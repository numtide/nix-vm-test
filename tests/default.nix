{ package }:
let
  ubuntu = import ./ubuntu.nix { inherit package; };
in ubuntu
