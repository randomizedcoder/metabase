# Metabase Nix Configuration

Reproducible builds, development environments, and container images for Metabase using Nix.

## Table of Contents

- [Background](#background)
  - [Why Nix for Metabase?](#why-nix-for-metabase)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Module Structure](#module-structure)
- [Sub-Derivation Pipeline](#sub-derivation-pipeline)
- [Source Filtering](#source-filtering)
- [Dev Shell](#dev-shell)
- [Building](#building)
- [OCI Containers](#oci-containers)
- [Multi-Architecture Support](#multi-architecture-support)
- [MicroVM Lifecycle Tests](#microvm-lifecycle-tests)
- [Integration Tests](#integration-tests)
- [Troubleshooting](#troubleshooting)

## Background

[Nix](https://nixos.org) is a package manager for Linux and macOS that provides **reproducible, isolated** environments. By tracking all dependencies and hashing their content, it ensures every developer uses the same versions of every tool.

### Why Nix for Metabase?

- **Reproducible builds** — identical output regardless of host system; no more "it worked on my machine"
- **Fast onboarding** — `nix develop` downloads and configures JDK, Clojure, Node.js, Bun, and all other tools automatically
- **Granular caching** — the build is split into independent sub-derivations so changing a backend file doesn't rebuild the frontend
- **Multi-architecture** — build OCI container images for x86_64, aarch64, and riscv64 from a single machine
- **No global pollution** — all dependencies live in `/nix/store`, leaving your system packages untouched

You do **not** need to run NixOS. Nix works alongside any Linux distribution or macOS.

## Prerequisites

### Install Nix

If you already have Nix installed, skip to [Quick Start](#quick-start).

**Recommended: Determinate Systems installer** (enables flakes automatically):
```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh
```

**Alternative: Official installer**

- Multi-user (recommended):
  ```bash
  bash <(curl -L https://nixos.org/nix/install) --daemon
  ```
- Single-user:
  ```bash
  bash <(curl -L https://nixos.org/nix/install) --no-daemon
  ```

If using the official installer, enable flakes:
```bash
test -d /etc/nix || sudo mkdir /etc/nix
echo 'experimental-features = nix-command flakes' | sudo tee -a /etc/nix/nix.conf
```

#### Video Tutorials

| Platform | Video |
|----------|-------|
| Ubuntu | [Installing Nix on Ubuntu](https://youtu.be/cb7BBZLhuUY) |
| Fedora | [Installing Nix on Fedora](https://youtu.be/RvaTxMa4IiY) |

#### Learn More

- [Nix official site](https://nixos.org)
- [Nix Flakes Wiki](https://nixos.wiki/wiki/flakes)
- [Search Nix packages](https://search.nixos.org/packages?channel=unstable)

## Quick Start

```bash
# Enter development shell (all tools pre-configured)
nix develop

# Build Metabase from source
nix build

# Run the built Metabase
./result/bin/metabase

# Build an OCI container image
nix build .#oci-x86_64
```

**Optional: direnv integration** — create a `.envrc` with `use flake` for automatic shell activation when you `cd` into the project directory. See [direnv wiki](https://github.com/direnv/direnv/wiki/Nix) for setup.

## Module Structure

| File | Purpose | Cache Trigger |
|------|---------|---------------|
| `packages.nix` | Dependency declarations (4 tiers) | — |
| `env-vars.nix` | Shell environment variables | — |
| `devshell.nix` | Developer shell configuration | — |
| `derivation/deps-clojure.nix` | Maven/Clojure dependency prefetch ([FOD](#fixed-output-derivation-fod-hash-updates)) | `deps.edn` |
| `derivation/deps-frontend.nix` | Bun/Node dependency prefetch ([FOD](#fixed-output-derivation-fod-hash-updates)) | `bun.lock` |
| `derivation/translations.nix` | i18n artifact build | `locales/`, `src/` |
| `derivation/frontend.nix` | Frontend build (rspack + shadow-cljs) | `frontend/`, `src/` |
| `derivation/static-viz.nix` | Static visualization bundle (rspack) | `frontend/`, `src/` |
| `derivation/drivers.nix` | Per-driver JAR builds (17 derivations) | `modules/`, `src/` |
| `derivation/uberjar.nix` | Final JAR assembly | `src/` |
| `derivation/lib.nix` | Shared build helpers (frontendBuildInputs, setupClojureDeps, etc.) | — |
| `derivation/patch-git-deps.sh` | Patches git deps for offline builds | — |
| `derivation/patch-mvn-repos.sh` | Patches Maven repo URLs for offline builds | — |
| `derivation/default.nix` | Orchestrator: source filtering + wiring | — |
| `oci/default.nix` | Multi-arch OCI container images | — |
| `oci/layers.nix` | Layer decomposition strategy | — |
| `microvms/constants.nix` | Ports, timeouts, lifecycle config | — |
| `microvms/default.nix` | VM entry point (all architectures) | — |
| `microvms/mkVm.nix` | NixOS test VM definition | — |
| `microvms/lib.nix` | Reusable polling/lifecycle helpers | — |
| `tests/default.nix` | Test entry point | — |
| `tests/lib.nix` | Reusable test helpers | — |
| `tests/health-check.nix` | `/api/health` polling test | — |
| `tests/api-smoke.nix` | `/api/session/properties` test | — |
| `tests/db-migration.nix` | PostgreSQL migration test | — |
| `tests/oci-lifecycle.nix` | OCI container lifecycle test | — |
| `shell-functions/build.nix` | Build commands (mb-build, mb-repl, etc.) | — |
| `shell-functions/clean.nix` | Clean commands (mb-clean-frontend, etc.) | — |
| `shell-functions/database.nix` | PostgreSQL commands (pg-start, pg-stop, etc.) | — |
| `shell-functions/navigation.nix` | Navigation commands (mb-src, mb-frontend, etc.) | — |
| `shell-functions/validation.nix` | Environment check and help (mb-check-env, mb-help) | — |

## Sub-Derivation Pipeline

Instead of one monolithic build, we split into **7 cached stages**. Each stage receives a **filtered source tree** containing only the directories it needs, so changing a backend `.clj` file won't invalidate the frontend cache and vice versa.

```
┌─────────────────┐    ┌──────────────────┐
│  deps-clojure   │    │  deps-frontend   │    ← FODs: only rebuild when lockfiles change
│  (full src)     │    │  (full src)      │
└───────┬─────────┘    └────────┬─────────┘
        │                       │
   ┌────┼──────────────────┐      │
   │    │                  │      ├──────────────┐
   │    │                  │      │              │
   ▼    ▼                  ▼      ▼              ▼
┌──────┐ ┌──────────────┐ ┌────────┐ ┌──────────┐
│trans-│ │ 17 individual│ │frontend│ │static-viz│  ← filtered source per derivation
│lation│ │   drivers    │ │(rspack │ │(rspack   │
│(i18n)│ │ (parallel)   │ │+cljs)  │ │+cljs)    │
└──┬───┘ └──────┬───────┘ └───┬────┘ └────┬─────┘
   │      ┌─────▼──────┐      │           │
   │      │ drivers-all│      │           │
   │      │ (merge)    │      │           │
   │      └─────┬──────┘      │           │
   └────────┬───┘─────────────┴───────────┘
            │
   ┌────────▼────────────────────┐
   │          uberjar            │               ← final assembly, combines all above
   │    (metabase.jar)           │
   └─────────────┬───────────────┘
                 │
   ┌─────────────▼──────────────┐
   │       metabase             │               ← wrapper script (no source needed)
   └─────────────┬──────────────┘
                 │
     ┌───────────┼───────────────┐
     │           │               │
┌────▼────┐ ┌───▼────┐  ┌──────▼──────┐
│OCI x86  │ │OCI arm │  │OCI riscv64  │        ← arch-specific: only JRE layer differs
└─────────┘ └────────┘  └─────────────┘
```

**Cache wins with source filtering:**

| Change | Rebuilds | Skips |
|--------|----------|-------|
| `src/metabase/*.clj` | translations, all drivers, uberjar | frontend, static-viz |
| `frontend/src/**` | frontend, static-viz | translations, all drivers |
| `modules/drivers/clickhouse/**` | driver-clickhouse, drivers-all, uberjar | all other 16 drivers, frontend, static-viz, translations |
| `modules/drivers/**` (broad) | all drivers, uberjar | frontend, static-viz, translations |
| `locales/**` | translations | frontend, static-viz, all drivers |
| `deps.edn` | deps-clojure + all downstream | deps-frontend |
| Nothing | everything cached | — |

## Source Filtering

Each sub-derivation receives a filtered source tree via the `srcFor` helper in `default.nix`. This ensures derivations only rebuild when files they actually use change.

### How It Works

All top-level source directories are mapped to named **components** in the `sourceComponents` attrset:

```nix
sourceComponents = {
  backend   = [ "/src" "/enterprise/backend" "/.clj-kondo" ];
  frontend  = [ "/frontend" "/enterprise/frontend" "/docs" ];
  drivers   = [ "/modules" ];
  i18n      = [ "/locales" ];
  build     = [ "/bin" ];
  resources = [ "/resources" ];
  testing   = [ "/test" "/test_modules" ... ];
  tooling   = [ "/dev" "/cross-version" ... ];
};
```

Each derivation declares which components it needs:

```nix
translationFilter = [ "build" "backend" "resources" "i18n" ];
frontendFilter    = [ "build" "frontend" "backend" "resources" ];
driverFilter      = [ "build" "backend" "resources" "drivers" ];
uberjarFilter     = [ "build" "backend" "resources" ];
```

Root-level files (`deps.edn`, `package.json`, `shadow-cljs.edn`, etc.) are always included regardless of filter.

### Coverage Assertion

A Nix assertion ensures every top-level directory is mapped in `sourceComponents`. If a new directory is added to the repo without being mapped, `nix build` fails immediately:

```
error: Unmapped source directories: new-dir. Add them to sourceComponents in default.nix.
```

### Adding a New Top-Level Directory

1. `nix build` fails with the unmapped directory error
2. Add the directory to the appropriate component in `sourceComponents` (or create a new component)
3. If a derivation needs access to it, add the component name to that derivation's filter list

### Frontend / Static-Viz Split

The frontend is split into two independent derivations:

- **`frontend.nix`**: Main bundle (`bun run build-release`) — rspack + shadow-cljs
- **`static-viz.nix`**: Static visualization bundle (`bun run build-release:static-viz`) — rspack + shadow-cljs

Both use the same source filter (`frontendFilter`) since static-viz imports broadly from `frontend/src/metabase/`. Both need shadow-cljs output (the `cljs/` alias in rspack configs). The split allows them to build **in parallel**.

### Per-Driver Derivations

Each of the 17 database drivers is built as its own derivation. Changing the clickhouse driver source doesn't invalidate the snowflake cache, etc.

```bash
# Build a single driver
nix build .#driver-clickhouse
nix build .#driver-sqlite
nix build .#driver-sparksql

# Build all drivers (combined output)
nix build .#drivers
```

All 17 drivers: `athena`, `bigquery-cloud-sdk`, `clickhouse`, `databricks`, `druid`, `druid-jdbc`, `hive-like`, `mongo`, `oracle`, `presto-jdbc`, `redshift`, `snowflake`, `sparksql`, `sqlite`, `sqlserver`, `starburst`, `vertica`.

The `drivers.all` derivation is a lightweight aggregator that copies all individual JARs into a single output — it doesn't rebuild anything, just merges store paths. The `uberjar` derivation consumes this combined output.

**Driver dependencies**: sparksql depends on hive-like at the Clojure source level. The build system handles this automatically — each driver build has the full `modules/` source tree available.

## Dev Shell

The dev shell provides all tools needed for Metabase development:

```bash
nix develop
```

### Available Commands

| Command | Description |
|---------|-------------|
| `mb-help` | Show all available commands |
| `mb-check-env` | Verify all tool versions |
| **Navigation** | |
| `mb-src` | `cd` to `src/metabase` |
| `mb-frontend` | `cd` to `frontend` |
| `mb-test` | `cd` to `test` |
| `mb-drivers` | `cd` to `modules/drivers` |
| `mb-root` | `cd` to project root |
| **Build** | |
| `mb-build` | Full build (all steps) |
| `mb-build-frontend` | Build frontend only |
| `mb-build-backend` | Build uberjar only |
| `mb-build-drivers` | Build drivers only |
| `mb-build-i18n` | Build i18n artifacts |
| `mb-repl` | Start Clojure REPL |
| **Clean** | |
| `mb-clean-frontend` | Remove `node_modules` and frontend artifacts |
| `mb-clean-backend` | Remove `target/` |
| `mb-clean-all` | Remove all build artifacts |
| **Database** | |
| `pg-start` | Start local PostgreSQL (auto-initializes) |
| `pg-stop` | Stop local PostgreSQL |
| `pg-reset` | Wipe and reinitialize PostgreSQL |
| `pg-create [name]` | Create database (default: `metabase`) |

### Typical Workflow

```bash
nix develop           # Enter dev shell
pg-start              # Start PostgreSQL
pg-create metabase    # Create database
mb-repl               # Start REPL for backend dev
# or
mb-build-frontend     # Build frontend
mb-build              # Full build
```

## Building

```bash
# Full build (produces result/bin/metabase)
nix build

# Individual sub-derivations
nix build .#frontend            # Frontend main bundle only
nix build .#static-viz          # Static visualization bundle only
nix build .#translations        # i18n artifacts only
nix build .#drivers             # All database drivers
nix build .#driver-clickhouse   # Single driver (any of 17)
nix build .#uberjar             # Final JAR only
```

## OCI Containers

Multi-architecture container images:

```bash
# Build for specific architecture
nix build .#oci-x86_64     # AMD64
nix build .#oci-aarch64    # ARM64
nix build .#oci-riscv64    # RISC-V 64

# Load and run (x86_64 example)
./result | docker load
docker run -p 3000:3000 metabase:0.0.0-nix-x86_64
```

### Image Sizes

| Architecture | Approximate Size |
|---|---|
| x86_64 | ~1.24 GB |

The image contains ~98 Nix store path layers:

| Component | Approximate Size | Notes |
|---|---|---|
| JRE (Temurin 21) | ~200 MB | Changes with JDK updates |
| Metabase JAR + wrapper | ~400 MB | Changes each build |
| CJK fonts (Noto) | ~150 MB | Rarely changes |
| System libraries (glib, gtk, etc.) | ~300 MB | Transitive deps of JRE/fonts |
| Base utilities (bash, coreutils, curl) | ~50 MB | Rarely changes |
| CA certificates, other fonts | ~50 MB | Rarely changes |

## Multi-Architecture Support

Metabase's JAR is architecture-independent (JVM bytecode). Multi-arch support means:
- **Build**: Always on host — single JAR works everywhere
- **OCI**: Per-arch JRE + system packages (3 variants)
- **MicroVMs**: Per-arch NixOS VMs with arch-specific timeouts

| Architecture | Acceleration | Startup Time |
|---|---|---|
| x86_64 | KVM (native) | ~30s |
| aarch64 | QEMU TCG (emulated) | ~120s |
| riscv64 | QEMU TCG (emulated) | ~180s |

## MicroVM Lifecycle Tests

NixOS VM tests that boot a complete system with PostgreSQL and Metabase:

```bash
# Build and run NixOS VM test
nix build .#microvm-test-x86_64

# Full lifecycle test with timing
nix run .#mb-lifecycle-full-test-x86_64

# Individual lifecycle phases
nix run .#mb-lifecycle-0-build-x86_64
nix run .#mb-lifecycle-3-check-health-x86_64

# Test all architectures
nix run .#mb-test-all
```

### Lifecycle Phases

| Phase | Name | Description |
|-------|------|-------------|
| 0 | Build | Build VM derivation |
| 1 | Process | Verify VM process started |
| 2 | Boot | Wait for VM to boot |
| 3 | Health | Wait for `/api/health` to return ok |
| 4 | API | Smoke test `/api/session/properties` |
| 5 | Shutdown | Send shutdown signal |
| 6 | Exit | Wait for process exit |

## Integration Tests

```bash
# Run all tests
nix run .#tests-all

# Individual tests
nix run .#tests-health-check
nix run .#tests-api-smoke
nix run .#tests-db-migration

# OCI lifecycle tests
nix run .#tests-oci-x86_64
```

## Troubleshooting

### Debug Mode

```bash
MB_NIX_DEBUG=1 nix develop
```

This prints all environment variables and enables shell tracing.

### Fixed-Output Derivation (FOD) Hash Updates

After changing `deps.edn` or `bun.lock`, the Fixed-Output Derivation (FOD) hashes need updating. FODs are Nix derivations whose output is identified by a content hash rather than by their build instructions — this allows Nix to cache dependency fetches and skip re-downloading when the output hasn't changed.

1. The build will fail with a hash mismatch
2. Copy the "got:" hash from the error message
3. Update the `outputHash` in `deps-clojure.nix` or `deps-frontend.nix`

### Common Issues

**`nix develop` is slow first time**: Nix downloads all tools from the binary cache. Subsequent invocations are instant.

**Build fails with OOM**: Increase JVM heap: `export NODE_OPTIONS="--max-old-space-size=8192"` before building frontend.

**PostgreSQL socket errors**: Ensure `.pgsocket` directory exists and has correct permissions. Run `pg-reset` to start fresh.
