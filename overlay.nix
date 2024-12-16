final: prev:

let
  inherit (prev) system;
  generic = import ./generic { inherit (prev) lib; pkgs = final; nixpkgs = prev.path; };
  ubuntu = prev.callPackage ./ubuntu { inherit generic system; };
  debian = prev.callPackage ./debian { inherit generic system; };
  fedora = prev.callPackage ./fedora { inherit generic system; };
in

{
  testers = prev.testers or { } // {
    nonNixOSDistros = prev.testers.nonNixOSDistros or {} // {
      inherit debian ubuntu fedora;
    };
  };
}
