flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.openziti.controller;
  format = pkgs.formats.yaml { };

  configFile =
    if cfg.configFile != null
    then cfg.configFile
    else format.generate "ziti-controller.yml" cfg.settings;

  pkg = cfg.package;
in
{
  options.services.openziti.controller = {
    enable = lib.mkEnableOption "OpenZiti controller";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.stdenv.hostPlatform.system}.ziti;
      description = "The OpenZiti package to use.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ziti-controller";
      description = "State directory for the controller.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a raw YAML config file. When set, `settings` is ignored.
        Use this escape hatch if the Nix option tree does not cover your needs.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        Controller configuration as a Nix attribute set.
        Converted to YAML and passed to `ziti controller run`.
        See upstream `etc/ctrl.with.edge.yml` for all fields.
      '';
    };

    pki = {
      autoGenerate = lib.mkEnableOption "automatic PKI generation on first boot";

      pkiRoot = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.stateDir}/pki";
        defaultText = lib.literalExpression ''"''${cfg.stateDir}/pki"'';
        description = "Root directory for PKI material.";
      };

      caFile = lib.mkOption {
        type = lib.types.str;
        default = "root-ca";
        description = "Name of the root CA directory inside pkiRoot.";
      };

      intermediateFile = lib.mkOption {
        type = lib.types.str;
        default = "intermediate-ca";
        description = "Name of the intermediate CA directory inside pkiRoot.";
      };

      serverFile = lib.mkOption {
        type = lib.types.str;
        default = "server";
        description = "Leaf server certificate file name.";
      };

      clientFile = lib.mkOption {
        type = lib.types.str;
        default = "client";
        description = "Leaf client certificate file name.";
      };

      trustDomain = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "SPIFFE trust domain for the PKI. Required when autoGenerate is enabled.";
      };

      advertisedAddress = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "Advertised address (FQDN or IP) used as DNS SAN in certificates.";
      };
    };

    database = {
      autoInit = lib.mkEnableOption "automatic database initialization on first boot";

      adminUser = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "Default admin username for edge init.";
      };

      adminPasswordFile = lib.mkOption {
        type = lib.types.str;
        description = ''
          Path to a file containing the admin password.
          Never put passwords in the Nix store. Compatible with sops-nix, agenix, etc.
        '';
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments passed to `ziti controller run`.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open firewall ports for the controller listeners.";
    };

    firewallPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 6262 1280 ];
      description = "TCP ports to open when `openFirewall` is enabled.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.ziti-controller = {
      isSystemUser = true;
      group = "ziti-controller";
      home = cfg.stateDir;
      description = "OpenZiti Controller service user";
    };
    users.groups.ziti-controller = { };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall cfg.firewallPorts;

    systemd.services.ziti-controller = {
      description = "OpenZiti Controller";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart =
        let
          pkiScript = lib.optionalString cfg.pki.autoGenerate ''
            # --- PKI auto-generation (idempotent) ---
            PKI_ROOT="${cfg.pki.pkiRoot}"
            CA="${cfg.pki.caFile}"
            INTER="${cfg.pki.intermediateFile}"
            SERVER="${cfg.pki.serverFile}"
            CLIENT="${cfg.pki.clientFile}"
            ADDR="${cfg.pki.advertisedAddress}"

            mkdir -p "$PKI_ROOT"

            # Root CA
            if [[ ! -s "$PKI_ROOT/$CA/certs/$CA.cert" ]]; then
              ${pkg}/bin/ziti pki create ca \
                --pki-root "$PKI_ROOT" \
                --ca-file "$CA" \
                ${lib.optionalString (cfg.pki.trustDomain != "") ''--trust-domain "spiffe://${cfg.pki.trustDomain}"''}
            fi

            # Intermediate CA
            if [[ ! -s "$PKI_ROOT/$INTER/certs/$INTER.cert" ]]; then
              ${pkg}/bin/ziti pki create intermediate \
                --pki-root "$PKI_ROOT" \
                --ca-name "$CA" \
                --intermediate-file "$INTER"
            fi

            # Server certificate (also generates its own key)
            if [[ ! -s "$PKI_ROOT/$INTER/certs/$SERVER.chain.pem" ]]; then
              DNS_SANS="localhost"
              IP_SANS="127.0.0.1,::1"
              if [[ "$ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                IP_SANS="$IP_SANS,$ADDR"
              else
                DNS_SANS="$DNS_SANS,$ADDR"
              fi
              ${pkg}/bin/ziti pki create server \
                --pki-root "$PKI_ROOT" \
                --ca-name "$INTER" \
                --server-file "$SERVER" \
                --server-name "ziti-controller" \
                --dns "$DNS_SANS" \
                --ip "$IP_SANS"
            fi

            # Client certificate (reuses the server key)
            if [[ ! -s "$PKI_ROOT/$INTER/certs/$CLIENT.chain.pem" ]]; then
              ${pkg}/bin/ziti pki create client \
                --pki-root "$PKI_ROOT" \
                --ca-name "$INTER" \
                --key-file "$SERVER" \
                --client-file "$CLIENT" \
                --client-name "ziti-controller"
            fi
          '';

          dbScript = lib.optionalString cfg.database.autoInit ''
            # --- Database auto-init (idempotent) ---
            DB_PATH="${cfg.settings.db or "${cfg.stateDir}/db/ctrl.db"}"
            if [[ ! -f "$DB_PATH" ]]; then
              mkdir -p "$(dirname "$DB_PATH")"
              ${pkg}/bin/ziti controller edge init ${configFile} \
                --username "${cfg.database.adminUser}" \
                --password "$(cat '${cfg.database.adminPasswordFile}')"
            fi
          '';
        in
        pkiScript + dbScript;

      serviceConfig = {
        Type = "simple";
        User = "ziti-controller";
        Group = "ziti-controller";
        StateDirectory = "ziti-controller";
        WorkingDirectory = cfg.stateDir;
        ExecStart = lib.concatStringsSep " " (
          [ "${pkg}/bin/ziti" "controller" "run" "${configFile}" ]
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
      };
    };
  };
}
