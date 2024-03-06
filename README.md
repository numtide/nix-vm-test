# Nix-Vm-Test

Use the NixOS VM test infrastructure to test Ubuntu, Debian, and Fedora machines.

<p align="center">
  <a href="doc/getting-started.md">Getting Started</a> - <a href="doc/reference.md">Reference Documentation</a>
</p>

## Example

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
