{
  description = "VM images for My Compute Cloud runners: a nix-darwin system for macOS, Nix-pinned tools on Ubuntu for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Determinate Nix's nix-darwin module: Determinate Nix, which provision.sh installs, manages
    # the Nix daemon and nix.conf; the module hands it this configuration's Nix settings.
    determinate = {
      url = "github:DeterminateSystems/determinate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
      determinate,
    }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      linuxSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forLinux = f: nixpkgs.lib.genAttrs linuxSystems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      # macOS: the whole runner configuration as a nix-darwin module, so that your own flake
      # can import it and add to it. See "Build your own image" in the README.
      darwinModules.runner = {
        imports = [
          determinate.darwinModules.default
          ./modules/runner.nix
        ];
      };
      darwinModules.default = self.darwinModules.runner;

      # What scripts/build.sh applies inside a macOS VM: `darwin-rebuild switch --flake .#runner`.
      darwinConfigurations.runner = nix-darwin.lib.darwinSystem {
        modules = [ self.darwinModules.runner ];
      };

      # Linux: the tools and the job environment, as one package that scripts/build.sh installs
      # inside an Ubuntu VM. lib.linuxRunner makes the same with your additions.
      lib.linuxRunner = args: import ./modules/linux.nix ({ inherit (args.pkgs) lib; } // args);
      packages = forLinux (pkgs: {
        runner = self.lib.linuxRunner { inherit pkgs; };
      });

      # `nix flake check` builds everything an image is made from, so a package that stops
      # building is caught before an image is.
      checks =
        forLinux (pkgs: {
          runner = self.packages.${pkgs.stdenv.hostPlatform.system}.runner;
        })
        // {
          ${system}.runner = self.darwinConfigurations.runner.system;
        };

      formatter.${system} = pkgs.nixfmt-rfc-style;
    };
}
