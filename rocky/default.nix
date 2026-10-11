{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    inherit (image) sha256;
    url = image.url;
  };

  images = lib.mapAttrs (k: v: fetchImage v) (imagesJSON.${system} or {});
  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ], memorySize ? null, cpus ? null }: generic.makeVmTest {
    name = "vm-test-rocky_${imageID}";
    inherit system testScript sharedDirs memorySize cpus;
    image = prepareRockyImage {
      inherit diskSize extraPathsToRegister;
      hostPkgs = pkgs;
      originalImage = image;
    };
  };

  resizeService = pkgs.writeText "resizeService" ''
    [Service]
    Type = oneshot
    ExecStart = growpart /dev/sda 1
    ExecStart = xfs_growfs /

    [Install]
    WantedBy = multi-user.target
  '';

  # Kept as plain text (rather than inline in the script below) because it runs
  # inside a chroot of the image, where no nix store paths are visible.
  rockyFixReposScriptText = ''
    # lock repositories to the minor version in vault so that
    # the dnf operations **always** work for first-party repos

    # safe to do on all repos because you won't find any
    # non-first-party repos on a fresh image from RESF
    rockyRepoFiles=( $(find /etc/yum.repos.d -type f 2>/dev/null) )
    for repoFile in "''${rockyRepoFiles[@]}"; do
      sed -i 's@.*mirrorlist=@#mirrorlist=@g' "''${repoFile}" # disable mirrorlist
      sed -i 's@.*baseurl=@baseurl=@g' "''${repoFile}" # switch to fastly CDN

      # `pub/rocky` is for non-EoL, `vault/rocky` is for EoL
      sed -i 's@$contentdir@vault/rocky@g' "''${repoFile}"
      sed -i 's@pub/rocky@vault/rocky@g' "''${repoFile}"

      # change `$contentdir` globally
      sed -i 's@$contentdir@vault/rocky@g' "''${repoFile}"

      # all this to not pollute the current environment with $VERSION_ID
      (export $(cat /etc/os-release | grep '^VERSION_ID=' | sed -e 's/"//g') && sed -i "s@\$releasever@''${VERSION_ID}@g" "''${repoFile}")
    done
    # change the value of the `contentdir` DNF variable
    [ -f /etc/dnf/vars/contentdir ] && sed -i 's@pub/rocky@vault/rocky@g' /etc/dnf/vars/contentdir
  '';

  prepareRockyImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister }:
    generic.customizeImageInVM {
      name = "${originalImage.name}-nix-vm-test.qcow2";
      inherit originalImage diskSize;
      # The root filesystem is XFS.
      rootModules = [ "xfs" ];
      script = ''
          # Copy the service files here, since otherwise they end up in the VM
          # with their paths including the nix hash
          # Also disable mounting store because RHEL (and RHEL clones by nature)
          # compile their kernels with support for 9P filesystem disabled :(
          cp ${generic.backdoor { scriptPath = "/usr/bin/backdoorScript"; withMountedStore = false; }} "$mnt/etc/systemd/system/backdoor.service"
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
          systemctl --root="$mnt" mask serial-getty@ttyS0.service
          systemctl --root="$mnt" mask serial-getty@hvc0.service

          # We have no network in the test VMs, avoid an error on bootup
          systemctl --root="$mnt" mask ssh.service
          systemctl --root="$mnt" mask ssh.socket

          # Retrieve guest interface conf via DHCP
          mkdir -p "$mnt/etc/systemd/network"
          cat << EOF >> "$mnt/etc/systemd/network/80-ens4.network"
          [Match]
          Name=ens4

          [Network]
          DHCP=yes
          EOF

          ${lib.optionalString (diskSize != null) ''
            systemctl --root="$mnt" enable resizeguest.service
          ''}
          systemctl --root="$mnt" enable backdoor.service

          # (a clean PATH: the one inherited from this VM only has nix store paths)
          chroot "$mnt" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c ${lib.escapeShellArg rockyFixReposScriptText}

          # Files written from here carry no SELinux labels, which an enforcing policy
          # would deny the backdoor service: boot permissive.
          sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' "$mnt/etc/selinux/config"
      '';
    };
in {
  inherit images prepareRockyImage;
} // lib.mapAttrs makeVmTestForImage images
