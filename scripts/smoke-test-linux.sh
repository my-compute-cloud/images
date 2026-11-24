#!/bin/bash
# Runs inside a freshly booted Linux image, the way My Compute Cloud starts a job: through the
# Tart guest agent, in a shell that reads no profile, and then /etc/mcc/job-env as the agent's
# entry command does. Fails if a job would not find its tools.
set -euo pipefail

[ -r /etc/mcc/job-env ] || { echo "no /etc/mcc/job-env"; exit 1; }
# shellcheck disable=SC1091
. /etc/mcc/job-env

fail=0
for tool in \
	git git-lfs gh jq yq curl wget zstd gpg 7zz aria2c openssl pkgconf ninja cmake make \
	node npm yarn python3 pip3 pipx ruby gem bundle go cargo rustc java mvn gradle ant \
	kotlin dotnet gcc g++ perl pwsh aws sam az bicep bazelisk vcpkg docker nix; do
	if ! command -v "$tool" >/dev/null; then
		echo "missing: $tool"
		fail=1
	fi
done

# Ubuntu's own tools must still be the ones a job gets.
for tool in cc gcc g++ ld ar make bash sh tar sed; do
	got=$(command -v "$tool" || true)
	[ "$got" = "/usr/bin/$tool" ] || { echo "$tool is $got, expected /usr/bin/$tool"; fail=1; }
done
[ "$(command -v python3)" = "$HOME/.python/bin/python3" ] || { echo "python3 is not the default environment"; fail=1; }
[ "$(command -v pip3)" = "$HOME/.python/bin/pip3" ] || { echo "pip3 does not belong to python3"; fail=1; }

git --version
node --version
python3 --version
ruby --version
go version
java -version 2>&1 | head -1
dotnet --version
nix --version
nix --version | grep -q 'Determinate Nix' || { echo "Nix is not Determinate Nix"; fail=1; }

[ -x "${JAVA_HOME:-}/bin/java" ] || { echo "JAVA_HOME does not point at a JDK"; fail=1; }
[ -d "${DOTNET_ROOT:-}" ] || { echo "DOTNET_ROOT does not point at a directory"; fail=1; }
git ls-remote https://github.com/actions/checkout HEAD >/dev/null || { echo "git cannot reach github.com over HTTPS"; fail=1; }

# Docker works for the job's user without sudo, which container jobs and services need.
docker version --format '{{.Server.Version}}' || { echo "the job's user cannot use docker"; fail=1; }
(docker run --rm --quiet hello-world >/dev/null 2>&1 && docker rmi --force hello-world >/dev/null) || { echo "docker cannot run a container"; fail=1; }

[ -z "${npm_config_cache:-}" ] || { echo "npm's cache is redirected although there is no host cache"; fail=1; }
(MCC_CACHE_DIR=$(mktemp -d) && . /etc/mcc/job-env && [ "$npm_config_cache" = "$MCC_CACHE_DIR/npm" ]) || { echo "/etc/mcc/job-env does not point npm at the host cache"; fail=1; }

scratch=$(mktemp -d)
trap 'pip3 uninstall --quiet --yes cowsay >/dev/null 2>&1; rm -rf "$scratch" ~/.npm-global ~/.npm ~/.gem ~/.cache/pip' EXIT
(cd "$scratch" && npm install -g --silent semver >/dev/null && semver 1.2.3 >/dev/null) || { echo "npm install -g does not work"; fail=1; }
(gem install --silent --no-document rake -v 13.2.1 >/dev/null && [ -x ~/.gem/bin/rake ]) || { echo "gem install does not work"; fail=1; }
(pip3 install --quiet --disable-pip-version-check cowsay >/dev/null && cowsay -t ok >/dev/null) || { echo "pip3 install does not work"; fail=1; }
printf 'int main(void) { return 0; }\n' > "$scratch/a.c"
(cc "$scratch/a.c" -o "$scratch/a" && "$scratch/a") || { echo "cc cannot build a program"; fail=1; }

[ -f /etc/mcc-image.json ] && cat /etc/mcc-image.json || { echo "no /etc/mcc-image.json"; fail=1; }
sudo -n true || { echo "sudo asks for a password"; fail=1; }

[ "$fail" = 0 ] && echo "The image looks right." || { echo "The image is not usable as it is."; exit 1; }
