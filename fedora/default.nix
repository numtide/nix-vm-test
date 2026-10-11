{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  # Releases move from the live tree to the archive once they are EOL, so try both.
  fetchImage = image: pkgs.fetchurl {
    inherit (image) hash;
    urls = [
      "https://download.fedoraproject.org/pub/fedora/linux/releases/${image.name}"
      "https://dl.fedoraproject.org/pub/archive/fedora/linux/releases/${image.name}"
    ];
  };
  images = lib.mapAttrs (k: v: fetchImage v) (imagesJSON.${system} or {});
  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ], selinuxEnforcing ? false, memorySize ? null, cpus ? null }: generic.makeVmTest {
    name = "vm-test-fedora_${imageID}";
    inherit system testScript sharedDirs memorySize cpus;
    image = prepareFedoraImage {
      inherit diskSize extraPathsToRegister selinuxEnforcing;
      hostPkgs = pkgs;
      originalImage = image;
    };
  };

  resizeService = pkgs.writeText "resizeService" ''
    [Service]
    Type = oneshot
    ExecStart = growpart ${generic.diskDevice} 5
    ExecStart = btrfs filesystem resize max /

    [Install]
    WantedBy = multi-user.target
  '';

  prepareFedoraImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister, selinuxEnforcing ? false }:
    generic.customizeImageInVM {
      name = "${originalImage.name}-nix-vm-test.qcow2";
      inherit originalImage diskSize;
      # The root filesystem is a btrfs subvolume named `root` (next to `home` and `var`).
      mountOptions = "subvol=root";
      rootModules = [ "btrfs" "xor" "raid6_pq" "zstd_compress" ];
      nativeBuildInputs = [ pkgs.policycoreutils ]; # setfiles
      script = ''
          # Copy the service files here, since otherwise they end up in the VM
          # with their paths including the nix hash
          cp ${generic.backdoor { scriptPath = "/usr/bin/backdoorScript"; }} "$mnt/etc/systemd/system/backdoor.service"
          cp ${generic.mountStore { pathsToRegister = extraPathsToRegister; }} "$mnt/etc/systemd/system/mount-store.service"
          cp ${resizeService} "$mnt/etc/systemd/system/resizeguest.service"
          cp ${generic.backdoorScript} "$mnt/usr/bin/backdoorScript"

          # Patching the patched shebang to a reasonable path: /bin/bash.
          # Mic92 approves this.
          sed -i 's/\/nix\/store\/.*/\/bin\/bash/g' "$mnt/usr/bin/backdoorScript"

          # Clear the root password
          passwd --root "$mnt" -d root

          groupadd --root "$mnt" nixbld

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

          ${lib.optionalString (!selinuxEnforcing) ''
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' "$mnt/etc/selinux/config"
          ''}
          ${lib.optionalString selinuxEnforcing ''
            # Keep this last: it labels the files written above, including the unit
            # symlink `enable` just created.
            ${generic.selinuxRelabel ''"$mnt/usr/bin/backdoorScript" "$mnt/etc"''}
          ''}
      '';
    };
in {
  inherit images prepareFedoraImage;
} // lib.mapAttrs makeVmTestForImage images
