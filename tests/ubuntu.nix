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
    (n: v: pkgs.lib.nameValuePair "${n}-multi-user-test" (test lib.ubuntu.${n}))
    lib.ubuntu.images;
in {
  resizeImage = (lib.ubuntu."23_04" {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
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
  in (lib.ubuntu."23_04" {
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

  sudoSameConsole = (lib.ubuntu."23_04" {
    sharedDirs = {};
    testScript = ''
      # Ensure using sudo doesn't crash the test-driver
      vm.execute("sudo bash -c \"echo 'Created foo → bar.\n' >&2 && echo 'foo' \"")
    '';
  }).sandboxed;

  pathsToRegisterTest = let
    testPackage = pkgs.runCommandNoCC "test-package" {} ''
      mkdir -p $out/bin
      echo '#!/bin/sh' > $out/bin/test-tool
      echo 'echo "Hello from test-package"' >> $out/bin/test-tool
      chmod +x $out/bin/test-tool
    '';
    nixStoreBin = "${pkgs.lib.getBin pkgs.nix}/bin/nix-store";
  in (lib.ubuntu."23_04" {
    sharedDirs = {};
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      # Verify mount-store.service completed successfully (oneshot services become inactive after completion)
      vm.succeed('systemctl show -p Result mount-store.service | grep -q "Result=success"')
      # Verify the nix store is mounted
      vm.succeed('test -d /nix/store')
      # Verify the test package path exists in the store
      vm.succeed('test -d ${testPackage}')
      # Verify the package contents are accessible
      vm.succeed('test -f ${testPackage}/bin/test-tool')
      vm.succeed('${testPackage}/bin/test-tool | grep "Hello from test-package"')
      # Verify the nix database was populated
      vm.succeed('test -f /nix/var/nix/db/db.sqlite')
      # Verify the test package is registered in the nix database
      vm.succeed('${nixStoreBin} --dump-db | grep -q "${testPackage}"')
    '';
    extraPathsToRegister = [ testPackage ];
  }).sandboxed;

}
// package.ubuntu.images
// runTestOnEveryImage multiUserTest
