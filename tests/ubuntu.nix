{ pkgs, package }:

{
  dummyTest = package.ubuntu."ubuntu_23_04" {
    name = "test_ubuntu_dummy";
    sharedDirs = {};
    testScript = ''
      test_ubuntu_dummy.wait_for_unit("multi-user.target")
  '';
  };

  sharedDirTest = let
    dir1 = pkgs.runCommandNoCC "dir1" {} ''
      mkdir -p $out
      echo "hello1" > $out/somefile1
    '';
    dir2 = pkgs.runCommandNoCC "dir2" {} ''
      mkdir -p $out
      echo "hello2" > $out/somefile2
    '';
  in package.ubuntu."ubuntu_23_04" {
    name = "shared_dir_test";
    sharedDirs = {
      dir1 = {
        source = "${dir1}";
        target = "/tmp/dir1";
      };
      dir2 = {
        source = "${dir2}";
        target = "/tmp/dir2";
      };
    };
    testScript = ''
      shared_dir_test.wait_for_unit("multi-user.target")
      shared_dir_test.succeed('ls /tmp/dir1')
      shared_dir_test.succeed('test "$(cat /tmp/dir1/somefile1)" == "hello1"')
      shared_dir_test.succeed('test "$(cat /tmp/dir2/somefile2)" == "hello2"')
    '';
  };
}
