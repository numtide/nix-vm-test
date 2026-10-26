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
    inherit guestPkgs;
    nixpkgs = prev.path;
  };
  ubuntu = prev.callPackage ./ubuntu { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  debian = prev.callPackage ./debian { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  fedora = prev.callPackage ./fedora { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  rocky = prev.callPackage ./rocky { inherit generic; pkgs = guestPkgs; system = guestSystem; };
  archlinux = prev.callPackage ./archlinux { inherit generic; pkgs = guestPkgs; system = guestSystem; };
in

{
  testers = prev.testers or { } // {
    nonNixOSDistros = prev.testers.nonNixOSDistros or {} // {
      inherit debian ubuntu fedora rocky archlinux;
    };
  };
}
