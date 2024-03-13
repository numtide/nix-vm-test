# Getting Started

In this getting started tutorial, we create a VM test in charge of installing the gnu hello package on a Debian 13 machine.

## Prerequisites

To follow this tutorial, you'll need:

1. A **Linux** system with Nix installed on top of it. See [this page](https://zero-to-nix.com/start/install) to see how to install Nix on your system.
2. Enabling the hardware KVM acceleration on your system. Without hardware acceleration, the VM tests will likely be unbearably slow to run. This is usually done on your computer through UEFI menu settings.

You can check whether you have hardware-accelerated KVM support using the following command:

```sh
$ LC_ALL=C.UTF-8 lscpu | grep Virtualization
```

This command should output something if hardware-accelerated KVM is enabled on your system, nothing if it's not.

For more information about whether your processor supports hardware-accelerated KVM, and if so, hw to enable it, see [this article](https://www.speaknetworks.com/enable-intel-vt-amd-v-support-hardware-accelerated-kvm-virtualization-extensions/)

## Setting up the Project

First, we're going to create a new directory for this project, and create an empty git repository inside it. This example puts the project under /tmp, but you may want to put it somewhere else if you want to keep it.

```sh
$ cd /tmp
$ mkdir -p nix-vm-test-tutorial
$ cd nix-vm-test-tutorial
$ git init .
```

The last command should print that a new git repository has been created.

Let's create an empty Nix flake:

```sh
$ nix flake init
```

You now should have a `flake.nix` file in the current directory.

Let's edit this flake to add `nix-vm-tests` in its inputs:

```diff
   inputs = {
     nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
+    nix-vm-test.url = "github:numtide/nix-vm-test";
   };

-  outputs = { self, nixpkgs }: {
+  outputs = { self, nixpkgs, nix-vm-test }: {

     packages.x86_64-linux.hello = nixpkgs.legacyPackages.x86_64-linux.hello;
```

Let's fetch the input and build this dummy default derivation to make sure everything is fine:

```nix
git add flake.nix
nix build .\#
```

This command should have created a `flake.lock` lockfile and a `./result` symlink pointing to the gnu hello binary.

Alright, let's commit this and jump right onto the fun part :)

```nix
git commit -m "init"
```

## Write an Actual Test

In this section, we're writing a VM test in which we install a `.deb` package.

First of all, let's do our homework and download the gnu hello `.deb` package from this URL: http://ftp.fr.debian.org/debian/pool/main/h/hello/. Look for an amd64 version of gnu hello on the previously linked page then download it in the project directory:

```sh
# Replace the hello fetch URL with the current hello version one.
$ curl "http://ftp.fr.debian.org/debian/pool/main/h/hello/hello_2.10-3_amd64.deb" > hello.deb
$ git add hello.deb
```

⚠️ Don't forget to `git add` the file to your git repository.

Let's edit the `flake.nix` file to add a new test. Don't worry, you don't have to understand everything yet, we're going to detail the content of this file.

```nix
{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    nix-vm-test.url = "github:numtide/nix-vm-test";
  };

  outputs = { self, nixpkgs, nix-vm-test }: {

    packages.x86_64-linux.test-vm =
      let
        vmTest = nix-vm-test.lib.x86_64-linux.debian."13" {
          sharedDirs = {
            debDir = {
              source = "${./.}";
              target = "/mnt/debdir";
            };
          };
          testScript = ''
            vm.wait_for_unit("multi-user.target")
            vm.succeed("apt-get -yq install /mnt/debdir/hello.deb")
          '';
        };
        in vmTest.driverInteractive;

    packages.x86_64-linux.default = self.packages.x86_64-linux.test-vm;

  };
}
```

Copy this snippet to your `flake.nix` file.

Before running anything, let's examine this snippet in smaller bits:

```nix
vmTest = nix-vm-test.lib.x86_64-linux.debian."13" {
```

Here, we select the Debian 13 VM test runner. We apply this test runner function to an attributeset containing two keys:

```nix
sharedDirs = {
  debDir = {
    source = "${./.}";
    target = "/mnt/debdir";
  };
};
```

The `sharedDirs` key lists the shared directories between the host machine and the target VM. This is really handy for injecting files into the VM. We're using this shared directory to inject the `hello.deb` file to the VM.

Then, there's the `testScript` key:

```nix
testScript = ''
  vm.wait_for_unit("multi-user.target")
  vm.succeed("apt-get -yq install /mnt/debdir/hello.deb")
'';
```

This is a Python script used to specify the commands we should run in the VM for the test. Two commands are used:

- `wait_for_unit("multi-user.target")`: this command will make the test runner to wait for the systemd unit `multi-user.target` to be activated. `multi-user.target` is activated when all the services required for a functional non-graphical multi-user system are started. It's a proxy for "wait until the machine fully booted" as far as we are concerned.
- `succeed("apt-get -yq install /mnt/debdir/hello.deb")` executes the `apt-get -yq install /mnt/debdir/hello.deb` command and verify it did succeed.

Finally, we have:

```nix
in vmTest.driverInteractive;
```

This bit selects what kind of test driver we want to use. Here, we select the interactive test driver. It's usually the test driver we use to write our test and make sure everything works as expected.

Alright, enough theory, time for the exciting stuff. Let's run this test!!

```nix
$ nix build .# -L
$ ./result/bin/test-driver
```

You should see an interactive Python console opening in your terminal. This console is the interactive test runner. The list of the available top-level symbols should be printed just before the prompt.

Type `vm.` in the prompt. An autocomplete popup should appear and show you the available operations to control the VM.

Clear the prompt and type `run_tests()`, then press enter.

A new qemu window should open. This window displays a terminal to the VM we just started. In the meantime, the test scenario is played in the test runner terminal.

The test should succeed, in the test runner terminal, you should get those two final lines:

```
(finished: must succeed: apt-get -yq install /mnt/debdir/hello.deb, in 2.63 seconds)
(finished: run the VM test script, in 40.17 seconds)
```

and a new prompt.

NICE! It seems like our test succeeded on the first try. How lucky! 😉

The VM should still be alive, its window should also still be there.

Try to log in the VM. The VMs provisioned by `nix-vm-test` all have a `root` user not protected by any password.

Type `root` to log in the VM. You should be greeted with a `root@localhost` prompt. We now have an interactive shell to the test VM.

Let's double-check the hello deb file has been correctly installed.

Type `hello` in the prompt. The hello program should respond with a:

```
Hello, world!
```

Nice! It seems it's been correctly installed.

Mhhh, this sounds like a convenient extra check to add to our test scenario! Let's edit the test in the `flake.nix` file and add a check making sure the `hello` command is there:

```diff
         vm.wait_for_unit("multi-user.target")
         vm.succeed("apt-get -yq install /mnt/debdir/hello.deb")
+        vm.succeed("hello")
```

Overall, when developing a new VM test, this is the recommended workflow: first create an interactive test. Script it, run it. If it succeeds, log into the machine, check how you could improve it, add the new commands to the script, and start again. If it fails, log into the machine, figure out what's happening, alter the test script, and re-run the test from scratch.

Okay, we're done with this test. We now want to run that on CI. We definitely do not want an interactive test there. Let's alter the flake to replace the interactive test driver with a noninteractive one.

```diff
         };
-        in vmTest.driverInteractive;
+        in vmTest.driver;
```

Let's build the test runner:

```sh
$ nix build .\# -L
```

A new `result` symlink should appear.

Let's run the non-interactive test runner on our machine to check it works as expected:

```sh
$ ./result/bin/test-driver
```

The test will run in the console. We won't have any VM window this time.

The test should succeed and end with something like:

```
(finished: must succeed: apt-get -yq install /mnt/debdir/hello.deb, in 2.43 seconds)
vm: must succeed: hello
(finished: must succeed: hello, in 0.00 seconds)
(finished: run the VM test script, in 32.95 seconds)
test script finished in 33.07s
cleanup
kill machine (pid 8248)
vm # qemu-kvm: terminating on signal 15 from pid 8245 (/nix/store/y027d3bvlaizbri04c1bzh28hqd6lj01-python3-3.11.7/bin/python)
(finished: cleanup, in 0.04 seconds)
kill vlan (pid 8246)
```

Nice, we're done! All we have to do now is run those exact same two commands:

```sh
$ nix build .\# -L
$ ./result/bin/test-driver
```

on your CI.
