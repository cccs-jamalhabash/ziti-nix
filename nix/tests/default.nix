# NixOS VM integration test for OpenZiti controller + router.
#
# Run with:
#   nix build .#checks.x86_64-linux.controller-router-test
#
{ self, testers, writeText, ... }:

let
  controllerPort = 6262;
  edgePort = 1280;
  trustDomain = "nixziti-test";
  adminPassword = "testpassword123!";

  # write a password file for the controller
  adminPasswordFile = writeText "admin-password" adminPassword;
in
testers.nixosTest {
  name = "openziti-controller-router";

  nodes = {
    controller = { config, pkgs, ... }: {
      imports = [ self.nixosModules.default ];

      services.openziti.controller = {
        enable = true;

        pki = {
          autoGenerate = true;
          trustDomain = trustDomain;
          advertisedAddress = "controller";
        };

        database = {
          autoInit = true;
          adminPasswordFile = toString adminPasswordFile;
        };

        settings = {
          v = 3;
          db = "/var/lib/ziti-controller/db/ctrl.db";
          trustDomain = trustDomain;

          identity = {
            cert = "/var/lib/ziti-controller/pki/intermediate-ca/certs/client.chain.pem";
            server_cert = "/var/lib/ziti-controller/pki/intermediate-ca/certs/server.chain.pem";
            key = "/var/lib/ziti-controller/pki/intermediate-ca/keys/server.key";
            ca = "/var/lib/ziti-controller/pki/intermediate-ca/certs/intermediate-ca.chain.pem";
          };

          ctrl = {
            listener = "tls:0.0.0.0:${toString controllerPort}";
          };

          edge = {
            enrollment = {
              signingCert = {
                cert = "/var/lib/ziti-controller/pki/intermediate-ca/certs/intermediate-ca.cert";
                key = "/var/lib/ziti-controller/pki/intermediate-ca/keys/intermediate-ca.key";
              };
              edgeIdentity.duration = "5m";
              edgeRouter.duration = "5m";
            };
            api = {
              sessionTimeout = "30m";
              address = "controller:${toString edgePort}";
            };
          };

          healthChecks.boltCheck = {
            interval = "30s";
            timeout = "15s";
            initialDelay = "15s";
          };

          web = [
            {
              name = "all-apis";
              bindPoints = [
                {
                  interface = "0.0.0.0:${toString edgePort}";
                  address = "controller:${toString edgePort}";
                }
              ];
              apis = [
                { binding = "health-checks"; }
                { binding = "fabric"; }
                { binding = "edge-management"; }
                { binding = "edge-client"; }
                { binding = "edge-oidc"; }
              ];
            }
          ];
        };

        openFirewall = true;
        firewallPorts = [ controllerPort edgePort ];
      };
    };
  };

  testScript = ''
    controller.start()
    controller.wait_for_unit("ziti-controller.service")
    controller.wait_for_open_port(${toString controllerPort})
    controller.wait_for_open_port(${toString edgePort})

    # Verify the controller is responding on the edge API
    controller.succeed(
        "curl -sk https://localhost:${toString edgePort}/edge/client/v1/version | grep -q version"
    )
  '';
}
