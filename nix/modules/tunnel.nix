flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.openziti.tunnel;
  pkg = cfg.package;
in
{
  options.services.openziti.tunnel = {
    enable = lib.mkEnableOption "OpenZiti tunnel";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.stdenv.hostPlatform.system}.ziti;
      description = "The OpenZiti package to use.";
    };

    mode = lib.mkOption {
      type = lib.types.enum [ "host" "tproxy" "proxy" ];
      default = "host";
      description = "Tunnel mode: `host`, `tproxy`, or `proxy`.";
    };

    identityDir = lib.mkOption {
      type = lib.types.str;
      description = ''
        Path to the directory containing enrolled identity JSON file(s).
        The tunnel will load all identities from this directory.
      '';
    };

    dnsIpRange = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "100.64.0.1/10";
      description = "DNS service IP range for intercepted services. Only used with `tproxy` mode.";
    };

    resolver = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "udp://127.0.0.1:53";
      description = "DNS resolver address for the tunnel.";
    };

    lanInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "LAN interface for tproxy mode iptables rules. Required when mode is `tproxy`.";
    };

    verbose = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Verbosity level (higher = more verbose).";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments passed to `ziti tunnel`.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.ziti-tunnel = {
      isSystemUser = true;
      group = "ziti-tunnel";
      description = "OpenZiti Tunnel service user";
    };
    users.groups.ziti-tunnel = { };

    systemd.services.ziti-tunnel = {
      description = "OpenZiti Tunnel";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "ziti-tunnel";
        Group = "ziti-tunnel";
        ExecStart = lib.concatStringsSep " " (
          [ "${pkg}/bin/ziti" "tunnel" "${cfg.mode}" ]
          ++ [ "--identity-dir" cfg.identityDir ]
          ++ [ "--verbose" (toString cfg.verbose) ]
          ++ lib.optionals (cfg.resolver != null) [ "--resolver" cfg.resolver ]
          ++ lib.optionals (cfg.dnsIpRange != null) [ "--dns-ip-range" cfg.dnsIpRange ]
          ++ lib.optionals (cfg.lanInterface != null) [ "--lanIf" cfg.lanInterface ]
          ++ cfg.extraArgs
        );
        Restart = "always";
        RestartSec = 3;
        LimitNOFILE = 65535;

        # Hardening
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.identityDir ];
        NoNewPrivileges = lib.mkDefault (cfg.mode != "tproxy");
        PrivateTmp = true;
      } // lib.optionalAttrs (cfg.mode == "tproxy") {
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      };
    };
  };
}
