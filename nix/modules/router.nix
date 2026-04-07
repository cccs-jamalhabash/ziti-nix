flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.openziti.router;
  format = pkgs.formats.yaml { };

  configFile =
    if cfg.configFile != null
    then cfg.configFile
    else format.generate "ziti-router.yml" cfg.settings;

  pkg = cfg.package;
in
{
  options.services.openziti.router = {
    enable = lib.mkEnableOption "OpenZiti router";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.stdenv.hostPlatform.system}.ziti;
      description = "The OpenZiti package to use.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ziti-router";
      description = "State directory for the router.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a raw YAML config file. When set, `settings` is ignored.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        Router configuration as a Nix attribute set.
        Converted to YAML and passed to `ziti router run`.
        See upstream `etc/edge.router.yml` for all fields.
      '';
    };

    enrollment = {
      enable = lib.mkEnableOption "automatic router enrollment on first boot";

      tokenFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Path to a file containing the JWT enrollment token.
          Never put secrets in the Nix store.
        '';
      };

      keyAlg = lib.mkOption {
        type = lib.types.enum [ "EC" "RSA" ];
        default = "EC";
        description = "Key algorithm for enrollment (EC = P-256, RSA = 4096).";
      };
    };

    tunnelerMode = lib.mkOption {
      type = lib.types.enum [ "none" "host" "tproxy" "proxy" ];
      default = "none";
      description = "Tunneler mode for the router. `none` disables the built-in tunnel listener.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments passed to `ziti router run`.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open firewall ports for the router listeners.";
    };

    firewallPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 3022 7099 ];
      description = "TCP ports to open when `openFirewall` is enabled.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.ziti-router = {
      isSystemUser = true;
      group = "ziti-router";
      home = cfg.stateDir;
      description = "OpenZiti Router service user";
    };
    users.groups.ziti-router = { };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall cfg.firewallPorts;

    systemd.services.ziti-router = {
      description = "OpenZiti Router";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart = lib.optionalString cfg.enrollment.enable ''
        # --- Enrollment (idempotent) ---
        IDENTITY_CERT="${cfg.settings.identity.cert or "${cfg.stateDir}/certs/cert.pem"}"
        if [[ ! -s "$IDENTITY_CERT" ]]; then
          TOKEN_FILE="${cfg.enrollment.tokenFile}"
          if [[ -s "$TOKEN_FILE" ]]; then
            ${pkg}/bin/ziti router enroll ${configFile} \
              --jwt "$TOKEN_FILE"
          else
            echo "ERROR: enrollment token file not found or empty: $TOKEN_FILE" >&2
            exit 1
          fi
        fi
      '';

      serviceConfig = {
        Type = "simple";
        User = "ziti-router";
        Group = "ziti-router";
        StateDirectory = "ziti-router";
        WorkingDirectory = cfg.stateDir;
        ExecStart = lib.concatStringsSep " " (
          [ "${pkg}/bin/ziti" "router" "run" "${configFile}" ]
          ++ cfg.extraArgs
        );
        Restart = "always";
        RestartSec = 3;
        LimitNOFILE = 65535;
        UMask = "0007";

        # Hardening
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
        NoNewPrivileges = true;
        PrivateTmp = true;
      } // lib.optionalAttrs (cfg.tunnelerMode == "tproxy") {
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      };
    };
  };
}
