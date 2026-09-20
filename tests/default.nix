{ package, pkgs, guestPkgs, system }:
let
  lib = pkgs.lib;
  addPrefixToTests = prefix: tests: lib.mapAttrs' (n: v: lib.nameValuePair (prefix + n) v) tests;

  args = { inherit package pkgs guestPkgs system; };

  distros = {
    ubuntu = ./ubuntu.nix;
    debian = ./debian.nix;
    fedora = ./fedora.nix;
    rocky = ./rocky.nix;
  };

  # Only build a distro's tests when it actually has images for this system.
  # E.g. Fedora ships no aarch64 image, so it is skipped on aarch64-darwin.
  # `optionalAttrs` yields {} for the skipped distros, and `concatMapAttrs`
  # merges the rest into a single flat set of prefixed tests.
in
lib.concatMapAttrs
  (name: file:
    lib.optionalAttrs ((package.${name}.images or { }) != { })
      (addPrefixToTests "${name}-" (import file args)))
  distros
