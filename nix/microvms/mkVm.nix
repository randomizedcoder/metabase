# nix/microvms/mkVm.nix
#
# NixOS test VM definition for Metabase lifecycle testing.
# Parameterized by architecture for multi-arch support.
#
{
  pkgs,
  lib,
  metabase,
  nixpkgs,
  arch,
  buildSystem ? "x86_64-linux",
}:

let
  constants = import ./constants.nix;
  cfg = constants.architectures.${arch};
  timeouts = constants.getTimeouts arch;

  # For the target system's packages
  targetPkgs = nixpkgs.legacyPackages.${cfg.nixSystem};
in
pkgs.testers.nixosTest {
  name = "metabase-lifecycle-${arch}";

  nodes.server =
    { config, pkgs, ... }:
    {
      # VM resources
      virtualisation.memorySize = cfg.mem;
      virtualisation.cores = cfg.vcpu;

      # PostgreSQL for Metabase backend
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_18;
        initialScript = pkgs.writeText "metabase-init.sql" ''
          CREATE DATABASE metabase;
        '';
      };

      # Metabase systemd service
      systemd.services.metabase = {
        description = "Metabase Application Server";
        after = [
          "postgresql.service"
          "network.target"
        ];
        requires = [ "postgresql.service" ];
        wantedBy = [ "multi-user.target" ];

        environment = {
          MB_DB_TYPE = "postgres";
          MB_DB_DBNAME = "metabase";
          MB_DB_PORT = "5432";
          MB_DB_HOST = "localhost";
          MB_DB_USER = "metabase";
          MB_JETTY_HOST = "0.0.0.0";
          MB_JETTY_PORT = toString constants.metabasePort;
          JAVA_OPTS = "-Xmx1g";
        };

        serviceConfig = {
          ExecStart = "${metabase}/bin/metabase";
          User = "metabase";
          Group = "metabase";
          StateDirectory = "metabase";
          WorkingDirectory = "/var/lib/metabase";
          Restart = "on-failure";
          RestartSec = 10;
          TimeoutStartSec = toString timeouts.metabaseStart;
        };
      };

      # Create metabase user for PostgreSQL
      users.users.metabase = {
        isSystemUser = true;
        group = "metabase";
      };
      users.groups.metabase = { };

      # PostgreSQL authentication for metabase user
      services.postgresql.authentication = lib.mkForce ''
        local all all trust
        host all all 127.0.0.1/32 trust
        host all all ::1/128 trust
      '';
      services.postgresql.ensureUsers = [
        {
          name = "metabase";
          ensureDBOwnership = true;
        }
      ];
      services.postgresql.ensureDatabases = [ "metabase" ];

      # Required packages for test assertions
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      # Open firewall for Metabase
      networking.firewall.allowedTCPPorts = [ constants.metabasePort ];
    };

  # Test script (Python, NixOS test framework)
  testScript = ''
    server.start()
    server.wait_for_unit("postgresql.service")
    server.wait_for_unit("metabase.service")
    server.wait_for_open_port(${toString constants.metabasePort})

    # Health check — Metabase needs time to initialize after port opens
    import time
    for i in range(120):
        status, output = server.execute("curl -sf ${constants.healthEndpoint}")
        if status == 0 and "ok" in output:
            print(f"Metabase healthy after {i*2}s")
            break
        time.sleep(2)
    else:
        raise Exception("Metabase did not become healthy within 240s")

    server.succeed("curl -sf ${constants.healthEndpoint}")

    # API smoke test
    result = server.succeed("curl -sf ${constants.setupEndpoint} | jq .version")
    print(f"Metabase version: {result}")
  '';
}
