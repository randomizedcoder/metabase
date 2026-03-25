# Metabase Nix Flake
#
# Quick start:
#   nix develop                       - Dev shell (Java 21, Node 22, Bun, Clojure, PostgreSQL 18)
#   nix build                         - Build metabase.jar from source
#   nix build .#oci-x86_64            - Build OCI container (x86_64)
#   nix build .#oci-aarch64           - Build OCI container (ARM64)
#   nix build .#oci-riscv64           - Build OCI container (RISC-V 64)
#   nix build .#tests-all             - Run all integration tests
#   nix build .#microvm-test-x86_64   - Run NixOS VM lifecycle test (x86_64)
#   nix build .#microvm-test-aarch64  - Run NixOS VM lifecycle test (ARM64)
#   nix run .#mb-lifecycle-full-test-x86_64  - Full lifecycle test with timing
#
# Sub-derivations (for targeted rebuilds):
#   nix build .#frontend              - Frontend assets only
#   nix build .#static-viz            - Static visualization bundle only
#   nix build .#translations          - i18n artifacts only
#   nix build .#drivers               - Database drivers only
#
# Debugging:
#   MB_NIX_DEBUG=1 nix develop        - Debug mode with verbose env output
#
{
  description = "Metabase - Business Intelligence and Embedded Analytics";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # For local development with a pinned nixpkgs checkout:
    # nixpkgs.url = "path:/path/to/your/nixpkgs";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = nixpkgs.lib;

        # Version from git or fallback
        version = "0.0.0-nix";

        # Import packages module
        packagesModule = import ./nix/packages.nix { inherit pkgs; };

        # Import environment variables
        envVars = import ./nix/env-vars.nix {
          inherit pkgs;
          packages = packagesModule;
        };

        # Filter source to exclude Nix files, .git, flake inputs
        # Editing .nix files won't invalidate sub-derivation caches
        filteredSrc = lib.cleanSourceWith {
          src = ./.;
          filter =
            path: type:
            let
              relPath = lib.removePrefix (toString ./.) path;
            in
            !(lib.hasPrefix "/nix" relPath)
            && !(lib.hasPrefix "/flake" relPath)
            && !(lib.hasPrefix "/.git" relPath)
            && !(lib.hasSuffix ".nix" relPath);
        };

        # Import derivation orchestrator
        derivation = import ./nix/derivation {
          inherit pkgs lib version;
          jre = packagesModule.jre;
          src = filteredSrc;
          edition = "oss";
        };

        # The final Metabase package
        metabase = derivation.metabase;

        # Import development shell
        devshell = import ./nix/devshell.nix {
          inherit pkgs lib envVars;
          packages = packagesModule;
        };

        # Import OCI container images
        oci = import ./nix/oci {
          inherit
            pkgs
            lib
            metabase
            version
            ;
          jre = packagesModule.jre;
        };

        # Import tests
        tests = import ./nix/tests {
          inherit pkgs lib metabase;
        };

        # Import MicroVM infrastructure
        microvms = import ./nix/microvms {
          inherit
            pkgs
            lib
            metabase
            nixpkgs
            ;
          buildSystem = system;
        };

      in
      {
        # ===================================================================
        # Packages
        # ===================================================================

        packages = {
          # Primary outputs
          default = metabase;
          metabase = metabase;

          # Sub-derivations (for targeted rebuilds)
          frontend = derivation.frontend;
          static-viz = derivation.staticViz;
          translations = derivation.translations;
          drivers = derivation.drivers.all;
          uberjar = derivation.uberjar;
          deps-clojure = derivation.clojureDeps;
          deps-frontend = derivation.frontendDeps;

          # Individual driver derivations (nix build .#driver-clickhouse, etc.)
        }
        // (lib.mapAttrs' (name: drv: lib.nameValuePair "driver-${name}" drv) (
          removeAttrs derivation.drivers [ "all" ]
        ))
        // {

          # Tests
          tests-health-check = tests.health-check;
          tests-api-smoke = tests.api-smoke;
          tests-db-migration = tests.db-migration;
          tests-all = tests.all;

          # OCI lifecycle tests (per-arch)
          tests-oci-x86_64 = tests.oci-lifecycle.x86_64;
          tests-oci-aarch64 = tests.oci-lifecycle.aarch64;
          tests-oci-riscv64 = tests.oci-lifecycle.riscv64;

          # MicroVM tests
          microvm-test-x86_64 = microvms.vms.x86_64;
          microvm-test-aarch64 = microvms.vms.aarch64;
          microvm-test-riscv64 = microvms.vms.riscv64;

          # MicroVM test runners
          mb-test-all = microvms.testAll;

          # Convenience: format all Nix files
          fmt = pkgs.writeShellApplication {
            name = "mb-nix-fmt";
            runtimeInputs = [ pkgs.nixfmt ];
            text = ''
              nixfmt nix/ flake.nix
            '';
          };

        }
        // oci
        // microvms.packages; # Flatten OCI + lifecycle scripts into packages

        # ===================================================================
        # Development Shell
        # ===================================================================

        devShells.default = devshell;

        # ===================================================================
        # Checks (for `nix flake check`)
        # ===================================================================

        checks = {
          # Fast checks
          formatting =
            pkgs.runCommand "check-nix-format"
              {
                nativeBuildInputs = [ pkgs.nixfmt ];
              }
              ''
                nixfmt --check ${./nix} ${./flake.nix}
                touch $out
              '';

          build-smoke = pkgs.runCommand "mb-test-build-smoke" { } ''
            test -f ${metabase}/bin/metabase
            test -f ${metabase}/share/metabase/metabase.jar
            touch $out
          '';

          oci-builds = pkgs.runCommand "check-oci-builds" { } ''
            test -f ${oci.oci-x86_64}
            touch $out
          '';

          # Integration tests (slower — require PostgreSQL/Docker)
          health-check = tests.health-check;
          api-smoke = tests.api-smoke;
          db-migration = tests.db-migration;
        };

        # ===================================================================
        # Formatter (for `nix fmt`)
        # ===================================================================

        formatter = pkgs.nixfmt;
      }
    );
}
