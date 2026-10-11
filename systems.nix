# Maps a host system to the Linux guest system its VMs run as.
#
# VM tests always run a Linux guest. On a Linux host the guest matches the host;
# on darwin we run the same-architecture Linux guest (accelerated via HVF), which
# requires a Linux builder to build the guest closure.
hostSystem:
{
  "x86_64-linux" = "x86_64-linux";
  "aarch64-linux" = "aarch64-linux";
  "aarch64-darwin" = "aarch64-linux";
}.${hostSystem} or (throw ''
  nix-vm-test: unsupported host system '${hostSystem}'.
  Supported host systems: x86_64-linux, aarch64-linux, aarch64-darwin.
'')
