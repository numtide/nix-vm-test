# Nix-Vm-Test

Re-use the NixOS VM test infrastructure to test Ubuntu, Debian, and Fedora machines.

The API is very WIP/unstable, do not expect much stability for now.

## Usage

```nix
nix-vm-test.lib.ubuntu."23_04" {
  sharedDirs = {
  };
  testScript = ''
    vm.wait_for_unit("multi-user.target")
  '';
  };
}
```

This is very WIP, we did not write a proper documentation for this. In the meantime, don't hesitate to check out the [test](tests) directory for more examples.
