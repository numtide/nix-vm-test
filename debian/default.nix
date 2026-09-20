{ generic, guestPkgs, lib, guestSystem }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: guestPkgs.fetchurl {
    sha256 = image.hash;
    url = image.name;
  };
  images = lib.mapAttrs (k: v: fetchImage v) (imagesJSON.${guestSystem} or {});

  # aarch64 has no guestfs; customize via a cloud-init seed at boot instead (see ubuntu).
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

  debianCloudInitSeed = { extraPathsToRegister }:
    generic.mkCloudInitSeed {
      files = {
        "backdoor.service" = generic.backdoor { };
        "mount-store.service" = generic.mountStore { pathsToRegister = extraPathsToRegister; };
      };
      userData = generic.mkUserData {
        runcmd = [
          "mkdir -p /run/nixvmtest-seed"
          "mount -o ro /dev/disk/by-label/CIDATA /run/nixvmtest-seed"
          "install -m644 /run/nixvmtest-seed/backdoor.service /etc/systemd/system/backdoor.service"
          "install -m644 /run/nixvmtest-seed/mount-store.service /etc/systemd/system/mount-store.service"
          "umount /run/nixvmtest-seed"
          "passwd -d root"
          "systemctl mask --now serial-getty@${generic.serialConsole}.service serial-getty@hvc0.service"
          "systemctl mask ssh.service ssh.socket"
          "systemctl daemon-reload"
          # Start only the backdoor; its Requires/After pulls mount-store in once
          # (see ubuntu/default.nix for why activating mount-store separately breaks).
          "systemctl start backdoor.service"
        ];
      };
    };

  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ], memorySize ? null, cpus ? null }: generic.makeVmTest ({
    name = "vm-test-debian_${imageID}";
    inherit testScript sharedDirs memorySize cpus;
  } // (if useCloudInit then {
    image = resizeRawImage { originalImage = image; inherit diskSize; };
    cloudInitSeed = debianCloudInitSeed { inherit extraPathsToRegister; };
  } else {
    image = prepareDebianImage {
      inherit diskSize extraPathsToRegister;
      # Image preparation is Linux work, so it always runs with `guestPkgs`.
      buildPkgs = guestPkgs;
      originalImage = image;
    };
  }));
  prepareDebianImage = { buildPkgs, originalImage, diskSize, extraPathsToRegister ? [ ]}:
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

      # virt-resize depends on qemu-img, which is part of the qemu
      # derivation
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

          # We have no network in the test VMs, avoid an error on bootup
          systemctl mask ssh.service
          systemctl mask ssh.socket

          # Retrieve guest interface conf via DHCP
          cat << EOF >> /etc/systemd/network/80-ens4.network
          [Match]
          Name=ens4

          [Network]
          DHCP=yes
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
  inherit images prepareDebianImage;
} // lib.mapAttrs makeVmTestForImage images
