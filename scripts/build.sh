#!/bin/sh
# Builds a runner image on this Mac and, with --push, publishes it.
#
#   scripts/build.sh [--push]
#
# It clones a base VM, boots it, applies this repository's Nix configuration inside it, checks
# the result the way a job would see it, and leaves a stopped VM named $NAME. Needs an Apple
# Silicon Mac with Tart (https://tart.run); pushing needs `tart login` to the registry.
#
# Settings, all optional, from the environment:
#   OS       guest to build: macos (default) or linux
#   MACOS    for macos, the release of the base image: tahoe (default) or sequoia
#   BASE     base image; default ghcr.io/cirruslabs/macos-$MACOS-base:latest, or
#            ghcr.io/cirruslabs/ubuntu:latest for linux
#   FLAKE    directory of the flake to apply; default this repository
#   CONFIG   what to apply from that flake: for macos a darwinConfigurations attribute, for
#            linux a package (packages.<system>.<name>); default runner
#   NAME     local VM name; default mcc-image-$MACOS or mcc-image-ubuntu (replaced if it exists)
#   IMAGE    where --push publishes; default ghcr.io/my-compute-cloud/macos-runner or
#            ghcr.io/my-compute-cloud/ubuntu-runner
#   PUSH_OPTIONS  extra options for `tart push`. Default for ghcr.io: uploads in 3 MB chunks,
#                 because sending a whole layer in one request times out on a slow uplink.
#   SOURCE_URL  repository the pushed image is linked to on ghcr.io; default this one
#   TAGS     space-separated tags to push; default "$MACOS $MACOS-<today>", or
#            "24.04 24.04-<today>" for linux
#   SMOKE_TEST  script run inside the finished image; default scripts/smoke-test.sh or
#               scripts/smoke-test-linux.sh, which expect this repository's tools. Set it to
#               your own, or to "" to skip.
#   DISK_GB  disk size of the image; default 80 for macos (the base has 50, of which 12 are
#            free) and 40 for linux (the base has 20)
#   KVM_OUT  for linux, a directory to also leave the image in as a disk for Linux hosts
#            (disk.qcow2 and config.json), which scripts/push-kvm.sh publishes. It is the same
#            arm64 disk, since Tart's Linux VMs boot the way QEMU's do. Needs qemu-img, which
#            is taken from Nix if it is not installed.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
push=
for arg in "$@"; do
	case $arg in
		--push) push=1 ;;
		*) echo "usage: build.sh [--push]" >&2; exit 2 ;;
	esac
done

OS=${OS:-macos}
today=$(date -u +%Y%m%d)
case $OS in
	macos)
		MACOS=${MACOS:-tahoe}
		BASE=${BASE:-ghcr.io/cirruslabs/macos-$MACOS-base:latest}
		NAME=${NAME:-mcc-image-$MACOS}
		IMAGE=${IMAGE:-ghcr.io/my-compute-cloud/macos-runner}
		TAGS=${TAGS:-"$MACOS $MACOS-$today"}
		DISK_GB=${DISK_GB:-80}
		provision=$root/scripts/provision.sh
		smoke=$root/scripts/smoke-test.sh
		;;
	linux)
		BASE=${BASE:-ghcr.io/cirruslabs/ubuntu:latest}
		NAME=${NAME:-mcc-image-ubuntu}
		IMAGE=${IMAGE:-ghcr.io/my-compute-cloud/ubuntu-runner}
		TAGS=${TAGS:-"24.04 24.04-$today"}
		DISK_GB=${DISK_GB:-40}
		provision=$root/scripts/provision-linux.sh
		smoke=$root/scripts/smoke-test-linux.sh
		;;
	*) echo "build.sh: OS must be macos or linux" >&2; exit 2 ;;
esac
FLAKE=${FLAKE:-$root}
CONFIG=${CONFIG:-runner}
case $IMAGE in
	ghcr.io/*) PUSH_OPTIONS=${PUSH_OPTIONS-"--chunk-size 3 --concurrency 8"} ;;
	*) PUSH_OPTIONS=${PUSH_OPTIONS-} ;;
esac
SMOKE_TEST=${SMOKE_TEST-$smoke}

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

# Runs a script from this repository inside the VM. It is copied in first rather than fed to
# a shell on standard input, where any command that reads its input would swallow the rest.
guest_run() {
	script=$1
	shift
	tart exec -i "$NAME" /bin/bash -c 'cat > /tmp/mcc-build-step.sh' < "$script"
	tart exec "$NAME" /bin/bash /tmp/mcc-build-step.sh "$@"
	tart exec "$NAME" /bin/rm -f /tmp/mcc-build-step.sh
}

say "Booting"
boot "--dir=flake:$stage:ro"

say "Applying $CONFIG from $FLAKE (revision $revision)"
guest_run "$provision" "$CONFIG" "$revision" "$BASE"
if [ -n "${KVM_OUT:-}" ]; then
	# Who jobs run as, which a Linux host must know before it starts a VM.
	job_user=$(tart exec "$NAME" id -un)
	job_uid=$(tart exec "$NAME" id -u)
	job_gid=$(tart exec "$NAME" id -g)
fi
halt

# A second boot, with nothing shared, is what a job gets: it proves the configuration
# survives a restart and that the tools are there without the build's help.
if [ -n "$SMOKE_TEST" ]; then
	say "Checking the image as a job would see it"
	boot
	guest_run "$SMOKE_TEST"
	halt
fi

if [ -n "${KVM_OUT:-}" ]; then
	[ "$OS" = linux ] || { echo "build.sh: KVM_OUT is for OS=linux" >&2; exit 2; }
	say "Writing the disk for Linux hosts to $KVM_OUT"
	mkdir -p "$KVM_OUT"
	disk=${TART_HOME:-$HOME/.tart}/vms/$NAME/disk.img
	if command -v qemu-img >/dev/null; then
		qemu-img convert -c -O qcow2 "$disk" "$KVM_OUT/disk.qcow2"
	else
		nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#qemu-utils --command \
			qemu-img convert -c -O qcow2 "$disk" "$KVM_OUT/disk.qcow2"
	fi
	printf '{"architecture":"arm64","os":"linux","user":"%s","uid":%s,"gid":%s}\n' "$job_user" "$job_uid" "$job_gid" > "$KVM_OUT/config.json"
fi

if [ -n "$push" ]; then
	refs=
	for tag in $TAGS; do refs="$refs $IMAGE:$tag"; done
	say "Pushing$refs"
	# shellcheck disable=SC2086
	tart push "$NAME" $refs $PUSH_OPTIONS --label "org.opencontainers.image.source=${SOURCE_URL:-https://github.com/my-compute-cloud/images}"
else
	say "Built $NAME. Try it with: tart run $NAME"
fi
