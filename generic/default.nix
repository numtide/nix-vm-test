{ lib, hostPkgs, guestPkgs, nixpkgs, ... }:
rec {
  # `hostPkgs`  : packages that run on the machine driving the test (QEMU, the
  #               Python test-driver, the run-vm wrapper script). On a Linux host
  #               this is the same as `guestPkgs`; on darwin it is a darwin set.
  # `guestPkgs` : packages that run *inside* the Linux guest or are baked into the
  #               image (backdoor shell, `nix-store`, image preparation). These must
  #               always be Linux packages, so on darwin they are built for the
  #               matching `*-linux` system (via a Linux/remote builder).
  qemuArch = guestPkgs.stdenv.hostPlatform.qemuArch;
  guestIsAarch64 = guestPkgs.stdenv.hostPlatform.isAarch64;
  hostIsDarwin = hostPkgs.stdenv.hostPlatform.isDarwin;
  serialConsole = if guestIsAarch64 then "ttyAMA0" else "ttyS0";

  defaultMachineConfigModule = { ... }: {
    nodes = {
    };
  };
  printAttrPos = { file, line, column }: "${file}:${toString line}:${toString column}";

  # Careful since we do not have the nix store yet when this service runs,
  # so we cannot use guestPkgs.writeText or guestPkgs.writeShellScript for instance,
  # since their results would refer to the store
  mountStore = { pathsToRegister ? [ ] }:
    let
      pathRegistrationInfo = "${guestPkgs.closureInfo { rootPaths = pathsToRegister; }}/registration";
    in
    guestPkgs.writeText "mount-store.service" ''
      [Service]
      Type = oneshot
      User = root
      ExecStart = /bin/sh -euc ' \
        mkdir -p /nix/.ro-store; \
        mount -t 9p -o defaults,trans=virtio,version=9p2000.L,cache=loose,msize=${toString (256 * 1024 * 1024)} nix-store /nix/.ro-store; \
        mkdir -p -m 0755 /nix/.rw-store/ /nix/store; \
        mount -t tmpfs -o size=2G tmpfs /nix/.rw-store; \
        mkdir -p -m 0755 /nix/.rw-store/store /nix/.rw-store/work; \
        mount -t overlay overlay /nix/store -o lowerdir=/nix/.ro-store,upperdir=/nix/.rw-store/store,workdir=/nix/.rw-store/work${lib.optionalString (pathsToRegister != []) "; ${lib.getBin guestPkgs.nix}/bin/nix-store --load-db < ${pathRegistrationInfo}"}'
      [Install]
      WantedBy = multi-user.target
    '';

  backdoorScript = guestPkgs.writeShellScript "backdoor-start-script" ''
    set -euo pipefail

    ProtectSystem=false
    export USER=root
    export HOME=/root
    export DISPLAY=:0.0

    # TODO: do we actually need to source /etc/profile ?
    # Unbound vars cause the service to crash
    #source /etc/profile

    # Don't use a pager when executing backdoor
    # actions. Because we use a tty, commands like systemctl
    # or nix-store get confused into thinking they're running
    # interactively.
    export PAGER=

    cd /tmp
    exec < /dev/hvc0 > /dev/hvc0
    while ! exec 2> /dev/${serialConsole}; do sleep 0.1; done
    echo "connecting to host..." >&2
    stty -F /dev/hvc0 raw -echo # prevent nl -> cr/nl conversion
    # This line is essential since it signals to the test driver that the
    # shell is ready.
    # See: the connect method in the Machine class.
    echo "Spawning backdoor root shell..."
    # Passing the terminal device makes bash run non-interactively.
    # Otherwise we get errors on the terminal because bash tries to
    # setup things like job control.
    PS1= exec /usr/bin/env bash --norc /dev/hvc0
  '';

  # Backdoor service that exposes a root shell through a socket to the test instrumentation framework
  # `withMountedStore`: some distros (primarily rhel and rhel clones)
  #                     have support for 9P filesystem disabled so we
  #                     cannot mount nix store _at the moment_.
  # `scriptPath`: in case `withMountedStore` is set to `false`, the
  #               script needs to be copied to the VM and the path of
  #               the backdoor script changes, allow the "builder"
  #               to specify it
  backdoor = { withMountedStore ? true, scriptPath ? backdoorScript }:
    guestPkgs.writeText "backdoor.service" ''
      [Unit]
      Requires = dev-hvc0.device dev-${serialConsole}.device ${lib.strings.optionalString withMountedStore "mount-store.service"}
      After = dev-hvc0.device dev-${serialConsole}.device ${lib.strings.optionalString withMountedStore "mount-store.service"}
      # Keep this unit active when we switch to rescue mode for instance
      IgnoreOnIsolate = true

      [Service]
      ExecStart = ${scriptPath}
      KillSignal = SIGHUP

      [Install]
      WantedBy = multi-user.target
    '';

    # Baked (x86_64) path only: the aarch64/cloud-init path relies on cloud-init's
    # own default growpart/resizefs modules instead (see ubuntu/default.nix).
    resizeService = guestPkgs.writeText "resizeService" ''
      [Service]
      Type = oneshot
      ExecStart = apt-get install -yq cloud-guest-utils
      ExecStart = growpart /dev/sda 1
      ExecStart = resize2fs /dev/sda1

      [Install]
      WantedBy = multi-user.target
    '';

  # Build a cloud-init NoCloud seed ISO. Used on darwin/aarch64 where `guestfs`
  # (and therefore `virt-customize`) is unavailable: instead of baking the guest
  # customization into the image ahead of time, we attach this seed at VM launch
  # and let cloud-init apply it on boot.
  #
  # `files`    : attrset of `<name-on-seed> = <store path>`; copied verbatim onto
  #              the seed so `runcmd` can install them into the guest.
  # `userData` : the cloud-config (`#cloud-config …`) YAML string.
  #
  # The seed is a plain ISO9660 volume labelled CIDATA, which cloud-init's NoCloud
  # datasource discovers automatically on any attached block device.
  mkCloudInitSeed = { files ? { }, userData }:
    guestPkgs.runCommand "cloud-init-seed.iso"
      { nativeBuildInputs = [ guestPkgs.cdrkit ]; }
      ''
        mkdir -p seed
        printf 'instance-id: iid-nixvmtest\nlocal-hostname: vm\n' > seed/meta-data
        cp ${guestPkgs.writeText "user-data" userData} seed/user-data
        ${lib.concatStrings (lib.mapAttrsToList (name: src: "cp ${src} seed/${name}\n") files)}
        ( cd seed && genisoimage -output "$out" -volid CIDATA -joliet -rock * )
      '';

  # Assemble a `#cloud-config` user-data document. `runcmd` is a list of shell
  # command strings run (in order, as root) on boot. Guest customization files are
  # shipped on the seed (see `mkCloudInitSeed`'s `files`) and installed by `runcmd`,
  # which keeps this pure (no import-from-derivation of file contents).
  # Each command is emitted via `builtins.toJSON` (a valid YAML double-quoted
  # scalar) rather than as a raw plain scalar, so a command containing a
  # leading '#' or ': ' can't be misparsed as a YAML comment/mapping.
  mkUserData = { runcmd ? [ ] }:
    lib.concatStringsSep "\n" (
      [ "#cloud-config" ]
      ++ lib.optionals (runcmd != [ ]) ([ "runcmd:" ] ++ map (c: "  - ${builtins.toJSON c}") runcmd)
    );

  makeVmTest =
    { image
    , testScript
    , sharedDirs
    , machineConfigModule ? defaultMachineConfigModule
    , memorySize ? null
    , cpus ? null
    , name ? "vm-test"
    # Optional cloud-init NoCloud seed ISO (see `mkCloudInitSeed`). When set, it is
    # attached as an extra drive so cloud-init customizes the guest on boot. Used
    # on darwin/aarch64 in place of the baked `virt-customize` image.
    , cloudInitSeed ? null
    }:
    let
      mountSharesScript = hostPkgs.writeScriptBin "mount-shares" {} ''
      '';

      # TODO: hacky hacky… We need to mount the 9p shares at some
      # point, however, doing so in the image generation phase would
      # force us to rebuild images for each and every mount topology.
      #
      # Doing this from the test driver itself saves us this rebuild.
      # However, the 9p shares won't be mounted in the interactive
      # test driver by default.
      #
      # There must be a better hook for this.
      testScriptWithMounts = ''
        ${lib.concatStringsSep "\n"
        (lib.mapAttrsToList
        (tag: share:
        "vm.succeed('mkdir -p ${share.target} && mount -t 9p -o defaults,trans=virtio,version=9p2000.L,cache=loose,msize=${toString (256 * 1024 * 1024)} ${tag} ${share.target}')")
        sharedDirs)}
      '' + testScript;

      config = (lib.evalModules {
        modules = [
          (./module.nix)
          ({ config, ... }: { nodes.vm.virtualisation.sharedDirectories = sharedDirs; })
          ({ ... }: {
            nodes.vm.virtualisation =
              lib.optionalAttrs (memorySize != null) { inherit memorySize; }
              // lib.optionalAttrs (cpus != null) { inherit cpus; };
          })
          machineConfigModule
          {
            _file = "${printAttrPos (builtins.unsafeGetAttrPos "a" { a = null; })}: inline module";
          }
        ];
      }).config;

      nodes = interactive: lib.mapAttrs
        (name: node: { inherit name; start_script = runVmScript interactive node; })
        config.nodes;

      runVmScript = interactive: node:
      let
        qemupkg = (if !interactive then hostPkgs.qemu_test else hostPkgs.qemu);

        # On darwin we accelerate with Apple's Hypervisor.framework (HVF); on Linux
        # with KVM. We only ever pair a host with a same-architecture Linux guest
        # (e.g. aarch64-darwin → aarch64-linux), so hardware acceleration always applies.
        accel = if hostIsDarwin then "hvf" else "kvm";

        qemuBinary = "${lib.getBin qemupkg}/bin/qemu-system-${qemuArch}";

        machineFlags =
          if guestIsAarch64 then
            [ "-machine virt,accel=${accel}" ]
          else
            [ "-machine accel=${accel}" ];

        firmwareFlags = lib.optionals guestIsAarch64 [
          "-drive if=pflash,format=raw,unit=0,readonly=on,file=${qemupkg}/share/qemu/edk2-aarch64-code.fd"
          "-drive if=pflash,format=raw,unit=1,file=\"$TMPDIR/efivars.fd\""
        ];

        diskFlags =
          if guestIsAarch64 then
            [ "-drive if=none,file=${image},format=qcow2,id=disk0"
              "-device virtio-blk-pci,drive=disk0"
            ]
          else
            [ "-drive file=${image},format=qcow2" ];

        # Attach the cloud-init NoCloud seed (read-only) when provided.
        seedFlags = lib.optionals (cloudInitSeed != null) [
          "-drive if=none,id=cidata,format=raw,readonly=on,file=${cloudInitSeed}"
          "-device virtio-blk-pci,drive=cidata"
        ];

        # On aarch64 UEFI, disable the NIC's option ROM via romfile=. Without this,
        # every boot prints "Image type X64 can't be loaded on AARCH64 UEFI system."
        # while EDK2 tries (and fails) to load the ROM's x86 EFI section — harmless
        # (the disk still boots normally) but noisy on every single boot. We never
        # PXE-boot, so dropping the ROM outright is safe and removes the warning.
        netDevFlag =
          if guestIsAarch64 then
            "-device virtio-net-pci,netdev=net0,romfile="
          else
            "-device virtio-net-pci,netdev=net0";

        # The test driver extracts the name of the node from the name of the
        # VM script, so it's important here to stick to the naming scheme expected
        # by the test driver.
      in hostPkgs.writeShellScript "run-vm-vm"
         ''
          set -eo pipefail

          export PATH=${lib.makeBinPath [ hostPkgs.coreutils ]}''${PATH:+:}$PATH

          # Create a directory for storing temporary data of the running VM.
          if [ -z "$TMPDIR" ] || [ -z "$USE_TMPDIR" ]; then
            TMPDIR=$(mktemp -d nix-vm.XXXXXXXXXX --tmpdir)
          fi

          # Associative array containing the absolute mount points for
          # all the shares.
          #
          # We absolutely need to resolve the relative paths using
          # $rundir as a root. $rundir is the directory in which
          # the test driver has been started (variable set by runTest).
          pushd "''${rundir}"
          declare -A abs_mnt_paths
          ${lib.concatStringsSep "\\\n "
            (lib.mapAttrsToList
              (tag: share: "abs_mnt_paths[\"${tag}\"]=\"$(realpath \"${share.source}\")\"")
            node.virtualisation.sharedDirectories)
          }
          popd

          # Create a directory for exchanging data with the VM.
          mkdir -p "$TMPDIR/xchg"

          cd "$TMPDIR"
          ${lib.optionalString guestIsAarch64 ''
            # Writable UEFI variable store for the aarch64 firmware above. A blank
            # 64 MiB NVRAM matches the code image size; -snapshot keeps it ephemeral.
            truncate -s 64M "$TMPDIR/efivars.fd"
          ''}

          # Start QEMU.
          ${lib.concatStringsSep "\\\n  " ([
            "exec ${qemuBinary}"
          ] ++ machineFlags ++ [
            "-device virtio-rng-pci"
            "-cpu max"
            "-name vm"
            "-m ${toString node.virtualisation.memorySize}"
            "-smp ${toString node.virtualisation.cpus}"
          ] ++ firmwareFlags ++ diskFlags ++ seedFlags ++ [
            netDevFlag
            "-netdev user,id=net0"
            "-virtfs local,security_model=passthrough,id=fsdev1,path=/nix/store,readonly=on,mount_tag=nix-store"
            (lib.concatStringsSep "\\\n  "
              (lib.mapAttrsToList
              (tag: share: "-virtfs local,path=\"\${abs_mnt_paths[\"${tag}\"]}\",security_model=none,mount_tag=${tag}")
                  node.virtualisation.sharedDirectories))
            "-snapshot"
            (lib.optionalString (!interactive) "-nographic")
            "$QEMU_OPTS"
            "$@"
          ])};
        '';

      test-driver =
        (hostPkgs.python3Packages.callPackage "${nixpkgs}/nixos/lib/test-driver"
          # `vhost-device-vsock` is a Linux-only dependency of the test driver (used
          # for the vsock SSH backdoor). We never enable that backdoor
          # (`enable_ssh_backdoor = false`), so on darwin we swap it for a harmless
          # stand-in to keep the driver evaluatable. On Linux the real dep is used.
          (lib.optionalAttrs hostIsDarwin {
            vhost-device-vsock = hostPkgs.emptyDirectory;
          })
        ).overrideAttrs (old: {
          # `vlan.py`'s `_log_stream` forwards the vde_switch / vde_plug2tap pipes to
          # `logger.debug()` but decodes them as STRICT UTF-8.
          postPatch = (old.postPatch or "") + ''
            vlan=$(find . -path '*test_driver/vlan.py' | head -n1)
            substituteInPlace "$vlan" \
              --replace-fail ${lib.escapeShellArg "text=True,"} ${lib.escapeShellArg "text=True,\n            errors=\"replace\","}
          '';
        });

      # create configuration file based on test driver configuration
      # see https://github.com/NixOS/nixpkgs/blob/6ab8a6fd46fa56298ad16ec9b36cf6ab04413459/nixos/lib/test-driver/src/test_driver/driver.py#L38
      driverConfigFile = { vlans, interactive }:
        hostPkgs.writers.writeJSON "driver-configuration.json" {
          vms = nodes interactive;
          containers = { };
          inherit vlans;
          global_timeout = 60 * 60;
          enable_ssh_backdoor = false;
          test_script = hostPkgs.writeText "test-script" testScriptWithMounts;
        };

      runTest = { vlans, interactive }: ''
        # Exporting the current directory. The start script need it to
        # resolve the relative mount points.
        export rundir="$(pwd)"
        ${lib.getBin test-driver}/bin/nixos-test-driver \
          ${lib.optionalString interactive "--interactive"} \
          -c ${driverConfigFile { inherit vlans interactive; }}
      '';

      defaultTest = { interactive ? false }: runTest {
        inherit interactive;
        vlans = [ 1 ];
      };

      targets =
        let
          passthru = { inherit targets; };
        in
        {
          sandboxed = hostPkgs.stdenv.mkDerivation {
            # KVM on Linux, Apple's Hypervisor.framework on darwin.
            requiredSystemFeatures = [ "nixos-test" ]
              ++ lib.optional hostIsDarwin "apple-virt"
              ++ lib.optional (!hostIsDarwin) "kvm";
            buildCommand = ''
              ${defaultTest {}}
              touch $out
            '';
            inherit name passthru;
          };

          driver = (hostPkgs.writeShellScriptBin "test-driver"
            (defaultTest {
              interactive = false;
            })
          ).overrideAttrs (prevAttrs: {
            passthru = (prevAttrs.passthru or { }) // passthru;
          });

          driverInteractive = (hostPkgs.writeShellScriptBin "test-driver"
            (defaultTest {
              interactive = true;
            })
          ).overrideAttrs (prevAttrs: {
            passthru = (prevAttrs.passthru or { }) // passthru;
          });
        };
    in
    {
      inherit (targets) sandboxed driver driverInteractive;
    };
}
