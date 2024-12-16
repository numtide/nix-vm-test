{
  description = "Nix-VM-Test, re-use the NixOS VM integration test infrastructure on Ubuntu, Debian and Fedora";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        overlays = [ self.overlays.default ];
        localSystem = system;
      };
    in
    {
      lib.${system} = pkgs.testers.nix-vm-test;

      checks.${system} = import ./tests {
        package = pkgs.testers.nix-vm-test;
        inherit pkgs system;
      };

      overlays.default = import ./overlay.nix;
    };
}
