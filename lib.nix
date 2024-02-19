{ nixpkgs,   # The nixpkgs source
  system
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (nixpkgs) lib;
  generic = pkgs.callPackage ./generic { inherit nixpkgs; };
  ubuntu = pkgs.callPackage ./ubuntu { inherit generic system; };
  # Function that can be used when defining inline modules to get better location
  # reporting in module-system errors.
  # Usage example:
  #   { _file = "${printAttrPos (builtins.unsafeGetAttrPos "a" { a = null; })}: inline module"; }
  nixos = "${nixpkgs}/nixos";
in
rec {
  ubuntuStableRun = { testScript, name, sharedDirs}: generic.makeVmTest {
    inherit system testScript name;
    image = ubuntu.prepareUbuntuImage {
      hostPkgs = pkgs;
      originalImage = ubuntu.images."ubuntu_23_04_cloudimg";
    };

  };
}
