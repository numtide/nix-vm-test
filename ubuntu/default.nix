{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    sha256 = image.hash;
    url = image.name;
  };
  images = lib.mapAttrs (k: v: fetchImage v) imagesJSON.${system};
  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ], memorySize ? null, cpus ? null }: generic.makeVmTest {
    name = "vm-test-ubuntu_${imageID}";
    inherit system testScript sharedDirs memorySize cpus;
    image = prepareUbuntuImage {
      inherit diskSize extraPathsToRegister;
      hostPkgs = pkgs;
      originalImage = image;
    };
  };
  prepareUbuntuImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister }:
    generic.customizeImageInVM {
      name = "${originalImage.name}-nix-vm-test.qcow2";
      inherit originalImage diskSize;
      nativeBuildInputs = [ pkgs.sudo ]; # visudo
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
          # Speed up the boot process
          systemctl --root="$mnt" mask snapd.service
          systemctl --root="$mnt" mask snapd.socket
          systemctl --root="$mnt" mask snapd.seeded.service

          # Disable TTY usage in sudo.
          # Otherwise, using sudo spawns a new pty, causing the test-driver to
          # receive mixed stdout and stderr when processing command output.
          # The driver only expects base64-encoded stdout, so extra stderr data
          # can break the output parsing.
          mkdir -p "$mnt/etc/sudoers.d"
          cat << EOF > "$mnt/etc/sudoers.d/disable-pty"
          Defaults !requiretty
          Defaults !use_pty
          EOF
          visudo -cf "$mnt/etc/sudoers.d/disable-pty"
          chmod 440 "$mnt/etc/sudoers.d/disable-pty"

          # We have no network in the test VMs, avoid an error on bootup
          systemctl --root="$mnt" mask ssh.service
          systemctl --root="$mnt" mask ssh.socket


          cat << EOF >> "$mnt/etc/netplan/99_config.yaml"
          network:
            version: 2
            renderer: networkd
            ethernets:
              ${generic.nicName}:
                dhcp4: true
          EOF

          ${lib.optionalString (diskSize != null) ''
            systemctl --root="$mnt" enable resizeguest.service
          ''}
          systemctl --root="$mnt" enable backdoor.service
      '';
    };
in {
  inherit prepareUbuntuImage;
  images = images;
} // lib.mapAttrs makeVmTestForImage images
