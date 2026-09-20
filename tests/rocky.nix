{ pkgs, package, guestPkgs, system }:
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
in {
  resizeImage = (lib.rocky."10_1" {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      # Verify the disk resize didn't leave a failed unit behind (baked path:
      # our own resizeguest.service; cloud-init path: its built-in growpart).
      vm.succeed('[ -z "$(systemctl --failed --no-legend)" ]')
    '';
    diskSize = "+2M";
  }).sandboxed;
} //
runTestOnEveryImage multiUserTest //
package.rocky.images
