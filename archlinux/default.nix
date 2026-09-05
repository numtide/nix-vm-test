{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    inherit (image) hash;
    url = image.url;
  };
  images = lib.mapAttrs (k: v: fetchImage v) (imagesJSON.${system} or {});
  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ] }: generic.makeVmTest {
    name = "vm-test-archlinux_${imageID}";
    inherit system testScript sharedDirs;
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
    ExecStart = /bin/sh -euc 'sfdisk --relocate=gpt-bak-std /dev/sda; echo ",+" | sfdisk --no-reread --force -N 3 /dev/sda; partx -u /dev/sda; btrfs filesystem resize max /'

    [Install]
    WantedBy = multi-user.target
  '';

  prepareArchlinuxImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister }:
    let
      pkgs = hostPkgs;
      resultImg = "./image.qcow2";
    in
    pkgs.runCommand "${originalImage.name}-nix-vm-test.qcow2" { } ''
      install -m777 ${originalImage} ${resultImg}

      cp ${generic.backdoor { scriptPath = "/usr/bin/backdoorScript"; }} backdoor.service
      cp ${generic.mountStore { pathsToRegister = extraPathsToRegister; }} mount-store.service
      cp ${resizeService} resizeguest.service
      cp ${generic.backdoorScript} backdoorScript

      # Patching the patched shebang to a reasonable path: /bin/bash.
      sed -i 's/\/nix\/store\/.*/\/bin\/bash/g' backdoorScript

      ${lib.optionalString (diskSize != null) ''
        export PATH="${pkgs.qemu}/bin:$PATH"
        qemu-img resize ${resultImg} ${diskSize}
      ''}

      ${lib.concatStringsSep "  \\\n" [
        "${pkgs.guestfs-tools}/bin/virt-customize"
        "-a ${resultImg}"
        "--smp 2"
        "--memsize 256"
        "--no-network"
        "--copy-in backdoorScript:/usr/bin"
        "--copy-in backdoor.service:/etc/systemd/system"
        "--copy-in mount-store.service:/etc/systemd/system"
        "--copy-in resizeguest.service:/etc/systemd/system"
        "--run"
        (pkgs.writeShellScript "run-script" ''
          passwd -d root

          groupadd nixbld

          # Don't spawn ttys on these devices, they are used for test instrumentation
          systemctl mask serial-getty@ttyS0.service
          systemctl mask serial-getty@hvc0.service

          # We have no reliable network in the test VMs
          systemctl mask sshd.service
          systemctl mask sshd.socket

          # arch-boxes enables systemd-time-wait-sync which blocks
          # time-sync.target -> multi-user.target forever when NTP is unreachable.
          systemctl mask systemd-time-wait-sync.service

          # arch-boxes also enables a pacman-init and keyring-sync pair that
          # need the network to run first-boot key initialization.
          rm -f /etc/systemd/system/pacman-init.service
          systemctl mask pacman-init.service
          systemctl mask archlinux-keyring-wkd-sync.service
          systemctl mask archlinux-keyring-wkd-sync.timer

          # Skip waiting for the network to be "online"
          systemctl mask systemd-networkd-wait-online.service

          # arch-boxes installs GRUB; systemd-boot-update is pointless
          systemctl mask systemd-boot-update.service

          # Drop GRUB's interactive timeout so the VM doesn't wait at the menu,
          # and route the kernel console to ttyS0 so systemd stage 2 is visible
          # on the same serial line the test driver reads.
          if [ -f /boot/grub/grub.cfg ]; then
            sed -i 's/^set timeout=.*/set timeout=0/' /boot/grub/grub.cfg
            sed -i 's|\(linux\s\+/boot/vmlinuz-linux[^\n]*\)|\1 console=tty0 console=ttyS0|' /boot/grub/grub.cfg
          fi
          if [ -f /etc/default/grub ]; then
            sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
            sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 console=tty0 console=ttyS0"|' /etc/default/grub
          fi

          ${lib.optionalString (diskSize != null) ''
            systemctl enable resizeguest.service
          ''}
          systemctl enable backdoor.service
        '')
      ]};

      cp ${resultImg} $out
    '';
in {
  inherit images prepareArchlinuxImage;
} // lib.mapAttrs makeVmTestForImage images
