#!/bin/bash
# Builds the Linux runner image on a Linux machine with KVM, as a disk for Linux hosts.
#
#   scripts/build-kvm.sh
#
# It is the same Ubuntu configuration that build.sh applies inside a Tart VM on a Mac
# (provision-linux.sh, then smoke-test-linux.sh), applied to Ubuntu's own cloud image under
# QEMU. Use it for x86_64, which a Mac cannot build, or for arm64 on an arm64 Linux machine.
# The result is a directory holding disk.qcow2 and config.json, which the agent can use as it
# is (name the directory as the image's source) and push-kvm.sh publishes.
#
# Needs: qemu-system for this machine's architecture, qemu-img, cloud-localds (package
# cloud-image-utils), ssh, curl, and access to /dev/kvm. On arm64 also the UEFI firmware
# (package qemu-efi-aarch64).
#
# Settings, all optional, from the environment:
#   UBUNTU   release of the base cloud image; default 24.04
#   BASE     URL or path of the base cloud image; default Ubuntu's for this architecture
#   FLAKE    directory of the flake to apply; default this repository
#   CONFIG   package to apply from that flake (packages.<system>.<name>); default runner
#   OUT      directory to leave the image in; default ./mcc-image-ubuntu-<architecture>
#   DISK_GB  disk size of the image; default 40
#   CPUS, MEMORY_MB  what the build VM gets; default 4 and 8192
#   SMOKE_TEST  script run inside the finished image; default scripts/smoke-test-linux.sh.
#               Set it to your own, or to "" to skip.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
UBUNTU=${UBUNTU:-24.04}
FLAKE=${FLAKE:-$root}
CONFIG=${CONFIG:-runner}
DISK_GB=${DISK_GB:-40}
CPUS=${CPUS:-4}
MEMORY_MB=${MEMORY_MB:-8192}
SMOKE_TEST=${SMOKE_TEST-$root/scripts/smoke-test-linux.sh}
user='admin'

case $(uname -m) in
	x86_64) arch=amd64; qemu=qemu-system-x86_64; machine='q35,accel=kvm' ;;
	aarch64 | arm64) arch=arm64; qemu=qemu-system-aarch64; machine='virt,accel=kvm,gic-version=host' ;;
	*) echo "build-kvm.sh: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
