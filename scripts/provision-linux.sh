#!/bin/bash
# Runs inside an Ubuntu VM, started by build.sh: installs what a Linux runner needs from apt
# (Docker, compilers, the Actions runner's libraries), then Nix and the flake's runner package.
#
#   provision-linux.sh <package> <flake revision> <base image>
set -euo pipefail

package=$1
revision=$2
base=$3
shares=/mnt/mcc
work="$HOME/.mcc-image-build"
determinate_version=3.24.3

sudo -n true 2>/dev/null || { echo "provision-linux.sh: this needs sudo without a password in the base image" >&2; exit 1; }

# The flake is either shared in by Tart, whose Linux guests do not mount the host's shares by
# themselves, or was copied to the same place by build-kvm.sh.
shared_by_tart=
if [ ! -f "$shares/flake/flake.nix" ] && ! mountpoint -q "$shares"; then
	sudo mkdir -p "$shares"
	sudo mount -t virtiofs com.apple.virtio-fs.automount "$shares"
	shared_by_tart=1
fi
[ -f "$shares/flake/flake.nix" ] || { echo "provision-linux.sh: the flake is not shared into this VM" >&2; exit 1; }
rm -rf "$work"
mkdir -p "$work/flake"
cp -R "$shares/flake/." "$work/flake/"

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
# Docker for container jobs and services; the compilers and tools Ubuntu's own image has; and
# the libraries the Actions runner needs (its installdependencies.sh).
sudo apt-get install -y -qq --no-install-recommends \
	docker.io docker-buildx docker-compose-v2 openssh-server \
	build-essential ca-certificates curl git unzip zip xz-utils zstd rsync sudo tzdata locales \
	libicu74 libkrb5-3 zlib1g libssl3t64 liblttng-ust1t64 >/dev/null
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker >/dev/null 2>&1

if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
	echo "Installing Determinate Nix $determinate_version"
	curl -fsSL "https://install.determinate.systems/nix/tag/v$determinate_version" -o "$work/install-nix"
	sh "$work/install-nix" install --determinate --no-confirm >/dev/null
fi
# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
# Determinate Nix owns nix.conf and reads added settings from nix.custom.conf. Flakes are on by
# default. Crash reports would go from customers' jobs to Determinate's Sentry; they are off.
echo "trusted-users = $USER" | sudo tee -a /etc/nix/nix.custom.conf >/dev/null
sudo mkdir -p /etc/determinate
echo '{"telemetry":{"sentry":{"endpoint":null}}}' | sudo tee /etc/determinate/config.json >/dev/null
sudo systemctl restart nix-daemon 2>/dev/null || sudo systemctl restart determinate-nixd

system=$(nix --extra-experimental-features nix-command eval --impure --raw --expr builtins.currentSystem)
nix build "path:$work/flake#packages.$system.$package" --out-link "$work/runner"
sudo "$(command -v nix-env)" --profile /nix/var/nix/profiles/mcc --set "$(readlink -f "$work/runner")"

# The agent's entry command reads this just before the runner starts.
sudo mkdir -p /etc/mcc
sudo ln -sfn /nix/var/nix/profiles/mcc/share/mcc/job-env /etc/mcc/job-env

# How a Linux host reaches the VM. A Mac host uses the Tart guest agent; a Linux host has
# none, so it hands each VM a new SSH key as a systemd credential (an SMBIOS string, which
# only the host can set), and this service lets that key, and nothing else, log in as the
# job's user. Without the credential, as under Tart, the service does not run.
echo "$USER" | sudo tee /etc/mcc/job-user >/dev/null
sudo mkdir -p /usr/local/lib/mcc
sudo tee /usr/local/lib/mcc/guest-access >/dev/null <<'GUEST_ACCESS'
#!/bin/sh
# Installed by My Compute Cloud's image build; run by mcc-guest-access.service.
set -eu
key=/run/credentials/@system/mcc.authorized_key
[ -s "$key" ] || exit 0
user=$(cat /etc/mcc/job-user)
home=$(getent passwd "$user" | cut -d: -f6)
group=$(id -gn "$user")
install -d -m 700 -o "$user" -g "$group" "$home/.ssh"
install -m 600 -o "$user" -g "$group" "$key" "$home/.ssh/authorized_keys"
# The host's key is the only way in: the base image's password must not be another.
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/00-mcc.conf
GUEST_ACCESS
sudo chmod 755 /usr/local/lib/mcc/guest-access
sudo tee /etc/systemd/system/mcc-guest-access.service >/dev/null <<'GUEST_ACCESS'
[Unit]
Description=Let the My Compute Cloud host that started this VM run commands in it
ConditionPathExists=/run/credentials/@system/mcc.authorized_key
# Early, so that it is done before anything listens for SSH. Sockets come up before the
# services that default dependencies would order this after.
DefaultDependencies=no
After=local-fs.target
Before=sockets.target ssh.socket ssh.service shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/mcc/guest-access

[Install]
WantedBy=sysinit.target
GUEST_ACCESS
sudo systemctl enable mcc-guest-access.service >/dev/null 2>&1

# Nix's Python is read-only, so `pip install` into it fails. A virtual environment on top of
# it is writable and is what jobs find first on PATH.
/nix/var/nix/profiles/mcc/bin/python3 -m venv --clear "$HOME/.python"

printf '{"configuration":"%s","revision":"%s","base":"%s","built_at":"%s"}\n' \
	"$package" "$revision" "$base" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | sudo tee /etc/mcc-image.json >/dev/null

# Leave only what the image needs.
rm -rf "$work"
# sudo does not keep PATH, so Nix's commands are named in full.
sudo "$(command -v nix-collect-garbage)" -d >/dev/null
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
if [ -n "$shared_by_tart" ]; then
	sudo umount "$shares" 2>/dev/null || true
else
	sudo rm -rf "$shares/flake"
fi
df -h / | tail -1
# The VM is stopped next; nothing written above may still be only in memory.
sync
