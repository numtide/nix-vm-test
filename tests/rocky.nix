{ pkgs, package, system }:
let
  lib = package;
  multiUserTest = runner: (runner {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
    '';
  }).sandboxed;
  runTestOnEveryImage = test:
    pkgs.lib.mapAttrs'
    (n: v: pkgs.lib.nameValuePair "${n}-multi-user-test" (test lib.rocky.${n}))
    lib.rocky.images;
  # The kernel of Rocky has no 9P, so the store of the host is not
  # mounted, and a path the test uses reaches the VM only through
  # extraPathsToRegister.
  extraPathsTest = runner: (runner {
    sharedDirs = {};
    extraPathsToRegister = [ pkgs.hello pkgs.nix ];
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      vm.succeed("${pkgs.hello}/bin/hello")
      vm.succeed("${pkgs.nix}/bin/nix-store --check-validity ${pkgs.hello}")
    '';
  }).sandboxed;
in
runTestOnEveryImage multiUserTest //
{
  extraPathsToRegister = extraPathsTest lib.rocky."9_6";
} //
package.rocky.images