BASE=${BASE:-https://cloud-images.ubuntu.com/releases/$UBUNTU/release/ubuntu-$UBUNTU-server-cloudimg-$arch.img}
OUT=${OUT:-$PWD/mcc-image-ubuntu-$arch}

for tool in "$qemu" qemu-img cloud-localds ssh ssh-keygen curl; do
	command -v "$tool" >/dev/null || { echo "build-kvm.sh: $tool is not installed" >&2; exit 1; }
done
[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "build-kvm.sh: no access to /dev/kvm" >&2; exit 1; }
[ -f "$FLAKE/flake.nix" ] || { echo "build-kvm.sh: no flake.nix in $FLAKE" >&2; exit 1; }
firmware=()
if [ "$arch" = arm64 ]; then
	code=/usr/share/AAVMF/AAVMF_CODE.fd
	[ -f "$code" ] || { echo "build-kvm.sh: the UEFI firmware is not installed (package qemu-efi-aarch64)" >&2; exit 1; }
fi

say() { printf '\n==> %s\n' "$*"; }

work=$(mktemp -d)
vm_pid=
cleanup() {
	[ -z "$vm_pid" ] || kill "$vm_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Only what git tracks goes into the VM, as in build.sh.
mkdir "$work/flake"
if git -C "$FLAKE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	git -C "$FLAKE" ls-files -z | (cd "$FLAKE" && xargs -0 tar -cf - --) | tar -xf - -C "$work/flake"
	revision=$(git -C "$FLAKE" rev-parse --verify -q HEAD || echo uncommitted)
	[ -z "$(git -C "$FLAKE" status --porcelain)" ] || revision="$revision-dirty"
else
	cp -R "$FLAKE/." "$work/flake/"
	revision=unversioned
fi

say "Fetching $BASE"
case $BASE in
	http://* | https://*)
		curl -fL --progress-bar -o "$work/base.img" "$BASE"
		# Ubuntu publishes checksums beside its images.
		if sums=$(curl -fsSL "${BASE%/*}/SHA256SUMS" 2>/dev/null); then
			want=$(printf '%s\n' "$sums" | awk -v f="${BASE##*/}" '$2 == "*" f || $2 == f { print $1 }')
			got=$(sha256sum "$work/base.img" | cut -d' ' -f1)
			[ -n "$want" ] && [ "$want" = "$got" ] || { echo "build-kvm.sh: the base image does not match its published checksum" >&2; exit 1; }
		else
			echo "build-kvm.sh: no SHA256SUMS beside the base image; it is used unchecked" >&2
		fi
		;;
	*) cp "$BASE" "$work/base.img" ;;
esac
qemu-img convert -O qcow2 "$work/base.img" "$work/disk.qcow2"
rm "$work/base.img"
qemu-img resize -q "$work/disk.qcow2" "${DISK_GB}G"

# The build logs in with a key of its own, which never leaves this directory and is removed
# from the image at the end.
ssh-keygen -q -t ed25519 -N '' -C mcc-image-build -f "$work/key"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
ssh_opts=(-F none -i "$work/key" -p "$port" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
guest() { ssh "${ssh_opts[@]}" "$user@127.0.0.1" "$@"; }

# boot <extra qemu arguments...>
boot() {
	if [ "$arch" = arm64 ]; then
		cp /usr/share/AAVMF/AAVMF_VARS.fd "$work/vars.fd"
		firmware=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$work/vars.fd")
	fi
	"$qemu" -name mcc-image-build -nodefaults -no-user-config -display none \
		-machine "$machine" -cpu host -smp "$CPUS" -m "${MEMORY_MB}M" "${firmware[@]}" \
		-drive "if=none,id=root,format=qcow2,discard=unmap,file=$work/disk.qcow2" -device virtio-blk-pci,drive=root,bootindex=1 \
		-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" -device virtio-net-pci,netdev=net0,romfile= \
		-device virtio-rng-pci -serial "file:$work/console.log" "$@" &
	vm_pid=$!
	i=0
	until guest true 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -lt 150 ] || { echo "build-kvm.sh: the VM did not accept the build's SSH key" >&2; tail -20 "$work/console.log" >&2; exit 1; }
		kill -0 "$vm_pid" 2>/dev/null || { echo "build-kvm.sh: the VM exited while booting" >&2; exit 1; }
		sleep 2
	done
}
# Shuts the VM down, taking the key that got the build in out of the image as it goes: only
# the key a host hands a job's VM is to get in.
halt() {
	guest 'rm -f ~/.ssh/authorized_keys; sync; sudo systemctl poweroff' 2>/dev/null || true
	wait "$vm_pid" 2>/dev/null || true
	vm_pid=
}
# Runs a script from this repository inside the VM, from a file, as build.sh does.
guest_run() {
	script=$1
	shift
	guest 'cat > /tmp/mcc-build-step.sh' < "$script"
	guest /bin/bash /tmp/mcc-build-step.sh "$@"
	guest rm -f /tmp/mcc-build-step.sh
}

# First boot: cloud-init, given this seed, makes the job's user.
cat > "$work/user-data" <<EOF
#cloud-config
users:
  - name: $user
    # Ubuntu's image already has a group of this name, which useradd would refuse to make.
    primary_group: $user
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$work/key.pub")
EOF
printf 'instance-id: mcc-image-build\nlocal-hostname: ubuntu\n' > "$work/meta-data"
cloud-localds "$work/seed.img" "$work/user-data" "$work/meta-data"

say "Booting"
boot -drive "if=none,id=seed,format=raw,readonly=on,file=$work/seed.img" -device virtio-blk-pci,drive=seed
guest 'cloud-init status --wait >/dev/null 2>&1 || true'
# From now on cloud-init looks for no seed, so a job's VM boots without waiting for one.
guest 'echo "datasource_list: [ None ]" | sudo tee /etc/cloud/cloud.cfg.d/99_mcc.cfg >/dev/null'

say "Applying $CONFIG from $FLAKE (revision $revision)"
guest 'sudo mkdir -p /mnt/mcc/flake && sudo chown "$USER" /mnt/mcc/flake'
tar -cf - -C "$work/flake" . | guest 'tar -xf - -C /mnt/mcc/flake'
guest_run "$root/scripts/provision-linux.sh" "$CONFIG" "$revision" "$BASE"
uid=$(guest id -u)
gid=$(guest id -g)
halt

# A second boot, as a job gets it: no seed, and the key arriving the way a Linux host passes
# it, which proves the image lets the host in and that the tools are there.
say "Checking the image as a job would see it"
boot -smbios "type=11,value=io.systemd.credential:mcc.authorized_key=$(cat "$work/key.pub")"
if [ -n "$SMOKE_TEST" ]; then
	guest_run "$SMOKE_TEST"
fi
guest 'sudo fstrim -av >/dev/null 2>&1 || true'
halt

say "Writing $OUT"
mkdir -p "$OUT"
qemu-img convert -c -O qcow2 "$work/disk.qcow2" "$OUT/disk.qcow2"
printf '{"architecture":"%s","os":"linux","user":"%s","uid":%s,"gid":%s}\n' "$arch" "$user" "$uid" "$gid" > "$OUT/config.json"
ls -lh "$OUT"
say "Built $OUT. Publish it with: scripts/push-kvm.sh $OUT <registry>/<name>:<tag>"
