{ generic, guestPkgs, lib, guestSystem }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: guestPkgs.fetchurl {
    sha256 = image.hash;
    url = image.name;
  };
  images = lib.mapAttrs (k: v: fetchImage v) (imagesJSON.${guestSystem} or {});

  # `guestfs`/`virt-customize` is unavailable on aarch64, so there we skip the
  # image bake and customize via a cloud-init seed at boot instead (see below).
  useCloudInit = generic.guestIsAarch64;

  # Grow the raw cloud image (guestfs-free) when a diskSize is requested. cloud-init's
  # default `growpart`/`resizefs` modules then grow the partition/filesystem on boot
  # (unlike the baked path, cloud-init is still active here, so a custom resize
  # service would just race it and fail with "NOCHANGE: ... it cannot be grown").
  resizeRawImage = { originalImage, diskSize }:
    if diskSize == null then originalImage
    else guestPkgs.runCommand "${originalImage.name}-resized.qcow2"
      { nativeBuildInputs = [ guestPkgs.qemu ]; } ''
        install -m644 ${originalImage} "$out"
        qemu-img resize "$out" ${diskSize}
      '';

  ubuntuCloudInitSeed = { extraPathsToRegister }:
    generic.mkCloudInitSeed {
      files = {
        "backdoor.service" = generic.backdoor { };
        "mount-store.service" = generic.mountStore { pathsToRegister = extraPathsToRegister; };
        # Mirror the sudoers tweak the baked image applies (keeps sudo output clean
        # for the test driver).
        "disable-pty" = guestPkgs.writeText "disable-pty" ''
          Defaults !requiretty
          Defaults !use_pty
        '';
      };
      userData = generic.mkUserData {
        runcmd = [
          "mkdir -p /run/nixvmtest-seed"
          "mount -o ro /dev/disk/by-label/CIDATA /run/nixvmtest-seed"
          "install -m644 /run/nixvmtest-seed/backdoor.service /etc/systemd/system/backdoor.service"
          "install -m644 /run/nixvmtest-seed/mount-store.service /etc/systemd/system/mount-store.service"
          "install -m440 /run/nixvmtest-seed/disable-pty /etc/sudoers.d/disable-pty"
          "umount /run/nixvmtest-seed"
          "passwd -d root"
          # `--now` also stops any getty already running on these instrumentation
          # devices, so the backdoor can take over hvc0 without contention.
          "systemctl mask --now serial-getty@${generic.serialConsole}.service serial-getty@hvc0.service"
          "systemctl mask snapd.service snapd.socket snapd.seeded.service"
          "systemctl mask ssh.service ssh.socket"
          "systemctl daemon-reload"
          # Start only the backdoor: its Requires/After pulls mount-store into the
          # same transaction and runs it exactly once. Activating mount-store
          # separately would re-trigger it (it is a oneshot without RemainAfterExit),
          # and the second 9p mount fails ("no channels available for device nix-store").
          "systemctl start backdoor.service"
        ];
      };
    };

  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ], memorySize ? null, cpus ? null }: generic.makeVmTest ({
    name = "vm-test-ubuntu_${imageID}";
    inherit testScript sharedDirs memorySize cpus;
  } // (if useCloudInit then {
    image = resizeRawImage { originalImage = image; inherit diskSize; };
    cloudInitSeed = ubuntuCloudInitSeed { inherit extraPathsToRegister; };
  } else {
    image = prepareUbuntuImage {
      inherit diskSize extraPathsToRegister;
      # Image preparation is Linux work (guestfs + guest binaries baked into the
      # image), so it always runs with the Linux `guestPkgs` set.
      buildPkgs = guestPkgs;
      originalImage = image;
    };
  }));
  prepareUbuntuImage = { buildPkgs, originalImage, diskSize, extraPathsToRegister }:
    let
      pkgs = buildPkgs;
      resultImg = "./image.qcow2";
    in
    pkgs.runCommand "${originalImage.name}-nix-vm-test.qcow2" { } ''
      # We will modify the VM image, so we need a mutable copy
      install -m777 ${originalImage} ${resultImg}

      # Copy the service files here, since otherwise they end up in the VM
      # with their paths including the nix hash
      cp ${generic.backdoor {}} backdoor.service
      cp ${generic.mountStore { pathsToRegister = extraPathsToRegister; }} mount-store.service
      cp ${generic.resizeService} resizeguest.service

      ${lib.optionalString (diskSize != null) ''
        export PATH="${pkgs.qemu}/bin:$PATH"
        qemu-img resize ${resultImg} ${diskSize}
      ''}

      #export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
      ${lib.concatStringsSep "  \\\n" [
        "${pkgs.guestfs-tools}/bin/virt-customize"
        "-a ${resultImg}"
        "--smp 2"
        "--memsize 256"
        "--no-network"
        "--copy-in backdoor.service:/etc/systemd/system"
        "--copy-in mount-store.service:/etc/systemd/system"
        "--copy-in resizeguest.service:/etc/systemd/system"
        "--run"
        (pkgs.writeShellScript "run-script" ''
          # Clear the root password
          passwd -d root

          # Don't spawn ttys on these devices, they are used for test instrumentation
          systemctl mask serial-getty@${generic.serialConsole}.service
          systemctl mask serial-getty@hvc0.service
          # Speed up the boot process
          systemctl mask snapd.service
          systemctl mask snapd.socket
          systemctl mask snapd.seeded.service

          # Disable TTY usage in sudo.
          # Otherwise, using sudo spawns a new pty, causing the test-driver to
          # receive mixed stdout and stderr when processing command output.
          # The driver only expects base64-encoded stdout, so extra stderr data
          # can break the output parsing.
          mkdir -p /etc/sudoers.d
          cat << EOF > /etc/sudoers.d/disable-pty
          Defaults !requiretty
          Defaults !use_pty
          EOF
          visudo -cf /etc/sudoers.d/disable-pty
          chmod 440 /etc/sudoers.d/disable-pty

          # We have no network in the test VMs, avoid an error on bootup
          systemctl mask ssh.service
          systemctl mask ssh.socket


          cat << EOF >> /etc/netplan/99_config.yaml
          network:
            version: 2
            renderer: networkd
            ethernets:
              ens4:
                dhcp4: true
          EOF

          ${lib.optionalString (diskSize != null) ''
            systemctl enable resizeguest.service
          ''}
          systemctl enable backdoor.service
        '')
      ]};

      cp ${resultImg} $out
    '';
in {
  inherit prepareUbuntuImage;
  images = images;
} // lib.mapAttrs makeVmTestForImage images
