#!/bin/bash
# Runs inside the VM, started by build.sh: installs Determinate Nix if the base lacks Nix and applies the
# nix-darwin configuration from the flake that build.sh shared into the VM.
#
#   provision.sh <configuration> <flake revision> <base image>
set -euo pipefail

config=$1
revision=$2
base=$3
shared="/Volumes/My Shared Files/flake"
work="$HOME/.mcc-image-build"
determinate_version=3.24.3

[ -f "$shared/flake.nix" ] || { echo "provision.sh: the flake is not shared into this VM" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "provision.sh: this needs sudo without a password in the base image" >&2; exit 1; }

# A copy on the VM's own disk: Nix cannot evaluate a flake in place on the shared volume.
rm -rf "$work"
mkdir -p "$work/flake"
cp -R "$shared/." "$work/flake/"

if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
	echo "Installing Determinate Nix $determinate_version"
	curl -fsSL "https://install.determinate.systems/nix/tag/v$determinate_version" -o "$work/install-nix"
	sh "$work/install-nix" install --determinate --no-confirm
fi
# shellcheck disable=SC1091
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

# nix-darwin owns these from here on and refuses to replace files it did not write. nix.conf
# stays Determinate Nix's; the configuration's Nix settings go in nix.custom.conf.
for f in /etc/zshrc /etc/zshenv /etc/nix/nix.custom.conf; do
	if [ -e "$f" ] && [ ! -L "$f" ]; then sudo mv "$f" "$f.before-nix-darwin"; fi
done

flake="path:$work/flake"
nix --extra-experimental-features 'nix-command flakes' build \
	"$flake#darwinConfigurations.$config.system" --out-link "$work/system"
sudo "$work/system/sw/bin/darwin-rebuild" switch --flake "$flake#$config"

# What the image was built from, for anyone debugging a job.
printf '{"configuration":"%s","revision":"%s","base":"%s","built_at":"%s"}\n' \
	"$config" "$revision" "$base" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | sudo tee /etc/mcc-image.json >/dev/null

# Leave only the running system in the store.
rm -rf "$work"
sudo nix-collect-garbage -d >/dev/null 2>&1
df -h / | tail -1
# The VM is stopped next; nothing written above may still be only in memory.
sync
