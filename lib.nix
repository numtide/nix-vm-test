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
    inherit nixpkgs hostPkgs guestPkgs;
  };
  ubuntu = hostPkgs.callPackage ./ubuntu { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  debian = hostPkgs.callPackage ./debian { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  fedora = hostPkgs.callPackage ./fedora { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  rocky = hostPkgs.callPackage ./rocky { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  archlinux = hostPkgs.callPackage ./archlinux { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  # Function that can be used when defining inline modules to get better location
  # reporting in module-system errors.
  # Usage example:
  #   { _file = "${printAttrPos (builtins.unsafeGetAttrPos "a" { a = null; })}: inline module"; }
  nixos = "${nixpkgs}/nixos";
in {
  inherit ubuntu debian fedora rocky archlinux;
}
