{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: pkgs.fetchurl {
    inherit (image) sha256;
    url = image.url;
  };
  images = lib.mapAttrs (k: v: fetchImage v) (imagesJSON.${system} or {});
  makeVmTestForImage = image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ]}: generic.makeVmTest {
    inherit system testScript sharedDirs;
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

  prepareRockyImage = { hostPkgs, originalImage, diskSize, extraPathsToRegister }:
    let
      pkgs = hostPkgs;
      resultImg = "./image.qcow2";
    in
    pkgs.runCommand "${originalImage.name}-nix-vm-test.qcow2" { } ''
      # We will modify the VM image, so we need a mutable copy
      install -m777 ${originalImage} ${resultImg}

      # Copy the service files here, since otherwise they end up in the VM
      # with their paths including the nix hash
      # Also disable mounting store because RHEL (and RHEL clones by nature)
      # compile their kernels with support for 9P filesystem disabled :(
      cp ${generic.backdoor { scriptPath = "/usr/bin/backdoorScript"; withMountedStore = false; }} backdoor.service
      cp ${generic.mountStore { pathsToRegister = extraPathsToRegister; }} mount-store.service
      cp ${resizeService} resizeguest.service
      cp ${generic.backdoorScript} backdoorScript

      # Patching the patched shebang to a reasonable path: /bin/bash.
      # Mic92 approves this.
      sed -i 's/\/nix\/store\/.*/\/bin\/bash/g' backdoorScript

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
        "--copy-in backdoorScript:/usr/bin"
        "--copy-in backdoor.service:/etc/systemd/system"
        "--copy-in mount-store.service:/etc/systemd/system"
        "--copy-in resizeguest.service:/etc/systemd/system"
        "--run"
        (pkgs.writeShellScript "run-script" ''
          # Clear the root password
          passwd -d root

          groupadd nixbld

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
          systemctl enable register-nix-paths.service
          systemctl enable backdoor.service

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
        '')

      ]};

      cp ${resultImg} $out
    '';
in {
  inherit images prepareRockyImage;
} // lib.mapAttrs (k: v: makeVmTestForImage v) images
