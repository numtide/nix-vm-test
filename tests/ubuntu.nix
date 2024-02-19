{ package }:

{
  ubuntuStable = package.ubuntuStableRun {
    name = "test_ubuntu_stable";
    sharedDirs = {};
    testScript = ''
      test_ubuntu_stable.wait_for_unit("multi-user.target")
  '';
  };
}
