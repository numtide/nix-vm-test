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
    (n: v: pkgs.lib.nameValuePair "${n}-multi-user-test" (test lib.debian.${n}))
    lib.debian.images;
in {
  resizeImage = (lib.debian."13" {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      # Verify the disk resize didn't leave a failed unit behind (baked path:
      # our own resizeguest.service; cloud-init path: its built-in growpart).
      vm.succeed('[ -z "$(systemctl --failed --no-legend)" ]')
    '';
    diskSize = "+2M";
  }).sandboxed;

  sharedDirTest = let
    dir1 = pkgs.runCommandNoCC "dir1" {} ''
      mkdir -p $out
      echo "hello1" > $out/somefile1
    '';
    dir2 = pkgs.runCommandNoCC "dir2" {} ''
      mkdir -p $out
      echo "hello2" > $out/somefile2
    '';
  in (lib.debian."13" {
    sharedDirs = {
      dir1 = {
        source = dir1;
        target = "/tmp/dir1";
      };
      dir2 = {
        source = dir2;
        target = "/tmp/dir2";
      };
    };
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      vm.succeed('ls /tmp/dir1')
      vm.succeed('test "$(cat /tmp/dir1/somefile1)" == "hello1"')
      vm.succeed('test "$(cat /tmp/dir2/somefile2)" == "hello2"')
    '';
  }).sandboxed;
} //
runTestOnEveryImage multiUserTest //
package.debian.images
