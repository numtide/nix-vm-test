{ pkgs, guestPkgs, package, system }:
let
  lib = package;
  isAarch64 = pkgs.lib.hasPrefix "aarch64" system;
  testScript = ''
    vm.start(allow_reboot=True)
    vm.wait_for_unit("multi-user.target")
    vm.succeed("grep -E '^[^ ]+ /nix/store overlay ' /proc/mounts")
    vm.succeed("${guestPkgs.hello}/bin/hello")
    vm.succeed("${guestPkgs.nix}/bin/nix-store --query --requisites ${guestPkgs.hello}")
    vm.succeed("[ $(nproc) = 3 ]")
    vm.succeed("[ $(awk '/MemTotal/ {print $2}' /proc/meminfo) -gt 1400000 ]")
    vm.succeed("command -v nc")
    vm.succeed("${guestPkgs.python3}/bin/python3 -m http.server 8111 >/dev/null 2>&1 &")
    vm.wait_for_open_port(8111)
    ${if isAarch64 then ''
      vm.succeed("systemctl reboot")
      vm.connected = False
    '' else ''
      vm.reboot()
    ''}
    vm.wait_for_unit("multi-user.target")
    vm.succeed("${guestPkgs.hello}/bin/hello")
    vm.succeed("${guestPkgs.nix}/bin/nix-store --query --requisites ${guestPkgs.hello}")
  '';
  args = {
    inherit testScript;
    sharedDirs = {};
    extraPathsToRegister = [ guestPkgs.hello guestPkgs.python3 ];
    memorySize = 1536;
    cpus = 3;
  };
  multiUserTest = runner: (runner args).sandboxed;
  runTestOnEveryImage = test:
    pkgs.lib.mapAttrs'
    (n: v: pkgs.lib.nameValuePair "${n}-multi-user-test" (test lib.yocto.${n}))
    lib.yocto.images;

  rootfs = lib.yocto.images."6_0";

  # The layout a wic image with bootimg-pcbios has: syslinux in front of the rootfs. The
  # initrd leaves the store to mount-store.service, the path an image's own kernel takes.
  bootableDisk = pkgs.runCommand "yocto-6_0-bootable.qcow2"
    {
      nativeBuildInputs = with pkgs; [ zstd dosfstools mtools syslinux util-linux qemu ];
      kernelArgs = lib.yocto.kernelQemuArgs { mountStore = false; };
    } ''
    zstd -d ${rootfs} -o rootfs.ext4
    initrd=$(echo "$kernelArgs" | grep -o -- '-initrd [^ ]*' | cut -d' ' -f2)
    rootSectors=$(( ($(stat -c %s rootfs.ext4) + 511) / 512 ))

    truncate -s $(( 131072 * 512 )) boot.img
    mkfs.vfat -n boot boot.img
    mcopy -i boot.img ${pkgs.linux}/bzImage ::/bzImage
    mcopy -i boot.img "$initrd" ::/initrd
    mcopy -i boot.img ${pkgs.writeText "syslinux.cfg" ''
      DEFAULT linux
      PROMPT 0
      TIMEOUT 0
      LABEL linux
        KERNEL /bzImage
        INITRD /initrd
        APPEND root=/dev/sda2 console=ttyS0
    ''} ::/syslinux.cfg
    mcopy -i boot.img ${pkgs.syslinux}/share/syslinux/ldlinux.c32 ::/ldlinux.c32
    syslinux --install boot.img

    rootStart=$(( 2048 + 131072 ))
    truncate -s $(( (rootStart + rootSectors + 2048) * 512 )) disk.raw
    sfdisk --quiet disk.raw <<EOF
    label: dos
    start=2048, size=131072, type=c, bootable
    start=$rootStart, size=$rootSectors, type=83
    EOF
    dd if=${pkgs.syslinux}/share/syslinux/mbr.bin of=disk.raw bs=440 count=1 conv=notrunc status=none
    dd if=boot.img of=disk.raw bs=512 seek=2048 conv=notrunc status=none
    dd if=rootfs.ext4 of=disk.raw bs=512 seek=$rootStart conv=notrunc status=none
    qemu-img convert -f raw -O qcow2 disk.raw $out
  '';
in
runTestOnEveryImage multiUserTest
// {
  fromRootfs-test = (lib.yocto.fromRootfs (args // { inherit rootfs; })).sandboxed;
}
// pkgs.lib.optionalAttrs (system == "x86_64-linux") {
  custom-test = (lib.yocto.custom (args // {
    image = bootableDisk;
    extraQemuArgs = lib.yocto.kernelQemuArgs { mountStore = false; root = "/dev/sda2"; };
    testScript = testScript + ''
      vm.succeed("journalctl -u mount-store.service | grep -F 'Finished'")
    '';
  })).sandboxed;
}
