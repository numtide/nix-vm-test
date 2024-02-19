{ package, pkgs }:
let
  ubuntu = import ./ubuntu.nix { inherit package pkgs; };
in ubuntu
