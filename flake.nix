{
  description = "Nix-VM-Test, re-use the NixOS VM integration test infrastructure on Ubuntu, Debian and Fedora";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }: rec {
    lib = system: import ./lib.nix {
      inherit nixpkgs system;
    };
    checks.x86_64-linux = import ./tests { package = lib "x86_64-linux"; pkgs = nixpkgs.legacyPackages.x86_64-linux; };
  };
}
