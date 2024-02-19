{ package }:

{
  ubuntuStable = package.ubuntu."ubuntu_23_04" {
    name = "test_ubuntu_stable";
    sharedDirs = {};
    testScript = ''
      test_ubuntu_stable.wait_for_unit("multi-user.target")
  '';
  };
}
