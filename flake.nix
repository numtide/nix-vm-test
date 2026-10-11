{
  description = "Nix-VM-Test, re-use the NixOS VM integration test infrastructure on Ubuntu, Debian, Fedora, Rocky and Arch Linux";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs supportedSystems f;

      pkgsFor = system: import nixpkgs {
        overlays = [ self.overlays.default ];
        localSystem = system;
      };
    in
    {
      lib = forAllSystems (system: (pkgsFor system).testers.nonNixOSDistros);

      checks = forAllSystems (system:
        import ./tests {
          package = (pkgsFor system).testers.nonNixOSDistros;
          pkgs = pkgsFor system;
          inherit system;
        });

      overlays.default = import ./overlay.nix;
    };
}
