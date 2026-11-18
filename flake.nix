{
  description = "VM images for My Compute Cloud runners, declared with nix-darwin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
    }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The whole runner configuration as a module, so that your own flake can import it and
      # add to it. See "Build your own image" in the README.
      darwinModules.runner = ./modules/runner.nix;
      darwinModules.default = self.darwinModules.runner;

      # What scripts/build.sh applies inside the VM: `darwin-rebuild switch --flake .#runner`.
      darwinConfigurations.runner = nix-darwin.lib.darwinSystem {
        modules = [ self.darwinModules.runner ];
      };

      # `nix flake check` builds the complete system, so a package that stops building is
      # caught before an image is.
      checks.${system}.runner = self.darwinConfigurations.runner.system;

      formatter.${system} = pkgs.nixfmt-rfc-style;
    };
}
