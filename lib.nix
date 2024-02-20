{ nixpkgs,   # The nixpkgs source
  system
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (nixpkgs) lib;
  generic = pkgs.callPackage ./generic { inherit nixpkgs; };
  ubuntu = pkgs.callPackage ./ubuntu { inherit generic system; };
  debian = pkgs.callPackage ./debian { inherit generic system; };
  # Function that can be used when defining inline modules to get better location
  # reporting in module-system errors.
  # Usage example:
  #   { _file = "${printAttrPos (builtins.unsafeGetAttrPos "a" { a = null; })}: inline module"; }
  nixos = "${nixpkgs}/nixos";
in {
  inherit ubuntu debian;
}
