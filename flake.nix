{
  description = "NixOS module and package for OpenZiti zero-trust networking";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          ziti = pkgs.callPackage ./nix/package.nix { };
          default = self.packages.${system}.ziti;
        }
      );

      nixosModules = {
        controller = import ./nix/modules/controller.nix self;
        router = import ./nix/modules/router.nix self;
        tunnel = import ./nix/modules/tunnel.nix self;
        default = {
          imports = [
            self.nixosModules.controller
            self.nixosModules.router
            self.nixosModules.tunnel
          ];
        };
      };

      checks = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          controller-router-test = pkgs.callPackage ./nix/tests/default.nix {
            inherit self;
            inherit (pkgs) testers writeText;
          };
        }
      );

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.go
              self.packages.${system}.ziti
            ];
          };
        }
      );
    };
}
