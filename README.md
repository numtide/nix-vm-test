# Nix-Vm-Test

Use the NixOS VM test infrastructure to test Ubuntu, Debian, and Fedora machines.

-----

You can use this project to write some integration VM tests. These tests can be either be used:

- interactively, for development purposes.
- noninteractively, on CI, and used as an integration test matrix on a wide variety of Linux distributions.

-----

<p align="center">
  <a href="doc/getting-started.md">Getting Started</a> - <a href="doc/reference.md">Reference Documentation</a>
</p>

-----

## Status of the Project

**Beta-grade**

The API will be backward compatible. The project is already used in some production setups in the wild.

However, expect to experience some paper cuts along the way. Check out the [bug tracker](https://github.com/numtide/nix-vm-test/issues) to see the currently unfixed known bugs and their workaround.

## API Peek

```nix
let
  test = nix-vm-test.lib.ubuntu."23_04" {
    diskSize = "+2M"
    sharedDirs = {
      numtideShare = {
        source = "/home/numtide/share";
        target = "/mnt";
      };
    };
    testScript = ''
      vm.wait_for_unit("multi-user.target")
      vm.succeed("apt-get update")
    '';
    };
in test.sandboxed
}
```
