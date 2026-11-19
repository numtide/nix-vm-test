# Reference Documentation

## Import the nix-vm-test to your Project

This project supports both flake-based workflows and non flake-based
workflows.

### Flake-based Workflows

Add the project to your `flake.nix` inputs to access the library from your flake outputs:

```nix
{
  inputs = {
    nix-vm-test = {
      url = "github:numtide/nix-vm-test";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nix-vm-test }: {
    packages.x86_64-linux = let
      test = nix-vm-test.lib.x86_64-linux.debian."12" {
        (...)
      };
    in test.driver
  };
}
```

### Non-Flake workflows

```nix
{ system ? "x86_64-linux", pkgs ? import <nixpkgs> { inherit system; }}:

let
  nix-vm-test-src = pkgs.fetchFromGitHub {
    owner = "numtide";
    repo = "nix-vm-test";
    # Replace this commit rev with the one pointed by the current main branch.
    rev = "e9df86d6275c5cda31c8bf3e7103e6c7c9e6fdad";
    sha256 = "sha256-NEpnmdhF5roYluocBmfpTjcg5giWtIXCMbsJFxTnNkM=";
  };
  nix-vm-test = import "${nix-vm-test-src}/lib.nix" {
    inherit system;
    nixpkgs = <nixpkgs>;
  };
  test = nix-vm-test.debian."12" {
    (...)
  };
in test.driver
```

Note: For a real-world deployment, you would probably want to pin `Nixpkgs` to a particular version, instead of using the one coming from your host path.


## Using a Nixpkgs Overlay

There is one last option to use this library: via a Nixpkgs overlay.

The overlay function makes all linux distributions available under the attribute
`pkgs.testers.nonNixOSDistros...`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    nix-vm-test.url = "github:numtide/nix-vm-test";
  };

  outputs = { self, nixpkgs, nix-vm-test }:
   let
     system = "x86_64-linux";
     pkgs = import nixpkgs {
       inherit system;
       overlays = [
         nix-vm-test.overlays.default
       ];
     };
    in
      packages.x86_64-linux.mytest = pkgs.testers.nonNixOSDistros.debian."13" {
        sharedDirs.debDir = {
          source = "${./.}";
          target = "/mnt/debdir";
        };
        testScript = ''
          vm.wait_for_unit("multi-user.target")
          vm.succeed("apt-get -yq install /mnt/debdir/hello.deb")
        '';
      };
}
```

## API

### Inputs

The API consists consists roughly of two parts:

```nix
$ROOT.$DISTRIBUTION {
  $INPUTS
}
```

Where `$ROOT` will be `nix-vm-test.lib.<system>` on a flake-based setup.

### Platform support

`<system>` is the **host** system running the driver. Supported hosts:

| Host system      | Guest system    | Acceleration | Notes                                  |
| ---------------- | --------------- | ------------ | -------------------------------------- |
| `x86_64-linux`   | `x86_64-linux`  | KVM          |                                        |
| `aarch64-linux`  | `aarch64-linux` | KVM          |                                        |
| `aarch64-darwin` | `aarch64-linux` | HVF          | macOS 15+. Requires a Linux builder (see README). |

On macOS the VMs run as `aarch64-linux` guests, so only distributions that publish
an `aarch64` image are available there. **Arch Linux is x86_64-only and is therefore
not exposed on `aarch64-darwin`**, and Fedora is only available as release 43 there
(older aarch64 releases are no longer on the release mirror). The Rocky 9.0
aarch64 image is skipped (it is damaged), and so are the 8.x ones on `aarch64-darwin`
(they need 64 KB pages, which Apple Silicon lacks).

Where `$DISTRIBUTION` is a `$NAME.$VERSION` couple. Here's the currently supported name/version couples:

| Name   | Version |
| ------ | ------- |
| debian | "12"    |
| debian | "13"    |
| ubuntu | "20_04" |
| ubuntu | "22_04" |
| ubuntu | "22_10" |
| ubuntu | "23_04" |
| ubuntu | "23_10" |
| fedora | "38"    |
| fedora | "39"    |
| yocto  | "6_0"   |
| yocto  | "6_1"   |

#### Inputs

A Nix attribute set, as described in the  [Nix manual](https://nixos.org/manual/nix/stable/language/values.html?highlight=attribute%20set#attribute-set), is used to configure the VM test. The API is consistent across all the supported distributions.

For instance:

```nix
{
  diskSize = "+2M";
  sharedDirs = {
    shareName = {
      source = "/home/numtide/share";
      target = "/mnt";
    };
  };
  testScript = ''
    vm.wait_for_unit("multi-user.target")
    vm.succeed("apt-get update")
  '';
}
```

Where:

| Attribute Name | Description                                                                                                                                                                                                                                                                         | Example           |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| diskSize       | Resize the guest root partition to a new size. That size can be either absolute (EG. `2G`, `800M`) or relative to the original size (EG. `+500M`, `+2G`)                                                                                                                            | +2G               |
| sharedDirs     | This attribute set describes the host directories that will be mounted to the guest filesystem. `source` being the host directory, `target` being the path we want to mount the directory on the VM.                                                                                | See above example |
| memorySize     | Memory available to the guest VM, in MiB. Defaults to 1024.                                                                                                                                                                                                                          | 2048              |
| cpus           | Number of virtual CPUs available to the guest VM. Defaults to 2.                                                                                                                                                                                                                     | 4                 |
| selinuxEnforcing | Fedora and Rocky only. Boot with SELinux in enforcing mode instead of permissive. Defaults to `true` on Rocky and `false` on Fedora. | `false` |
| testScript     | A Python script used to orchestrate the integration test. This is compatible with NixOS tests. You can have a look at the [relevant NixOS manual section](https://nixos.org/manual/nixos/stable/#ssec-machine-objects) to get the reference documentation of the available methods. | See above example |
| extraPathsToRegister | Store paths registered in the guest's Nix database once the store is mounted, so a test may run them. | `[ pkgs.hello ]` |
| extraQemuArgs  | Arguments appended to the qemu command line, to attach a device the image expects beside the rootfs. | `[ "-device nvme,drive=data,serial=data" ]` |

These are accepted by `yocto` only:

| Attribute Name | Description | Example |
| -------------- | ----------- | ------- |
| extraRootModules | Kernel modules added to the stage-1 initrd, for an image whose fstab names a device the default set does not reach. Yocto-only because it is the only target that boots a kernel and initrd of our own rather than the image's. | `[ "nvme" ]` |
| maskedUnits    | Units linked to /dev/null in the image, for services bound to hardware a VM has no equivalent for. The other targets prepare their images with `virt-customize`, so sharing this means teaching each of them the same `--link` call. | `[ "docker.service" ]` |
| guestPackages  | Packages whose `bin` goes on the PATH of the root shell the driver runs commands through. Defaults to `[ netcat-openbsd ]`, which `wait_for_open_port` needs. An empty list adds nothing. Sharing this means wiring `extraPath` through each target's backdoor script, which `fedora`, `rocky` and `archlinux` each copy differently. | `[ pkgs.jq ]` |

#### Outputs

```nix
let
vmTest = nix-vm-test.debian."12" {
  diskSize = "+2M";
  sharedDirs = {
    shareName = {
      source = "/home/numtide/share";
      target = "/mnt";
    };
  };
  testScript = ''
    vm.wait_for_unit("multi-user.target")
    vm.succeed("apt-get update")
  '';
  };
