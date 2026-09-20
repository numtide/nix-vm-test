{ nixpkgs,   # The nixpkgs source
  system     # The *host* system (where QEMU and the test driver run)
}:
let
  inherit (nixpkgs) lib;

  hostSystem = system;
  guestSystem = import ./systems.nix hostSystem;

  # `hostPkgs`  runs the driver/QEMU (darwin on a Mac); `guestPkgs` is always a
  # Linux set used for the guest image and anything executed inside the VM.
  hostPkgs = import nixpkgs { system = hostSystem; };
  guestPkgs =
    if guestSystem == hostSystem
    then hostPkgs
    else import nixpkgs { system = guestSystem; };

  generic = hostPkgs.callPackage ./generic {
    inherit nixpkgs hostPkgs guestPkgs hostSystem guestSystem;
  };
  ubuntu = hostPkgs.callPackage ./ubuntu { inherit generic guestPkgs guestSystem; };
  debian = hostPkgs.callPackage ./debian { inherit generic guestPkgs guestSystem; };
  fedora = hostPkgs.callPackage ./fedora { inherit generic guestPkgs guestSystem; };
  rocky = hostPkgs.callPackage ./rocky { inherit generic guestPkgs guestSystem; };
  # Function that can be used when defining inline modules to get better location
  # reporting in module-system errors.
  # Usage example:
  #   { _file = "${printAttrPos (builtins.unsafeGetAttrPos "a" { a = null; })}: inline module"; }
  nixos = "${nixpkgs}/nixos";
in {
  inherit ubuntu debian fedora rocky;
}
