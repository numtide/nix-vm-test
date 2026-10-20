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
  # The image must boot, and the backdoor must work, with SELinux enforcing.
  selinuxEnforcing = (lib.rocky."10_1" {
    sharedDirs = {};
    selinuxEnforcing = true;
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      vm.succeed('test "$(getenforce)" = Enforcing')
      vm.succeed('ls -Z /usr/bin/backdoorScript | grep -q bin_t')
      vm.succeed('[ -z "$(systemctl --failed --no-legend)" ]')
    '';
  }).sandboxed;

  selinuxPermissive = (lib.rocky."10_1" {
    sharedDirs = {};
    selinuxEnforcing = false;
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      vm.succeed('test "$(getenforce)" = Permissive')
    '';
  }).sandboxed;
} //
runTestOnEveryImage multiUserTest //
package.rocky.images
