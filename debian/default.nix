{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    inherit (image) hash;
    url = "https://cloud.debian.org/images/cloud/${image.name}";
  };
  images = lib.mapAttrs (k: v: fetchImage v) imagesJSON.${system};
  makeVmTestForImage = image: { testScript, name, sharedDirs }: generic.makeVmTest {
    inherit system testScript name sharedDirs;
    image = prepareDebianImage {
      hostPkgs = pkgs;
      originalImage = image;
    };
  };
  prepareDebianImage = { hostPkgs, originalImage, extraPathsToRegister ? [ ]}:
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

      #export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
      ${lib.concatStringsSep "  \\\n" [
        "${pkgs.guestfs-tools}/bin/virt-customize"
        "-a ${resultImg}"
        "--smp 2"
        "--memsize 256"
        "--no-network"
        "--copy-in backdoor.service:/etc/systemd/system"
        "--copy-in mount-store.service:/etc/systemd/system"
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

          systemctl enable backdoor.service
        '')
      ]};

      cp ${resultImg} $out
    '';
in {
  inherit images prepareDebianImage;
} // lib.mapAttrs (k: v: makeVmTestForImage v) images
