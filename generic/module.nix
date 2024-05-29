{ lib, ... }:

let
  inherit (lib) types;

  pkgsType = lib.mkOptionType {
    name = "nixpkgs";
    description = "An evaluation of Nixpkgs; the top level attribute set of packages";
    check = builtins.isAttrs;
  };

  nodeOptions = { config, name, ... }: {
    options = {
      virtualisation = {
        rootImage = lib.mkOption {
          type = types.package;
        };

        memorySize = lib.mkOption {
          type = types.ints.between 256 (1024 * 128);
          default = 1024;
        };

        cpus = lib.mkOption {
          type = types.ints.between 1 1024;
          default = 2;
        };

        # TODO: implement this properly, or remove the option
        # See: nixos/lib/testing/network.nix
        vlans = lib.mkOption {
          type = types.ints.between 1 1024;
          default = 1;
        };

        sharedDirectories = lib.mkOption {
          type = types.attrsOf
            (types.submodule {
              options = {
                source = lib.mkOption {
                  type = types.oneOf [ types.str types.path ];
                };
                target = lib.mkOption {
                  type = types.str;
                };
              };
            });
          default = { };
        };
      };
    };

    config = {
      # Include these shared directories by default, they are used by the test driver.
      virtualisation.sharedDirectories = {
        xchg = {
          source = ''"$TMPDIR"/xchg'';
          target = "/tmp/xchg";
        };
        shared = {
          source = ''"''${SHARED_DIR:-$TMPDIR/xchg}"'';
          target = "/tmp/shared";
        };
      };
    };
  };

in

{
  options = {
    nodes = lib.mkOption {
      type = types.attrsOf (types.submodule nodeOptions);
      default = { };
    };
  };
}
