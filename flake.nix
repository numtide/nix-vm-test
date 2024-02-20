{
  description = "Nix-VM-Test, re-use the NixOS VM integration test infrastructure on Ubuntu, Debian and Fedora";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }: rec {
    lib.x86_64-linux = import ./lib.nix {
      inherit nixpkgs;
      system = "x86_64-linux";
    };
    checks.x86_64-linux = import ./tests { package = lib; pkgs = nixpkgs.legacyPackages.x86_64-linux; system = "x86_64-linux"; };
  };
}
