{ package, pkgs, system }:
let
  lib = pkgs.lib;
  addPrefixToTests = prefix: tests: lib.mapAttrs' (n: v: lib.nameValuePair (prefix + n) v) tests;
  ubuntu = addPrefixToTests "ubuntu-" (import ./ubuntu.nix { inherit package pkgs system; });
  debian = addPrefixToTests "debian-" (import ./debian.nix { inherit package pkgs system; });
  fedora = addPrefixToTests "fedora-" (import ./fedora.nix { inherit package pkgs system; });
  rocky = addPrefixToTests "rocky-" (import ./rocky.nix { inherit package pkgs system; });
in ubuntu // debian // fedora // rocky
