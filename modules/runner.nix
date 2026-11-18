# A macOS VM set up to run GitHub Actions jobs for My Compute Cloud.
#
# It is applied on top of a base VM that already has an auto-login user, sudo without a
# password, Homebrew and the Tart guest agent: Cirrus Labs' macos-*-base images.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mcc.runner;
  tools = import ./tools.nix { inherit lib pkgs; };
  home = "/Users/${cfg.user}";

  # My Compute Cloud starts each job through the Tart guest agent, in a shell that reads no
  # profile. So a job's environment is the guest agent's environment, and this launchd
  # definition is where it is set.
  guestAgent = pkgs.writeText "org.cirruslabs.tart-guest-agent.plist" (
    lib.generators.toPlist { escape = true; } {
      Label = "org.cirruslabs.tart-guest-agent";
      ProgramArguments = [
        cfg.guestAgent
        "--run-agent"
      ];
      EnvironmentVariables = cfg.environment // {
        PATH = lib.concatStringsSep ":" cfg.path;
      };
      WorkingDirectory = home;
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/tmp/tart-guest-agent.log";
      StandardErrorPath = "/tmp/tart-guest-agent.log";
    }
  );
in
{
  options.mcc.runner = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "The base image's auto-login user. Jobs run as this user.";
    };

    guestAgent = lib.mkOption {
      type = lib.types.str;
      default = "/opt/homebrew/bin/tart-guest-agent";
      description = "Where the base image keeps the Tart guest agent.";
    };

    path = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "PATH for jobs, first entry first.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      description = "Environment variables for jobs, other than PATH.";
    };

    jobSetup = lib.mkOption {
      type = lib.types.lines;
      description = ''
        Shell commands that My Compute Cloud's agent runs (sources) in each job's VM just
        before the runner starts, for what cannot be a fixed environment variable. When the
        host owner provides a cache, MCC_CACHE_DIR names it.
      '';
    };
  };

  config = {
    nixpkgs.hostPlatform = "aarch64-darwin";
    system.stateVersion = 6;
    system.primaryUser = cfg.user;

    environment.systemPackages = lib.concatLists (lib.attrValues tools);

    mcc.runner.path = [
      # The default python3 and pip3: a virtual environment, made at activation, so that
      # `pip install` works as it does on GitHub's image.
      "${home}/.python/bin"
      # Where `npm install -g`, `gem install`, `pipx install`, `cargo install`, `go install`
      # and `dotnet tool install -g` put programs. The tools themselves are in the read-only
      # Nix store, so the environment below points npm and gem at the home directory.
      "${home}/.npm-global/bin"
      "${home}/.gem/bin"
      "${home}/.local/bin"
      "${home}/.cargo/bin"
      "${home}/go/bin"
      "${home}/.dotnet/tools"
      # Then this configuration's tools, so a job gets the pinned versions, then what the
      # base image installed with Homebrew, then macOS itself.
      "/run/current-system/sw/bin"
      "/nix/var/nix/profiles/default/bin"
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"
      "/usr/local/bin"
      "/usr/bin"
      "/bin"
      "/usr/sbin"
      "/sbin"
    ];

    mcc.runner.environment = {
      TERM = "xterm-256color";
      LANG = "en_US.UTF-8";
      # Tools built by Nix look here for certificate authorities.
      NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      JAVA_HOME = "${pkgs.jdk21.home}";
      JAVA_HOME_21_arm64 = "${pkgs.jdk21.home}";
      DOTNET_ROOT = "${pkgs.dotnet-sdk_8}/share/dotnet";
      NPM_CONFIG_PREFIX = "${home}/.npm-global";
      GEM_HOME = "${home}/.gem";
      # A job should not spend its first minutes updating Homebrew.
      HOMEBREW_NO_AUTO_UPDATE = "1";
      HOMEBREW_NO_INSTALL_CLEANUP = "1";
    };

    # A host owner may give jobs a directory that outlives them (the agent's cache_dir
    # policy). Only download caches are put there: what they hold is checked against a
    # lock file or a checksum when it is used, and several jobs can write to them at once.
    mcc.runner.jobSetup = ''
      if [ -n "''${MCC_CACHE_DIR:-}" ] && [ -w "$MCC_CACHE_DIR" ]; then
        export npm_config_cache="$MCC_CACHE_DIR/npm"
        export YARN_CACHE_FOLDER="$MCC_CACHE_DIR/yarn"
        export PIP_CACHE_DIR="$MCC_CACHE_DIR/pip"
        export UV_CACHE_DIR="$MCC_CACHE_DIR/uv"
        export GOMODCACHE="$MCC_CACHE_DIR/go-mod"
        export NUGET_PACKAGES="$MCC_CACHE_DIR/nuget"
        export HOMEBREW_CACHE="$MCC_CACHE_DIR/homebrew"
      fi
    '';
    environment.etc."mcc/job-env".text = cfg.jobSetup;

    # Installed as a file rather than as a nix-darwin launchd agent, which would restart the
    # guest agent during activation and cut off the build that is running through it. The new
    # environment applies from the next boot, and every job is a fresh boot.
    system.activationScripts.postActivation.text = ''
      echo "installing the Tart guest agent's job environment..." >&2
      install -o root -g wheel -m 0644 ${guestAgent} /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist

      # Nix's Python is read-only, so `pip install` into it fails. A virtual environment on
      # top of it is writable and is what jobs find first on PATH.
      echo "creating the default Python environment..." >&2
      sudo -u ${cfg.user} ${pkgs.python3}/bin/python3 -m venv --clear ${home}/.python
    '';

    # Jobs may use Nix themselves, with flakes and with binary caches of their choosing.
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ cfg.user ];
    };
    nix.channel.enable = false;

    # For people who log in to look around; jobs do not start a login shell. Bash is left
    # alone: enabling it here would put Bash 5 ahead of the Bash 3.2 that macOS and GitHub's
    # hosted image have.
    programs.zsh.enable = true;
    programs.bash.enable = false;

    documentation.enable = false;
    programs.info.enable = false;
  };
}
