final: prev:

let
  inherit (prev.stdenv.hostPlatform) system;
  hostSystem = system;
  guestSystem = import ./systems.nix hostSystem;

  # On a Linux host the guest packages are just `final`; on darwin we need a
  # Linux package set for the guest image and in-VM binaries.
  guestPkgs =
    if guestSystem == hostSystem
    then final
    else import prev.path { system = guestSystem; };

  generic = import ./generic {
    inherit (prev) lib;
    hostPkgs = final;
    inherit guestPkgs hostSystem guestSystem;
    nixpkgs = prev.path;
  };
  ubuntu = prev.callPackage ./ubuntu { inherit generic guestPkgs guestSystem; };
  debian = prev.callPackage ./debian { inherit generic guestPkgs guestSystem; };
  fedora = prev.callPackage ./fedora { inherit generic guestPkgs guestSystem; };
  rocky = prev.callPackage ./rocky { inherit generic guestPkgs guestSystem; };
in

{
  testers = prev.testers or { } // {
    nonNixOSDistros = prev.testers.nonNixOSDistros or {} // {
      inherit debian ubuntu fedora rocky;
    };
  };
}
