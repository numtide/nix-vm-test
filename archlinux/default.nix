{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    inherit (image) hash;
    url = image.url;
  };
  images = lib.mapAttrs (k: v: fetchImage v) (imagesJSON.${system} or {});
  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ], memorySize ? null, cpus ? null }: generic.makeVmTest {
    name = "vm-test-archlinux_${imageID}";
    inherit system testScript sharedDirs memorySize cpus;
    image = prepareArchlinuxImage {
      inherit diskSize extraPathsToRegister;
      hostPkgs = pkgs;
      originalImage = image;
    };
  };

  # Arch basic image: GPT with BIOS boot + EFI + btrfs root on partition 3.
  resizeService = pkgs.writeText "resizeService" ''
    [Service]
    Type = oneshot
    ExecStart = /bin/sh -euc 'sfdisk --relocate=gpt-bak-std ${generic.diskDevice}; echo ",+" | sfdisk --no-reread --force -N 3 ${generic.diskDevice}; partx -u ${generic.diskDevice}; btrfs filesystem resize max /'

    [Install]
    WantedBy = multi-user.target
  '';

  prepareArchlinuxImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister }:
    generic.customizeImageInVM {
      name = "${originalImage.name}-nix-vm-test.qcow2";
      inherit originalImage diskSize;
      rootModules = [ "btrfs" "xor" "raid6_pq" "zstd_compress" ];
      script = ''
          cp ${generic.backdoor { scriptPath = "/usr/bin/backdoorScript"; }} "$mnt/etc/systemd/system/backdoor.service"
          cp ${generic.mountStore { pathsToRegister = extraPathsToRegister; }} "$mnt/etc/systemd/system/mount-store.service"
          cp ${resizeService} "$mnt/etc/systemd/system/resizeguest.service"
          cp ${generic.backdoorScript} "$mnt/usr/bin/backdoorScript"

          # Patching the patched shebang to a reasonable path: /bin/bash.
          sed -i 's/\/nix\/store\/.*/\/bin\/bash/g' "$mnt/usr/bin/backdoorScript"

          passwd --root "$mnt" -d root

          groupadd --root "$mnt" nixbld

          # Don't spawn ttys on these devices, they are used for test instrumentation
          systemctl --root="$mnt" mask serial-getty@ttyS0.service
          systemctl --root="$mnt" mask serial-getty@hvc0.service

          # We have no reliable network in the test VMs
          systemctl --root="$mnt" mask sshd.service
          systemctl --root="$mnt" mask sshd.socket

          # arch-boxes enables systemd-time-wait-sync which blocks
          # time-sync.target -> multi-user.target forever when NTP is unreachable.
          systemctl --root="$mnt" mask systemd-time-wait-sync.service

          # arch-boxes also enables a pacman-init and keyring-sync pair that
          # need the network to run first-boot key initialization
          rm -f "$mnt/etc/systemd/system/pacman-init.service"
          systemctl --root="$mnt" mask pacman-init.service
          systemctl --root="$mnt" mask archlinux-keyring-wkd-sync.service
          systemctl --root="$mnt" mask archlinux-keyring-wkd-sync.timer

          # Skip waiting for the network to be "online"
          systemctl --root="$mnt" mask systemd-networkd-wait-online.service

          # arch-boxes installs GRUB; systemd-boot-update is pointless
          systemctl --root="$mnt" mask systemd-boot-update.service

          # Drop GRUB's interactive timeout so the VM doesn't wait at the menu,
          # and route the kernel console to ttyS0 so systemd stage 2 is visible
          # on the same serial line the test driver reads.
          if [ -f "$mnt/boot/grub/grub.cfg" ]; then
            sed -i 's/^set timeout=.*/set timeout=0/' "$mnt/boot/grub/grub.cfg"
            sed -i 's|\(linux\s\+/boot/vmlinuz-linux[^\n]*\)|\1 console=tty0 console=ttyS0|' "$mnt/boot/grub/grub.cfg"
          fi
          if [ -f "$mnt/etc/default/grub" ]; then
            sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' "$mnt/etc/default/grub"
            sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 console=tty0 console=ttyS0"|' "$mnt/etc/default/grub"
          fi

          ${lib.optionalString (diskSize != null) ''
            systemctl --root="$mnt" enable resizeguest.service
          ''}
          systemctl --root="$mnt" enable backdoor.service
      '';
    };
in {
  inherit images prepareArchlinuxImage;
} // lib.mapAttrs makeVmTestForImage images