interactive = vmTest.driverInteractive;
driver = vmTest.driver;
driverInSandbox = vmTest.sandbox;
in ...
```

| Output "Path"     | Description                                                                                                                                                                                                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| driver            | Run the test non-interactively. The VM will be able to reach the internet via a NAT interface with the host. This is likely the mode you want to use on your CI.                                                                                                                                      |
| driverInteractive | Run the test interactively. An interactive IPython console will open. You can interactively run the Python commands through this console. A qemu window also opens up, allowing you to directly interact with the VM shell. You can log in to the VM through the root account with an empty password. |
| sandbox           | Run the test non-interactively in the Nix sandbox. ⚠️ The Nix sandbox completely isolate the VM. You won't be able to have any network access, reach the Internet or use the host mounts with that mode                                                                                               |

## Yocto

`yocto."6_0"` (the LTS) and `yocto."6_1"` work like the other distributions. They are
`core-image-full-cmdline` from the Yocto Project's `-alt` (systemd) release builds, for
`x86_64-linux` and `aarch64-linux`:

```nix
nix-vm-test.lib.x86_64-linux.yocto."6_0" {
  extraPathsToRegister = [ pkgs.hello ];
  testScript = ''
    vm.wait_for_unit("multi-user.target")
    vm.succeed("${pkgs.hello}/bin/hello")
  '';
}
```

The Yocto Project publishes a rootfs per release, not a bootable disk, and its qemu kernels
lack 9p, which the store mount needs. The disk is therefore the rootfs alone, and qemu boots
the nixpkgs kernel directly with an initrd that loads the virtio, 9p and overlay modules and
switches to the rootfs. The userland under test is Yocto's; the kernel is not. The backdoor and
store units are written into the ext4 with `debugfs`, so preparing an image needs no
libguestfs and works for `aarch64-linux` too. `diskSize` is not supported.

### Your own image

Every image recipe produces a `rootfs.ext4`; `fromRootfs` builds the same disk around it as for
`yocto."6_0"`, so a team's existing recipes need no change beyond systemd and `bash`:

```nix
nix-vm-test.lib.x86_64-linux.yocto.fromRootfs {
  rootfs = ./my-image-qemux86-64.rootfs.ext4;   # or .ext4.zst
  testScript = ''
    vm.wait_for_unit("multi-user.target")
  '';
}
```

`extraRootModules` adds kernel modules to the stage-1 initrd, and `extraQemuArgs` adds qemu
arguments, for an image whose own fstab names devices beside the rootfs:

```nix
nix-vm-test.lib.aarch64-linux.yocto.fromRootfs {
  rootfs = ./my-image.rootfs.ext4;
  extraRootModules = [ "nvme" ];
  extraQemuArgs = [
    "-drive file=${./data-disk.img},format=raw,if=none,id=data"
    "-device nvme,drive=data,serial=data"
  ];
  maskedUnits = [ "docker.service" "ptp4l@eth0.service" ];
  testScript = "vm.wait_for_unit(\"multi-user.target\")";
}
```

`maskedUnits` links a unit to /dev/null in the image, the same way the serial gettys are
masked. A vendor image is full of services bound to hardware a VM has no equivalent for, and
they restart for as long as the test runs, so `multi-user.target` never settles.

When a guest drops to emergency mode, look for `Expecting device ...` and a 90 second wait in
the console log: the image wants a device this VM does not have. Either attach it with
`extraQemuArgs` and name its driver in `extraRootModules`, or mask the unit that pulls it in.
The driver reports this as `Guest root shell did not produce any data yet`, which says nothing
about the cause.

`guestPackages` puts a `buildEnv` of the packages it names on the PATH of the root shell the
driver runs commands through, and registers that env with the store mount. The image itself is
not touched, so a base image that already ships /usr/local/bin keeps it, and an empty list adds
nothing to the closure. Note the scope: this is the test's PATH, not the PATH of services
running inside the guest. It defaults to
`[ netcat-openbsd ]` because the driver's `wait_for_open_port` runs `nc -z` in the guest, and
the busybox and toybox `nc` these images ship take no `-z`: without a real netcat that call
prints usage in a loop until its timeout rather than failing. The same argument serves a test
that needs `getent`, `getcap` or `jq` from a distro that ships none of them.

To use the image's own kernel and bootloader, pass a bootable disk instead:

```nix
nix-vm-test.lib.x86_64-linux.yocto.custom {
  image = ./my-image.wic.qcow2;
  testScript = ''
    vm.wait_for_unit("multi-user.target")
  '';
}
```

`image` is a qcow2 disk carrying its own bootloader, attached as an IDE disk and booted with
SeaBIOS, so a `wic` layout with `bootimg-pcbios` and `--ondisk sda` works. The preparation step
only copies files into the image (`virt-customize --copy-in/--link/--mkdir`), no guest binary
runs, so a read-only rootfs is fine. x86_64 only: libguestfs has no aarch64 appliance in nixpkgs
and the `virt` machine needs UEFI firmware for a bootloader disk; `fromRootfs` covers aarch64.
`bootArgs` passes extra qemu arguments; `yocto.bootArgs { mountStore = false; root = "/dev/sda2"; }`
is the nixpkgs kernel and initrd for a disk whose own kernel cannot mount the store, `root` naming
the rootfs partition.

What the image must provide:

- systemd as init;
- `bash` (`IMAGE_INSTALL:append = " bash"`): the backdoor execs `/usr/bin/env bash`;
- a kernel with virtio, 9p (`CONFIG_NET_9P_VIRTIO`, `CONFIG_9P_FS`), virtio-console and
  overlayfs. The `linux-yocto` qemu kernels do not enable 9p; `features/9p/9p.scc` adds it;
- a serial console on `ttyS0`, used by the test driver.

On a read-only rootfs the preparation step creates the directories the store mount needs under
`/nix`, and `nix-var.service` mounts a tmpfs on `/nix/var` unless the image mounted something
there itself, so `extraPathsToRegister` can be loaded into the Nix database.

### Rebooting inside a test

`vm.reboot()` needs the machine started with `vm.start(allow_reboot=True)`; otherwise qemu runs
with `-no-reboot` and exits. Disk writes are discarded when the VM exits, but survive a reboot.
It presses ctrl-alt-delete on the guest keyboard, which the aarch64 `virt` machine does not have;
there, `vm.succeed("systemctl reboot")` followed by `vm.connected = False` does the same.

aarch64 here is what the Yocto target needs (`-machine virt`, a virtio disk, `ttyAMA0`) and
nothing more; the other targets gain aarch64 in
[#203](https://github.com/numtide/nix-vm-test/pull/203), which this follows.
