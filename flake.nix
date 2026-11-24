{
  description = "Native NixOS homeserver installer";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in {
      nixosModules.default = import ./module.nix;
      nixosConfigurations.test = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ self.nixosModules.default {
          system.stateVersion = "26.05";
          fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
          boot.loader.grub.device = "/dev/vda";
        } ];
      };
      packages = forAll (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in {
          default = pkgs.writeShellApplication {
            name = "homeserver-install";
            runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
            text = ''
              export HOMESERVER_SOURCE=${self.outPath}
              export HOMESERVER_NIXPKGS_REV=${nixpkgs.rev}
              ${builtins.readFile ./install.sh}
            '';
          };
        });
      apps = forAll (system: {
        default = { type = "app"; program = "${self.packages.${system}.default}/bin/homeserver-install"; };
      });
    };
}
