{
  description = "Nix-VM-Test, re-use the NixOS VM integration test infrastructure on Ubuntu, Debian and Fedora";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: lib.genAttrs supportedSystems f;
      guestSystemFor = import ./systems.nix;

      pkgsFor = system: import nixpkgs {
        overlays = [ self.overlays.default ];
        localSystem = system;
      };
      # Reuse the host's own evaluation when the guest matches it (the common,
      # non-darwin case), instead of importing nixpkgs a second time from scratch.
      guestPkgsFor = system:
        let guestSystem = guestSystemFor system;
        in if guestSystem == system
          then pkgsFor system
          else import nixpkgs { localSystem = guestSystem; };
    in
    {
      lib = forAllSystems (system: (pkgsFor system).testers.nonNixOSDistros);

      checks = forAllSystems (system:
        import ./tests {
          package = (pkgsFor system).testers.nonNixOSDistros;
          pkgs = pkgsFor system;
          guestPkgs = guestPkgsFor system;
          inherit system;
        });

      overlays.default = import ./overlay.nix;
    };
}
