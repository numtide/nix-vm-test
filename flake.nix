{
  description = "NixOS-Test-Anywhere, run your NixOS VM tests on Ubuntu, Debian and Fedora";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    lib = system: import ./lib.nix {
      inherit nixpkgs system;
    };
  };
}
