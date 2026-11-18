#!/bin/bash
# Runs inside a freshly booted image, the way My Compute Cloud starts a job: through the Tart
# guest agent, in a shell that reads no profile. Fails if a job would not find its tools.
set -euo pipefail

fail=0
for tool in \
	git git-lfs gh jq yq curl wget gtar zstd gpg 7zz aria2c openssl pkgconf ninja cmake \
	node npm yarn python3 pip3 pipx ruby gem bundle pod fastlane go cargo rustc java mvn gradle ant \
	kotlin dotnet gfortran perl pwsh aws sam az bicep bazelisk vcpkg swiftformat xcbeautify xcodes \
	brew nix; do
	if ! command -v "$tool" >/dev/null; then
		echo "missing: $tool"
		fail=1
	fi
done

# Apple's own tools must still be the ones a job gets.
for tool in cc gcc g++ c++ ld ar make clang bash sh tar sed python3; do
	case $tool in python3) want=$HOME/.python/bin/python3 ;; bash | sh) want=/bin/$tool ;; *) want=/usr/bin/$tool ;; esac
	got=$(command -v "$tool" || true)
	[ "$got" = "$want" ] || { echo "$tool is $got, expected $want"; fail=1; }
done
[ "$(command -v pip3)" = "$HOME/.python/bin/pip3" ] || { echo "pip3 does not belong to python3"; fail=1; }

# A few that must actually start, not just exist.
git --version
node --version
python3 --version
ruby --version
go version
java -version 2>&1 | head -1
dotnet --version
nix --version

[ -x "${JAVA_HOME:-}/bin/java" ] || { echo "JAVA_HOME does not point at a JDK"; fail=1; }
[ -d "${DOTNET_ROOT:-}" ] || { echo "DOTNET_ROOT does not point at a directory"; fail=1; }
# Certificates work for the tools Nix built, not only for Apple's.
git ls-remote https://github.com/actions/checkout HEAD >/dev/null || { echo "git cannot reach github.com over HTTPS"; fail=1; }

# Installing with the language package managers works and lands on PATH, although the tools
# themselves are read-only. Cleaned up afterwards: this runs in the image that gets published.
scratch=$(mktemp -d)
trap 'pip3 uninstall --quiet --yes cowsay >/dev/null 2>&1; rm -rf "$scratch" ~/.npm-global ~/.npm ~/.gem ~/Library/Caches/pip' EXIT
(cd "$scratch" && npm install -g --silent semver >/dev/null && semver 1.2.3 >/dev/null) || { echo "npm install -g does not work"; fail=1; }
(gem install --silent --no-document rake -v 13.2.1 >/dev/null && [ -x ~/.gem/bin/rake ]) || { echo "gem install does not work"; fail=1; }
(pip3 install --quiet --disable-pip-version-check cowsay >/dev/null && cowsay -t ok >/dev/null) || { echo "pip3 install does not work"; fail=1; }
printf 'int main(void) { return 0; }\n' > "$scratch/a.c"
(cc "$scratch/a.c" -o "$scratch/a" && "$scratch/a") || { echo "cc cannot build a program"; fail=1; }
gnu_cc=$(ls /run/current-system/sw/bin | grep -E '^gcc-[0-9]+$' | head -1)
([ -n "$gnu_cc" ] && "$gnu_cc" "$scratch/a.c" -o "$scratch/b" && "$scratch/b") || { echo "GCC (gcc-<version>) cannot build a program"; fail=1; }

[ -f /etc/mcc-image.json ] && cat /etc/mcc-image.json || { echo "no /etc/mcc-image.json"; fail=1; }
sudo -n true || { echo "sudo asks for a password"; fail=1; }

[ "$fail" = 0 ] && echo "The image looks right." || { echo "The image is not usable as it is."; exit 1; }
