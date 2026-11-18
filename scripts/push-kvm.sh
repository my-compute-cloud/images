#!/bin/sh
# Publishes a Linux runner image for Linux hosts: the directory build-kvm.sh leaves, or the
# one build.sh leaves with KVM_OUT set.
#
#   scripts/push-kvm.sh <directory> <registry>/<name>:<tag>
#
# The disk goes up as an OCI artifact under <tag>-<architecture>, in pieces, so that an upload
# that fails resumes with the pieces already there. <tag> itself is then pointed at an index
# of whichever of <tag>-arm64 and <tag>-amd64 exist, so that one name serves hosts of both
# architectures; push the other architecture later and the index gains it.
#
# Needs oras 1.3 or newer (https://oras.land), logged in to the registry (`oras login`), and
# jq. With Nix: nix shell nixpkgs#oras nixpkgs#jq --command scripts/push-kvm.sh ...
#
# Settings, optional, from the environment:
#   PIECE_MB    size of each piece; default 256
#   SOURCE_URL  repository the image is linked to on ghcr.io; default this one
#   ORAS_OPTIONS  extra options for oras, for example --plain-http for a registry on this machine
set -eu

[ $# -eq 2 ] || { echo "usage: push-kvm.sh <directory> <registry>/<name>:<tag>" >&2; exit 2; }
dir=$(cd "$1" && pwd)
ref=$2
repo=${ref%:*}
tag=${ref##*:}
[ "$repo" != "$ref" ] && [ -n "$tag" ] || { echo "push-kvm.sh: the reference needs a tag" >&2; exit 2; }
for tool in oras jq split; do
	command -v "$tool" >/dev/null || { echo "push-kvm.sh: $tool is not installed" >&2; exit 1; }
done
[ -f "$dir/disk.qcow2" ] && [ -f "$dir/config.json" ] || { echo "push-kvm.sh: $dir has no disk.qcow2 and config.json" >&2; exit 1; }
arch=$(jq -r .architecture "$dir/config.json")
PIECE_MB=${PIECE_MB:-256}
ORAS_OPTIONS=${ORAS_OPTIONS:-}
source_url=${SOURCE_URL:-https://github.com/my-compute-cloud/images}

config_type=application/vnd.mcc.vm.config.v1+json
disk_type=application/vnd.mcc.vm.disk.v1.qcow2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Names that sort in order: the host puts the pieces back together in the order listed.
split -b "${PIECE_MB}m" -a 4 "$dir/disk.qcow2" "$work/disk.qcow2."
cp "$dir/config.json" "$work/config.json"

cd "$work"
layers=
for piece in disk.qcow2.*; do layers="$layers $piece:$disk_type"; done
echo "==> Pushing $repo:$tag-$arch"
# shellcheck disable=SC2086
oras push $ORAS_OPTIONS --config "config.json:$config_type" \
	--annotation "org.opencontainers.image.source=$source_url" \
	"$repo:$tag-$arch" $layers

echo "==> Pointing $repo:$tag at the architectures published"
manifests=
for a in arm64 amd64; do
	# shellcheck disable=SC2086
	if d=$(oras manifest fetch $ORAS_OPTIONS --descriptor "$repo:$tag-$a" 2>/dev/null); then
		entry=$(printf '%s' "$d" | jq -c --arg a "$a" '{mediaType, digest, size, platform: {architecture: $a, os: "linux"}}')
		manifests="${manifests:+$manifests,}$entry"
	fi
done
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s],"annotations":{"org.opencontainers.image.source":"%s"}}' \
	"$manifests" "$source_url" > index.json
# shellcheck disable=SC2086
oras manifest push $ORAS_OPTIONS --media-type application/vnd.oci.image.index.v1+json "$repo:$tag" index.json
echo "==> Published $repo:$tag"
