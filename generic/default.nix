{ lib, pkgs, nixpkgs }:
rec {
  defaultMachineConfigModule = name: { ... }: {
    nodes = {
      vm.system.name = name;
    };
  };
  printAttrPos = { file, line, column }: "${file}:${toString line}:${toString column}";

  # Careful since we do not have the nix store yet when this service runs,
  # so we cannot use pkgs.writeTest or pkgs.writeShellScript for instance,
  # since their results would refer to the store
  mountStore = { pkgs, pathsToRegister}:
    let
      pathRegistrationInfo = "${pkgs.closureInfo { rootPaths = pathsToRegister; }}/registration";
    in
    pkgs.writeText "mount-store.service" ''
      [Service]
      Type = oneshot
      ExecStart = mkdir -p /nix/.ro-store
      ExecStart = mount -t 9p -o defaults,trans=virtio,version=9p2000.L,cache=loose,msize=${toString (256 * 1024 * 1024)} nix-store /nix/.ro-store
      ExecStart = mkdir -p -m 0755 /nix/.rw-store/ /nix/store
      ExecStart = mount -t tmpfs tmpfs /nix/.rw-store
      ExecStart = mkdir -p -m 0755 /nix/.rw-store/store /nix/.rw-store/work
      ExecStart = mount -t overlay overlay /nix/store -o lowerdir=/nix/.ro-store,upperdir=/nix/.rw-store/store,workdir=/nix/.rw-store/work

      # Register the required paths in the nix DB.
      # The store has been mounted at this point, to we can use writeShellScript now.
      ExecStart = ${pkgs.writeShellScript "execstartpost-script" ''
        ${lib.getBin pkgs.nix}/bin/nix-store --load-db < ${pathRegistrationInfo}
      ''}

      [Install]
      WantedBy = multi-user.target
    '';

  # Backdoor service that exposes a root shell through a socket to the test instrumentation framework
  backdoor = { pkgs }:
    pkgs.writeText "backdoor.service" ''
      [Unit]
      Requires = dev-hvc0.device dev-ttyS0.device mount-store.service
      After = dev-hvc0.device dev-ttyS0.device mount-store.service
      # Keep this unit active when we switch to rescue mode for instance
      IgnoreOnIsolate = true

      [Service]
      ExecStart = ${pkgs.writeShellScript "backdoor-start-script" ''
        set -euo pipefail

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
        while ! exec 2> /dev/ttyS0; do sleep 0.1; done
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
      ''}
      KillSignal = SIGHUP

      [Install]
      WantedBy = multi-user.target
    '';

  makeVmTest =
    { system
    , image
    , testScript
    , sharedDirs
    , machineConfigModule ? (defaultMachineConfigModule name)
    , name
    }:
    let
      hostPkgs = pkgs;

      mountSharesScript = pkgs.writeScriptBin "mount-shares" {} ''
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
        "${name}.succeed('mkdir -p ${share.target} && mount -t 9p -o defaults,trans=virtio,version=9p2000.L,cache=loose,msize=${toString (256 * 1024 * 1024)} ${tag} ${share.target}')")
        sharedDirs)}
      '' + testScript;

      config = (lib.evalModules {
        modules = [
          (./module.nix)
          ({ config, ... }: { nodes.vm.virtualisation.sharedDirectories = sharedDirs; })
          machineConfigModule
          {
            _file = "${printAttrPos (builtins.unsafeGetAttrPos "a" { a = null; })}: inline module";
          }
        ];
      }).config;

      nodes = interactive: map (runVmScript interactive) (lib.attrValues config.nodes);

      runVmScript = interactive: node:
      let
        qemupkg = (if !interactive then hostPkgs.qemu_test else hostPkgs.qemu);
        # The test driver extracts the name of the node from the name of the
        # VM script, so it's important here to stick to the naming scheme expected
        # by the test driver.
      in hostPkgs.writeShellScript "run-${node.system.name}-vm"
         ''
          set -eo pipefail

          export PATH=${lib.makeBinPath [ hostPkgs.coreutils ]}''${PATH:+:}$PATH

          # Create a directory for storing temporary data of the running VM.
          if [ -z "$TMPDIR" ] || [ -z "$USE_TMPDIR" ]; then
            TMPDIR=$(mktemp -d nix-vm.XXXXXXXXXX --tmpdir)
          fi

          # Create a directory for exchanging data with the VM.
          mkdir -p "$TMPDIR/xchg"

          cd "$TMPDIR"

          # Start QEMU.
          # We might need to be smarter about the QEMU binary to run when we want to
          # support architectures other than x86_64.
          # See qemu-common.nix in nixpkgs.
          ${lib.concatStringsSep "\\\n  " [
            "exec ${lib.getBin qemupkg}/bin/qemu-kvm"
            "-device virtio-rng-pci"
            "-cpu max"
            "-name ${node.system.name}"
            "-m ${toString node.virtualisation.memorySize}"
            "-smp ${toString node.virtualisation.cpus}"
            "-drive file=${image},format=qcow2"
            "-device virtio-net-pci,netdev=net0"
            "-netdev user,id=net0"
            "-virtfs local,security_model=passthrough,id=fsdev1,path=/nix/store,readonly=on,mount_tag=nix-store"
            (lib.concatStringsSep "\\\n  "
              (lib.mapAttrsToList
                (tag: share: "-virtfs local,path=${share.source},security_model=none,mount_tag=${tag}")
                  node.virtualisation.sharedDirectories))
            "-snapshot"
            (lib.optionalString (!interactive) "-nographic")
            "$QEMU_OPTS"
            "$@"
          ]};
        '';

      test-driver = hostPkgs.callPackage "${nixpkgs}/nixos/lib/test-driver" { };

      runTest = { nodes, vlans, interactive }: ''
        ${lib.getBin test-driver}/bin/nixos-test-driver \
        ${lib.optionalString interactive "--interactive"} \
        --start-scripts ${lib.concatStringsSep " " (nodes interactive)} \
          --vlans ${lib.concatStringsSep " " vlans} \
          -- ${hostPkgs.writeText "test-script" testScriptWithMounts}
      '';

      defaultTest = { interactive ? false }: runTest {
        inherit interactive nodes;
        vlans = [ "1" ];
      };
    in
    hostPkgs.stdenv.mkDerivation {
      inherit name;

      requiredSystemFeatures = [ "kvm" "nixos-test" ];

      buildCommand = ''
        ${defaultTest {}}
        touch $out
      '';

      passthru = {
        driverInteractive = hostPkgs.writeShellScriptBin "test-driver"
          (defaultTest {
            interactive = true;
          });
      };
    };
}
