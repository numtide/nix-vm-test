{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    sha256 = image.hash;
    url = image.name;
  };
  images = lib.mapAttrs (k: v: fetchImage v) imagesJSON.${system};
  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ], memorySize ? null, cpus ? null }: generic.makeVmTest {
    name = "vm-test-debian_${imageID}";
    inherit system testScript sharedDirs memorySize cpus;
    image = prepareDebianImage {
      inherit diskSize extraPathsToRegister;
      hostPkgs = pkgs;
      originalImage = image;
    };
  };
  prepareDebianImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister ? [ ]}:
    generic.customizeImageInVM {
      name = "${originalImage.name}-nix-vm-test.qcow2";
      inherit originalImage diskSize;
      script = ''
          # Copy the service files here, since otherwise they end up in the VM
          # with their paths including the nix hash
          cp ${generic.backdoor {}} "$mnt/etc/systemd/system/backdoor.service"
          cp ${generic.mountStore { pathsToRegister = extraPathsToRegister; }} "$mnt/etc/systemd/system/mount-store.service"
          cp ${generic.resizeService} "$mnt/etc/systemd/system/resizeguest.service"

          # Clear the root password
          passwd --root "$mnt" -d root

          # Don't spawn ttys on these devices, they are used for test instrumentation
          systemctl --root="$mnt" mask serial-getty@${generic.serialConsole}.service
          systemctl --root="$mnt" mask serial-getty@hvc0.service

          # We have no network in the test VMs, avoid an error on bootup
          systemctl --root="$mnt" mask ssh.service
          systemctl --root="$mnt" mask ssh.socket

          # Retrieve guest interface conf via DHCP
          mkdir -p "$mnt/etc/systemd/network"
          cat << EOF >> "$mnt/etc/systemd/network/80-${generic.nicName}.network"
          [Match]
          Name=${generic.nicName}

          [Network]
          DHCP=yes
          EOF

          ${lib.optionalString (diskSize != null) ''
            systemctl --root="$mnt" enable resizeguest.service
          ''}
          systemctl --root="$mnt" enable backdoor.service
      '';
    };
in {
  inherit images prepareDebianImage;
} // lib.mapAttrs makeVmTestForImage images
