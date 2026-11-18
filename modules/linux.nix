# What a Linux runner image gets from Nix: the tools, and the file that sets up a job's
# environment. scripts/provision-linux.sh installs the result as the profile
# /nix/var/nix/profiles/mcc on top of an Ubuntu VM, which keeps its own compilers, Docker and
# system libraries from apt.
#
# Unlike the macOS image, there is no service definition to carry the job's environment: the
# agent's entry command reads /etc/mcc/job-env, a link to this profile's share/mcc/job-env,
# just before it starts the runner. Everything a job needs set is set there.
{
  lib,
  pkgs,
  # More packages for your own image.
  extraPackages ? [ ],
  # More shell for the job's environment, after ours.
  extraJobSetup ? "",
}:
let
  tools = import ./tools.nix { inherit lib pkgs; };
  profile = "/nix/var/nix/profiles/mcc";

  jobEnv = pkgs.writeTextDir "share/mcc/job-env" ''
    # Sourced by My Compute Cloud's entry command in each job's VM before the runner starts.
    #
    # First on PATH: the default python3 and pip3 (a virtual environment, so that
    # `pip install` works), then where npm, gem, pipx, cargo, go and dotnet install programs,
    # then this image's pinned tools, Nix itself, and then Ubuntu's.
    export PATH="$HOME/.python/bin:$HOME/.npm-global/bin:$HOME/.gem/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/.dotnet/tools:${profile}/bin:/nix/var/nix/profiles/default/bin:$PATH"
    export LANG=C.UTF-8
    export JAVA_HOME=${pkgs.jdk21.home}
    export JAVA_HOME_21_${
      if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "X64"
    }=${pkgs.jdk21.home}
    export DOTNET_ROOT=${pkgs.dotnet-sdk_8}/share/dotnet
    # The tools are in the read-only Nix store, so installs go to the home directory.
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    export GEM_HOME="$HOME/.gem"
    # Tools built by Nix look here for certificate authorities.
    export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    # Do not let apt stop a job to ask a question.
    export DEBIAN_FRONTEND=noninteractive

    ${builtins.readFile ./cache-setup.sh}
    ${extraJobSetup}
  '';
in
pkgs.buildEnv {
  name = "mcc-linux-runner";
  paths = lib.concatLists (lib.attrValues tools) ++ extraPackages ++ [ jobEnv ];
  # Two tools may ship a file of the same name (both JDK and Kotlin have a `jar`, say); the
  # first in the list wins, as in the macOS configuration.
  ignoreCollisions = true;
  pathsToLink = [
    "/bin"
    "/share/mcc"
  ];
  passthru = { inherit jobEnv; };
}
