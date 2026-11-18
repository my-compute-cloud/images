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
nix_version=2.34.8

sudo -n true 2>/dev/null || { echo "provision-linux.sh: this needs sudo without a password in the base image" >&2; exit 1; }

# Linux guests do not mount the host's shares by themselves.
if ! mountpoint -q "$shares"; then
	sudo mkdir -p "$shares"
	sudo mount -t virtiofs com.apple.virtio-fs.automount "$shares"
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
	docker.io docker-buildx docker-compose-v2 \
	build-essential ca-certificates curl git unzip zip xz-utils zstd rsync sudo tzdata locales \
	libicu74 libkrb5-3 zlib1g libssl3t64 liblttng-ust1t64 >/dev/null
sudo usermod -aG docker "$USER"
sudo systemctl enable --now docker >/dev/null 2>&1

if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
	echo "Installing Nix $nix_version"
	curl -fsSL "https://releases.nixos.org/nix/nix-$nix_version/install" -o "$work/install-nix"
	sh "$work/install-nix" --daemon --yes >/dev/null
fi
# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
echo "experimental-features = nix-command flakes
trusted-users = $USER" | sudo tee -a /etc/nix/nix.conf >/dev/null
sudo systemctl restart nix-daemon

system=$(nix --extra-experimental-features nix-command eval --impure --raw --expr builtins.currentSystem)
nix build "path:$work/flake#packages.$system.$package" --out-link "$work/runner"
sudo "$(command -v nix-env)" --profile /nix/var/nix/profiles/mcc --set "$(readlink -f "$work/runner")"

# The agent's entry command reads this just before the runner starts.
sudo mkdir -p /etc/mcc
sudo ln -sfn /nix/var/nix/profiles/mcc/share/mcc/job-env /etc/mcc/job-env

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
sudo umount "$shares" 2>/dev/null || true
df -h / | tail -1
# The VM is stopped next; nothing written above may still be only in memory.
sync
