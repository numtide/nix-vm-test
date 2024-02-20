{ pkgs, package, system }:
let
  lib = package.${system};
in {
  dummyTest = lib.debian."13" {
    name = "test_debian_dummy";
    sharedDirs = {};
    testScript = ''
      test_debian_dummy.wait_for_unit("multi-user.target")
  '';
  };
} // package.${system}.debian.images
