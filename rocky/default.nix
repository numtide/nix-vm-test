{ generic, guestPkgs, lib, guestSystem }:
let
  imagesJSON = lib.importJSON ./images.json;
  fetchImage = image: guestPkgs.fetchurl {
    inherit (image) sha256;
    url = image.url;
  };

  # Rocky/RHEL 8.x aarch64 kernels are built with 64 KB memory pages. Not every
  # aarch64 CPU implements that translation granule (notably Apple Silicon, which
  # only supports 4 KB/16 KB) — on one that doesn't, the kernel's EFI stub refuses
  # to boot ("64 KB granular kernel is not supported by your CPU") and the VM just
  # hangs. This is a guest-architecture concern, not a darwin-specific one (e.g. an
  # aarch64-linux host with a similarly-limited CPU would hit it too), so filter
  # for any aarch64 guest rather than only when the host happens to be darwin.
  imagesForSystem = imagesJSON.${guestSystem} or { };
  supportedImages =
    if generic.guestIsAarch64
    then lib.filterAttrs (name: _: !(lib.hasPrefix "8_" name)) imagesForSystem
    else imagesForSystem;
  images = lib.mapAttrs (k: v: fetchImage v) supportedImages;

  # aarch64 has no guestfs; customize via a cloud-init seed at boot instead.
  # RHEL clones disable the 9p filesystem in their kernels, so (as in the baked
  # path) there is no mounted nix store: the backdoor script is a standalone
  # /bin/bash script copied into /usr/bin.
  useCloudInit = generic.guestIsAarch64;

  # Lock repositories to the vault mirror for the image's own minor version, so
  # dnf operations against first-party repos keep working even after that point
  # release is superseded — every image in rocky/images.json already points at
  # `vault/rocky`, so this isn't hypothetical, it's the state of every image we
  # ship. Safe to apply to every repo file since a fresh RESF image ships no
  # non-first-party repos. Kept as plain text (rather than a derivation) so it
  # can be spliced directly into the baked path's guestfs `--run` script (whose
  # own store-path references aren't visible inside the libguestfs chroot) as
  # well as copied onto the cloud-init seed for the boot-time path.
  rockyFixReposScriptText = ''
    rockyRepoFiles=( $(find /etc/yum.repos.d -type f 2>/dev/null) )
    for repoFile in "''${rockyRepoFiles[@]}"; do
      sed -i 's@.*mirrorlist=@#mirrorlist=@g' "''${repoFile}" # disable mirrorlist
      sed -i 's@.*baseurl=@baseurl=@g' "''${repoFile}" # switch to fastly CDN

      # `pub/rocky` is for non-EoL, `vault/rocky` is for EoL
      sed -i 's@$contentdir@vault/rocky@g' "''${repoFile}"
      sed -i 's@pub/rocky@vault/rocky@g' "''${repoFile}"

      # all this to not pollute the current environment with $VERSION_ID
      (export $(cat /etc/os-release | grep '^VERSION_ID=' | sed -e 's/"//g') && sed -i "s@\$releasever@''${VERSION_ID}@g" "''${repoFile}")
    done
    # change the value of the `contentdir` DNF variable
    [ -f /etc/dnf/vars/contentdir ] && sed -i 's@pub/rocky@vault/rocky@g' /etc/dnf/vars/contentdir
  '';

  resizeRawImage = { originalImage, diskSize }:
    if diskSize == null then originalImage
    else guestPkgs.runCommand "${originalImage.name}-resized.qcow2"
      { nativeBuildInputs = [ guestPkgs.qemu ]; } ''
        install -m644 ${originalImage} "$out"
        qemu-img resize "$out" ${diskSize}
      '';

  # cloud-init's default `growpart`/`resizefs` modules grow the partition/filesystem
  # on boot (unlike the baked path, cloud-init is still active here, so a custom
  # resize service would just race it and fail with "NOCHANGE: ... it cannot be
  # grown" — see resizeService's own comment for why it's baked-path-only).
  rockyCloudInitSeed =
    generic.mkCloudInitSeed {
      files = {
        "backdoor.service" = generic.backdoor { scriptPath = "/usr/bin/backdoorScript"; withMountedStore = false; };
        "backdoorScript" = generic.backdoorScript;
        "fix-repos.sh" = guestPkgs.writeText "fix-rocky-repos.sh" rockyFixReposScriptText;
      };
      userData = generic.mkUserData {
        runcmd = [
          "mkdir -p /run/nixvmtest-seed"
          "mount -o ro /dev/disk/by-label/CIDATA /run/nixvmtest-seed"
          "install -m755 /run/nixvmtest-seed/backdoorScript /usr/bin/backdoorScript"
          # Patch the store-path shebang to /bin/bash (there is no mounted store here).
          "sed -i 's|^#!/nix/store/.*|#!/bin/bash|' /usr/bin/backdoorScript"
          "install -m644 /run/nixvmtest-seed/backdoor.service /etc/systemd/system/backdoor.service"
          # See rockyFixReposScriptText above for why: every shipped image already
          # points at a vaulted point release.
          "bash /run/nixvmtest-seed/fix-repos.sh"
          "umount /run/nixvmtest-seed"
          "groupadd -f nixbld"
          "passwd -d root"
          "systemctl mask --now serial-getty@${generic.serialConsole}.service serial-getty@hvc0.service"
          "systemctl mask sshd.service"
          "systemctl daemon-reload"
          "systemctl start backdoor.service"
        ];
      };
    };

  makeVmTestForImage = imageID: image: { testScript, sharedDirs ? {}, diskSize ? null, extraPathsToRegister ? [ ], memorySize ? null, cpus ? null }: generic.makeVmTest ({
    name = "vm-test-rocky_${imageID}";
    inherit testScript sharedDirs memorySize cpus;
  } // (if useCloudInit then {
    image = resizeRawImage { originalImage = image; inherit diskSize; };
    cloudInitSeed = rockyCloudInitSeed;
  } else {
    image = prepareRockyImage {
      inherit diskSize extraPathsToRegister;
      # Image preparation is Linux work, so it always runs with `guestPkgs`.
      buildPkgs = guestPkgs;
      originalImage = image;
    };
  }));

  # Baked (x86_64) path only: the aarch64/cloud-init path relies on cloud-init's
  # own default growpart/resizefs modules instead (see rockyCloudInitSeed above).
  resizeService = guestPkgs.writeText "resizeService" ''
    [Service]
    Type = oneshot
    ExecStart = growpart /dev/sda 1
    ExecStart = xfs_growfs /

    [Install]
    WantedBy = multi-user.target
  '';

  prepareRockyImage = { buildPkgs, originalImage, diskSize, extraPathsToRegister }:
    let
      pkgs = buildPkgs;
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
          systemctl mask serial-getty@${generic.serialConsole}.service
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

          ${rockyFixReposScriptText}
        '')

      ]};

      cp ${resultImg} $out
    '';
in {
  inherit images prepareRockyImage;
} // lib.mapAttrs makeVmTestForImage images
