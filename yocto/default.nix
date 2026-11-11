{ generic, pkgs, lib, system }:
let
  imagesJSON = lib.importJSON ./images.json;

  isAarch64 = lib.hasPrefix "aarch64" system;
  rootDevice = if isAarch64 then "/dev/vda" else "/dev/sda";
  serialDevice = if isAarch64 then "ttyAMA0" else "ttyS0";
  vmTools = pkgs.vmTools.override {
    rootModules = [
      "ext4"
      "virtio_pci"
      "virtio_console"
      "virtio_net"
      "virtio_rng"
      "af_packet"
      "inet_diag"
      "netlink_diag"
      "9pnet_virtio"
      "9p"
      "overlay"
    ]
    ++ (if isAarch64 then [ "virtio_blk" ] else [ "i8042" "atkbd" "ata_piix" "sd_mod" ]);
  };
  stage1Init = { mountStore }: pkgs.writeScript "yocto-stage1" ''
    #! ${vmTools.initrdUtils}/bin/ash -e
    export PATH=${vmTools.initrdUtils}/bin
    mount -t proc none /proc
    mount -t sysfs none /sys
    for i in $(cat ${vmTools.modulesClosure}/insmod-list); do
      insmod $i || echo "warning: unable to load $i"
    done
    mount -t devtmpfs devtmpfs /dev
    root=${rootDevice}
    for o in $(cat /proc/cmdline); do
      case $o in
        root=*) root=''${o#root=} ;;
      esac
    done
    mkdir /fs
    until mount "$root" /fs; do sleep 0.2; done
    ${lib.optionalString mountStore (lib.concatStringsSep "\n" (generic.mountStoreCommands "/fs"))}
    exec switch_root /fs /sbin/init
  '';

  initrd = { mountStore ? true }: pkgs.makeInitrd {
    contents = [
      {
        object = stage1Init { inherit mountStore; };
        symlink = "/init";
      }
    ];
  };

  # The nixpkgs kernel and the stage-1 initrd; `root` is the rootfs device, the whole disk by default.
  bootArgs = { mountStore ? true, root ? rootDevice }: [
    "-kernel ${pkgs.linux}/${if isAarch64 then "Image" else "bzImage"}"
    "-initrd ${initrd { inherit mountStore; }}/initrd"
    "-append 'root=${root} console=${serialDevice}'"
  ];

  units = extraPathsToRegister: {
    "backdoor.service" = generic.backdoor { inherit serialDevice; };
    "mount-store.service" = generic.mountStore { pathsToRegister = extraPathsToRegister; };
    "nix-var.service" = nixVarService;
  };

  nixVarService = pkgs.writeText "nix-var.service" ''
    [Unit]
    Description = Writable /nix/var for the Nix database on a read-only rootfs
    Before = mount-store.service

    [Service]
    Type = oneshot
    ExecStart = /bin/sh -euc '[ -w /nix/var ] || mount -t tmpfs tmpfs /nix/var'

    [Install]
    WantedBy = multi-user.target
  '';

  makeDiskImage = name: rootfs: extraPathsToRegister:
    pkgs.runCommand "${name}.qcow2"
      {
        nativeBuildInputs = with pkgs; [ zstd e2fsprogs qemu ];
        inherit rootfs;
      } ''
      if [ "$(head -c 4 "$rootfs" | od -An -tx1 | tr -d ' ')" = 28b52ffd ]; then
        zstd -d "$rootfs" -o rootfs.ext4
      else
        cp "$rootfs" rootfs.ext4
      fi
      chmod u+w rootfs.ext4
      debugfs -w rootfs.ext4 <<EOF
      mkdir /nix
      mkdir /nix/.ro-store
      mkdir /nix/.rw-store
      mkdir /nix/store
      mkdir /nix/var
      mkdir /etc/systemd/system/multi-user.target.wants
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (unit: file: ''
        write ${file} /etc/systemd/system/${unit}
        symlink /etc/systemd/system/multi-user.target.wants/${unit} /etc/systemd/system/${unit}
      '') (units extraPathsToRegister))}
      symlink /etc/systemd/system/serial-getty@${serialDevice}.service /dev/null
      symlink /etc/systemd/system/serial-getty@hvc0.service /dev/null
      EOF

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (unit: file: ''
        debugfs -R "dump /etc/systemd/system/${unit} dumped" rootfs.ext4
        cmp -s dumped ${file} \
          || { echo "debugfs exited 0 but did not write ${unit}; is rootfs.ext4 out of space?" >&2; exit 1; }
      '') (units extraPathsToRegister))}

      for link in multi-user.target.wants/{${lib.concatStringsSep "," (lib.attrNames (units extraPathsToRegister))}} \
                  serial-getty@{${serialDevice},hvc0}.service; do
        debugfs -R "stat /etc/systemd/system/$link" rootfs.ext4 | grep -q 'Type: symlink' \
          || { echo "debugfs exited 0 but did not link $link in rootfs.ext4" >&2; exit 1; }
      done

      qemu-img convert -f raw -O qcow2 rootfs.ext4 $out
    '';

  images = lib.mapAttrs (_: image: pkgs.fetchurl { inherit (image) url; sha256 = image.hash; }) (
    imagesJSON.${system} or { }
  );

  prepareYoctoImage = { hostPkgs, originalImage, extraPathsToRegister ? [ ] }:
    let
      pkgs = hostPkgs;
      resultImg = "./image.qcow2";
      enable = unit: "--link /etc/systemd/system/${unit}:/etc/systemd/system/multi-user.target.wants/${unit}";
      mask = unit: "--link /dev/null:/etc/systemd/system/${unit}";
    in
    pkgs.runCommand "${baseNameOf (toString originalImage)}-nix-vm-test.qcow2" { } ''
      install -m777 ${originalImage} ${resultImg}

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (unit: file: "cp ${file} ${unit}") (units extraPathsToRegister))}

      ${lib.concatStringsSep "  \\\n" ([
        "${pkgs.guestfs-tools}/bin/virt-customize"
        "-a ${resultImg}"
        "--smp 2"
        "--memsize 256"
        "--no-network"
        "--mkdir /nix/.ro-store"
        "--mkdir /nix/.rw-store"
        "--mkdir /nix/store"
        "--mkdir /nix/var"
        "--mkdir /etc/systemd/system/multi-user.target.wants"
      ]
      ++ lib.concatMap (unit: [ "--copy-in ${unit}:/etc/systemd/system" (enable unit) ]) (lib.attrNames (units [ ]))
      ++ [
        (mask "serial-getty@${serialDevice}.service")
        (mask "serial-getty@hvc0.service")
      ])};

      cp ${resultImg} $out
    '';

  testArgs = { testScript, sharedDirs ? {}, extraPathsToRegister ? [ ], memorySize ? null, cpus ? null }: {
    inherit system testScript sharedDirs memorySize cpus;
  };

  makeVmTestFromRootfs = name: rootfs: { extraPathsToRegister ? [ ], ... }@args: generic.makeVmTest (testArgs args // {
    inherit name;
    image = makeDiskImage name rootfs extraPathsToRegister;
    bootArgs = bootArgs { };
  });

  custom = { image, bootArgs ? [ ], extraPathsToRegister ? [ ], ... }@args:
    if isAarch64 then
      throw "nix-vm-test: yocto.custom is x86_64-linux only: libguestfs has no aarch64 appliance in nixpkgs, and the aarch64 virt machine needs UEFI firmware for a bootloader disk. Use yocto.fromRootfs."
    else
      generic.makeVmTest (testArgs (builtins.removeAttrs args [ "image" "bootArgs" ]) // {
        inherit bootArgs;
        name = "vm-test-yocto";
        image = prepareYoctoImage {
          inherit extraPathsToRegister;
          hostPkgs = pkgs;
          originalImage = image;
        };
      });

  fromRootfs = { rootfs, ... }@args: makeVmTestFromRootfs "vm-test-yocto" rootfs (builtins.removeAttrs args [ "rootfs" ]);
in {
  inherit images custom fromRootfs makeDiskImage prepareYoctoImage bootArgs;
} // lib.mapAttrs (imageID: makeVmTestFromRootfs "vm-test-yocto_${imageID}") images
