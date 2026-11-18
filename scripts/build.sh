#!/bin/sh
# Builds a runner image on this Mac and, with --push, publishes it.
#
#   scripts/build.sh [--push]
#
# It clones a base VM, boots it, applies this repository's nix-darwin configuration inside it,
# checks the result the way a job would see it, and leaves a stopped VM named $NAME. Needs an
# Apple Silicon Mac with Tart (https://tart.run); pushing needs `tart login` to the registry.
#
# Settings, all optional, from the environment:
#   MACOS    macOS release of the base image: tahoe (default) or sequoia
#   BASE     base image; default ghcr.io/cirruslabs/macos-$MACOS-base:latest
#   FLAKE    directory of the flake to apply; default this repository
#   CONFIG   darwinConfigurations attribute in that flake; default runner
#   NAME     local VM name; default mcc-image-$MACOS (replaced if it exists)
#   IMAGE    where --push publishes; default ghcr.io/my-compute-cloud/macos-runner
#   SOURCE_URL  repository the pushed image is linked to on ghcr.io; default this one
#   TAGS     space-separated tags to push; default "$MACOS $MACOS-<today>"
#   SMOKE_TEST  script run inside the finished image; default scripts/smoke-test.sh, which
#               expects this repository's tools. Set it to your own, or to "" to skip.
#   DISK_GB  disk size of the image; default 80 (the base has 50, of which 12 are free)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
push=
for arg in "$@"; do
	case $arg in
		--push) push=1 ;;
		*) echo "usage: build.sh [--push]" >&2; exit 2 ;;
	esac
done

MACOS=${MACOS:-tahoe}
BASE=${BASE:-ghcr.io/cirruslabs/macos-$MACOS-base:latest}
FLAKE=${FLAKE:-$root}
CONFIG=${CONFIG:-runner}
NAME=${NAME:-mcc-image-$MACOS}
IMAGE=${IMAGE:-ghcr.io/my-compute-cloud/macos-runner}
TAGS=${TAGS:-"$MACOS $MACOS-$(date -u +%Y%m%d)"}
DISK_GB=${DISK_GB:-80}
SMOKE_TEST=${SMOKE_TEST-$root/scripts/smoke-test.sh}

command -v tart >/dev/null || { echo "build.sh: tart is not installed (https://tart.run)" >&2; exit 1; }
[ -f "$FLAKE/flake.nix" ] || { echo "build.sh: no flake.nix in $FLAKE" >&2; exit 1; }

say() { printf '\n==> %s\n' "$*"; }

vm_pid=
cleanup() {
	tart stop "$NAME" --timeout 30 >/dev/null 2>&1 || true
	[ -z "$vm_pid" ] || wait "$vm_pid" 2>/dev/null || true
	[ -z "${stage:-}" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Only what git tracks goes into the VM, so the image is built from committed files and
# nothing else in the directory. A flake outside git is copied as it is.
stage=$(mktemp -d)
if git -C "$FLAKE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	git -C "$FLAKE" ls-files -z | (cd "$FLAKE" && xargs -0 tar -cf - --) | tar -xf - -C "$stage"
	revision=$(git -C "$FLAKE" rev-parse --verify -q HEAD || echo uncommitted)
	[ -z "$(git -C "$FLAKE" status --porcelain)" ] || revision="$revision-dirty"
else
	cp -R "$FLAKE/." "$stage/"
	revision=unversioned
fi

say "Cloning $BASE to $NAME"
tart delete "$NAME" >/dev/null 2>&1 || true
tart clone "$BASE" "$NAME"
# The guest grows its volume to fill the disk when it boots.
tart set "$NAME" --disk-size "$DISK_GB"

boot() {
	tart run "$NAME" --no-graphics "$@" &
	vm_pid=$!
	i=0
	until tart exec "$NAME" true >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 150 ] || { echo "build.sh: the VM's guest agent did not respond" >&2; exit 1; }
		kill -0 "$vm_pid" 2>/dev/null || { echo "build.sh: the VM exited while booting" >&2; exit 1; }
		sleep 2
	done
}
halt() {
	tart stop "$NAME" --timeout 60
	wait "$vm_pid" 2>/dev/null || true
	vm_pid=
}

say "Booting"
boot "--dir=flake:$stage:ro"

say "Applying $CONFIG from $FLAKE (revision $revision)"
tart exec -i "$NAME" /bin/bash -s -- "$CONFIG" "$revision" "$BASE" < "$root/scripts/provision.sh"
halt

# A second boot, with nothing shared, is what a job gets: it proves the configuration
# survives a restart and that the tools are there without the build's help.
if [ -n "$SMOKE_TEST" ]; then
	say "Checking the image as a job would see it"
	boot
	tart exec -i "$NAME" /bin/bash -s < "$SMOKE_TEST"
	halt
fi

if [ -n "$push" ]; then
	refs=
	for tag in $TAGS; do refs="$refs $IMAGE:$tag"; done
	say "Pushing$refs"
	# shellcheck disable=SC2086
	tart push "$NAME" $refs --label "org.opencontainers.image.source=${SOURCE_URL:-https://github.com/my-compute-cloud/images}"
else
	say "Built $NAME. Try it with: tart run $NAME"
fi
