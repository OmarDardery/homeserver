{
  description = "Native NixOS homeserver installer";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.sops-nix = {
    url = "github:Mic92/sops-nix/d5abe5e53200ad48254e8e6bd95e6cef94e66577";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, nixpkgs, sops-nix }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in {
      nixosModules.default = { imports = [ sops-nix.nixosModules.sops ./module.nix ]; };
      nixosConfigurations.test = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ self.nixosModules.default {
          system.stateVersion = "26.05";
          fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
          boot.loader.grub.device = "/dev/vda";
        } ];
      };
      packages = forAll (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          klipper-deploy = pkgs.writeShellApplication {
            name = "homeserver-klipper-deploy";
            runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.gnugrep pkgs.curl ];
            text = ''
              export HOMESERVER_SOURCE=${self.outPath}
              ${builtins.readFile ./klipper-deploy.sh}
            '';
          };
        in {
          inherit klipper-deploy;
          default = pkgs.writeShellApplication {
            name = "homeserver-install";
            runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.sops pkgs.age klipper-deploy ];
            text = ''
              export HOMESERVER_SOURCE=${self.outPath}
              export HOMESERVER_NIXPKGS_REV=${nixpkgs.rev}
              export HOMESERVER_SOPS_REV=${sops-nix.rev}
              ${builtins.readFile ./install.sh}
            '';
          };
        });
      apps = forAll (system: {
        default = { type = "app"; program = "${self.packages.${system}.default}/bin/homeserver-install"; };
        klipper-deploy = { type = "app"; program = "${self.packages.${system}.klipper-deploy}/bin/homeserver-klipper-deploy"; };
      });
    };
}
