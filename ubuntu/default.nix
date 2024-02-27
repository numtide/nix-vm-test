{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    inherit (image) hash;
    url = "https://cloud-images.ubuntu.com/releases/${image.releaseName}/release-${image.releaseTimeStamp}/${image.name}";
  };
  images = lib.mapAttrs (k: v: fetchImage v) imagesJSON.${system};
  makeVmTestForImage = image: { testScript, name, sharedDirs, diskSize ? null }: generic.makeVmTest {
    inherit system testScript name sharedDirs;
    image = prepareUbuntuImage {
      inherit diskSize;
      hostPkgs = pkgs;
      originalImage = image;
    };
  };
  prepareUbuntuImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister ? [ ] }:
    let
      pkgs = hostPkgs;
      resultImg = "./image.qcow2";
      # The nix store paths that need to be added to the nix DB for this node.
      pathsToRegister =  extraPathsToRegister;
    in
    pkgs.runCommand "${originalImage.name}-nix-vm-test.qcow2" { } ''
      # We will modify the VM image, so we need a mutable copy
      install -m777 ${originalImage} ${resultImg}

      # Copy the service files here, since otherwise they end up in the VM
      # with their paths including the nix hash
      cp ${generic.backdoor { inherit pkgs; }} backdoor.service
      cp ${generic.mountStore { inherit pkgs pathsToRegister; }} mount-store.service
      cp ${generic.resizeService} resizeguest.service

      ${lib.optionalString (diskSize != null) ''
        export PATH="${pkgs.qemu}/bin:$PATH"
        qemu-img resize ${resultImg} +2G
        systemctl enable resizeguest.service
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
          # Speed up the boot process
          systemctl mask snapd.service
          systemctl mask snapd.socket
          systemctl mask snapd.seeded.service

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
} // lib.mapAttrs (k: v: makeVmTestForImage v) images
