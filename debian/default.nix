{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    sha256 = image.hash;
    url = image.name;
  };
  images = lib.mapAttrs (k: v: fetchImage v) imagesJSON.${system};
  makeVmTestForImage = image: { testScript, sharedDirs, diskSize ? null }: generic.makeVmTest {
    inherit system testScript sharedDirs;
    image = prepareDebianImage {
      inherit diskSize;
      hostPkgs = pkgs;
      originalImage = image;
    };
  };
  prepareDebianImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister ? [ ]}:
    let
      pkgs = hostPkgs;
      resultImg = "./image.qcow2";
    in
    pkgs.runCommand "${originalImage.name}-nix-vm-test.qcow2" { } ''
      # We will modify the VM image, so we need a mutable copy
      install -m777 ${originalImage} ${resultImg}

      # Copy the service files here, since otherwise they end up in the VM
      # with their paths including the nix hash
      cp ${generic.backdoor} backdoor.service
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
          systemctl mask serial-getty@ttyS0.service
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
} // lib.mapAttrs (k: v: makeVmTestForImage v) images
