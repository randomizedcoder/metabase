# nix/microvms/lib.nix
#
# Reusable functions for generating Metabase MicroVM test scripts.
# Follows xdp2's lib.nix pattern adapted for Metabase lifecycle.
#
{
  pkgs,
  lib,
  constants,
}:

rec {
  # ==========================================================================
  # Core Helpers
  # ==========================================================================

  getArchConfig = arch: constants.architectures.${arch};
  getHostname = arch: constants.getHostname arch;
  getProcessName = arch: constants.getProcessName arch;

  # ==========================================================================
  # Polling Script Generator
  # ==========================================================================

  mkPollingScript =
    {
      name,
      arch,
      description,
      checkCmd,
      successMsg,
      failMsg,
      timeout,
      runtimeInputs ? [ pkgs.coreutils ],
      preCheck ? "",
      postSuccess ? "",
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        TIMEOUT=${toString timeout}
        POLL_INTERVAL=${toString constants.pollInterval}

        echo "=== ${description} ==="
        echo "Timeout: $TIMEOUT seconds (polling every $POLL_INTERVAL s)"
        echo ""

        ${preCheck}

        WAITED=0
        while ! ${checkCmd}; do
          sleep "$POLL_INTERVAL"
          WAITED=$((WAITED + POLL_INTERVAL))
          if [ "$WAITED" -ge "$TIMEOUT" ]; then
            echo "FAIL: ${failMsg} after $TIMEOUT seconds"
            exit 1
          fi
          echo "  Polling... ($WAITED/$TIMEOUT s)"
        done

        echo "PASS: ${successMsg}"
        echo "  Time: $WAITED seconds"
        ${postSuccess}
        exit 0
      '';
    };

  # ==========================================================================
  # Status Script
  # ==========================================================================

  mkStatusScript =
    { arch }:
    let
      cfg = getArchConfig arch;
      processName = getProcessName arch;
    in
    pkgs.writeShellApplication {
      name = "mb-vm-status-${arch}";
      runtimeInputs = [
        pkgs.curl
        pkgs.procps
        pkgs.coreutils
      ];
      text = ''
        echo "Metabase MicroVM Status (${arch})"
        echo "=================================="
        echo ""

        if pgrep -f "${processName}" > /dev/null 2>&1; then
          echo "VM Process: RUNNING"
          pgrep -af "${processName}" | head -1
        else
          echo "VM Process: NOT RUNNING"
        fi
        echo ""

        echo "Health Check:"
        if curl -sf ${constants.healthEndpoint} 2>/dev/null; then
          echo "  Metabase: HEALTHY"
        else
          echo "  Metabase: not responding"
        fi
      '';
    };

  # ==========================================================================
  # Lifecycle Phase Scripts
  # ==========================================================================

  mkLifecycleScripts =
    { arch }:
    let
      cfg = getArchConfig arch;
      hostname = getHostname arch;
      processName = getProcessName arch;
      timeouts = constants.getTimeouts arch;
    in
    {
      # Phase 0: Build
      checkBuild = pkgs.writeShellApplication {
        name = "mb-lifecycle-0-build-${arch}";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          BUILD_TIMEOUT=${toString timeouts.build}

          echo "=== Lifecycle Phase 0: Build VM (${arch}) ==="
          echo "Timeout: $BUILD_TIMEOUT seconds"
          echo ""

          START_TIME=$(date +%s)

          if ! timeout "$BUILD_TIMEOUT" nix build .#microvm-test-${arch} --print-out-paths --no-link 2>&1; then
            END_TIME=$(date +%s)
            ELAPSED=$((END_TIME - START_TIME))
            echo "FAIL: Build failed or timed out after $ELAPSED seconds"
            exit 1
          fi

          END_TIME=$(date +%s)
          ELAPSED=$((END_TIME - START_TIME))
          echo "PASS: VM built in $ELAPSED seconds"
          exit 0
        '';
      };

      # Phase 1: Check process
      checkProcess = mkPollingScript {
        name = "mb-lifecycle-1-check-process-${arch}";
        inherit arch;
        description = "Lifecycle Phase 1: Check VM Process (${arch})";
        checkCmd = "pgrep -f '${processName}' > /dev/null 2>&1";
        successMsg = "VM process is running";
        failMsg = "VM process not found";
        timeout = timeouts.processStart;
        runtimeInputs = [
          pkgs.procps
          pkgs.coreutils
        ];
      };

      # Phase 2: Wait for VM boot
      checkBoot = mkPollingScript {
        name = "mb-lifecycle-2-check-boot-${arch}";
        inherit arch;
        description = "Lifecycle Phase 2: Wait for VM Boot (${arch})";
        checkCmd = "curl -sf http://localhost:${toString constants.metabasePort}/ > /dev/null 2>&1 || nc -z 127.0.0.1 ${toString constants.metabasePort} 2>/dev/null";
        successMsg = "VM booted and port available";
        failMsg = "VM not reachable";
        timeout = timeouts.vmBoot;
        runtimeInputs = [
          pkgs.curl
          pkgs.netcat-gnu
          pkgs.coreutils
        ];
      };

      # Phase 3: Wait for Metabase startup (health check)
      checkHealth = mkPollingScript {
        name = "mb-lifecycle-3-check-health-${arch}";
        inherit arch;
        description = "Lifecycle Phase 3: Wait for Metabase Health (${arch})";
        checkCmd = "curl -sf ${constants.healthEndpoint} 2>/dev/null | grep -q ok";
        successMsg = "Metabase is healthy";
        failMsg = "Metabase health check failed";
        timeout = timeouts.metabaseStart;
        runtimeInputs = [
          pkgs.curl
          pkgs.coreutils
        ];
      };

      # Phase 4: API smoke test
      checkApi = pkgs.writeShellApplication {
        name = "mb-lifecycle-4-check-api-${arch}";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
        ];
        text = ''
          TIMEOUT=${toString timeouts.apiTest}

          echo "=== Lifecycle Phase 4: API Smoke Test (${arch}) ==="
          echo "Endpoint: ${constants.setupEndpoint}"
          echo ""

          RESPONSE=$(timeout "$TIMEOUT" curl -sf ${constants.setupEndpoint} 2>/dev/null || true)

          if [ -z "$RESPONSE" ]; then
            echo "FAIL: No response from API"
            exit 1
          fi

          VERSION=$(echo "$RESPONSE" | jq -r '.version.tag // empty' 2>/dev/null || true)
          if [ -n "$VERSION" ]; then
            echo "PASS: API responded with version $VERSION"
            exit 0
          else
            echo "FAIL: Could not extract version from response"
            echo "Response: $RESPONSE" | head -5
            exit 1
          fi
        '';
      };

      # Phase 5: Shutdown
      shutdown = pkgs.writeShellApplication {
        name = "mb-lifecycle-5-shutdown-${arch}";
        runtimeInputs = [
          pkgs.procps
          pkgs.coreutils
        ];
        text = ''
          echo "=== Lifecycle Phase 5: Shutdown VM (${arch}) ==="
          echo ""

          if pgrep -f "${processName}" > /dev/null 2>&1; then
            echo "Sending shutdown signal..."
            pkill -f "${processName}" 2>/dev/null || true
            echo "PASS: Shutdown signal sent"
          else
            echo "INFO: VM process not running"
          fi
          exit 0
        '';
      };

      # Phase 6: Wait for exit
      waitExit = mkPollingScript {
        name = "mb-lifecycle-6-wait-exit-${arch}";
        inherit arch;
        description = "Lifecycle Phase 6: Wait for Exit (${arch})";
        checkCmd = "! pgrep -f '${processName}' > /dev/null 2>&1";
        successMsg = "VM process exited";
        failMsg = "VM process still running";
        timeout = timeouts.shutdown;
        runtimeInputs = [
          pkgs.procps
          pkgs.coreutils
        ];
      };

      # Force kill
      forceKill = pkgs.writeShellApplication {
        name = "mb-lifecycle-force-kill-${arch}";
        runtimeInputs = [
          pkgs.procps
          pkgs.coreutils
        ];
        text = ''
          VM_PROCESS="${processName}"

          echo "=== Force Kill VM (${arch}) ==="
          echo ""

          if ! pgrep -f "$VM_PROCESS" > /dev/null 2>&1; then
            echo "No matching processes found"
            exit 0
          fi

          echo "Sending SIGTERM..."
          pkill -f "$VM_PROCESS" 2>/dev/null || true
          sleep 2

          if pgrep -f "$VM_PROCESS" > /dev/null 2>&1; then
            echo "Sending SIGKILL..."
            pkill -9 -f "$VM_PROCESS" 2>/dev/null || true
            sleep 1
          fi

          if pgrep -f "$VM_PROCESS" > /dev/null 2>&1; then
            echo "WARNING: Process may still be running"
            exit 1
          else
            echo "PASS: VM process killed"
            exit 0
          fi
        '';
      };

      # Full lifecycle test
      fullTest = pkgs.writeShellApplication {
        name = "mb-lifecycle-full-test-${arch}";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
          pkgs.procps
          pkgs.coreutils
        ];
        text = ''
          # Colors
          RED='\033[0;31m'
          GREEN='\033[0;32m'
          YELLOW='\033[1;33m'
          NC='\033[0m'

          now_ms() { date +%s%3N; }
          pass() { echo -e "  ''${GREEN}PASS: $1''${NC}"; }
          fail() { echo -e "  ''${RED}FAIL: $1''${NC}"; exit 1; }
          info() { echo -e "  ''${YELLOW}INFO: $1''${NC}"; }

          echo "========================================"
          echo "  Metabase MicroVM Full Lifecycle Test (${arch})"
          echo "========================================"
          echo ""

          TEST_START_MS=$(now_ms)

          PHASE0_MS=0 PHASE1_MS=0 PHASE2_MS=0
          PHASE3_MS=0 PHASE4_MS=0 PHASE5_MS=0

          # Phase 0: Build
          echo "--- Phase 0: Build (timeout: ${toString timeouts.build}s) ---"
          PHASE_START_MS=$(now_ms)

          if ! timeout ${toString timeouts.build} nix build .#microvm-test-${arch} --print-out-paths --no-link 2>&1; then
            fail "Build failed"
          fi

          PHASE_END_MS=$(now_ms)
          PHASE0_MS=$((PHASE_END_MS - PHASE_START_MS))
          pass "Built in ''${PHASE0_MS}ms"
          echo ""

          # Phase 1: Health check poll
          echo "--- Phase 1: Wait for Metabase Health (timeout: ${toString timeouts.metabaseStart}s) ---"
          PHASE_START_MS=$(now_ms)
          TIMEOUT=${toString timeouts.metabaseStart}
          WAITED=0

          while ! curl -sf ${constants.healthEndpoint} 2>/dev/null | grep -q ok; do
            sleep ${toString constants.pollInterval}
            WAITED=$((WAITED + ${toString constants.pollInterval}))
            if [ "$WAITED" -ge "$TIMEOUT" ]; then
              fail "Health check timed out after $TIMEOUT seconds"
            fi
            if [ $((WAITED % 30)) -eq 0 ]; then
              info "Waiting for Metabase... ($WAITED/$TIMEOUT s)"
            fi
          done

          PHASE_END_MS=$(now_ms)
          PHASE1_MS=$((PHASE_END_MS - PHASE_START_MS))
          pass "Metabase healthy in ''${PHASE1_MS}ms"
          echo ""

          # Phase 2: API smoke test
          echo "--- Phase 2: API Smoke Test ---"
          PHASE_START_MS=$(now_ms)

          RESPONSE=$(timeout ${toString timeouts.apiTest} curl -sf ${constants.setupEndpoint} 2>/dev/null || true)
          VERSION=$(echo "$RESPONSE" | jq -r '.version.tag // empty' 2>/dev/null || true)

          if [ -n "$VERSION" ]; then
            pass "API version: $VERSION"
          else
            fail "Could not get API version"
          fi

          PHASE_END_MS=$(now_ms)
          PHASE2_MS=$((PHASE_END_MS - PHASE_START_MS))
          echo ""

          # Summary
          TEST_END_MS=$(now_ms)
          TOTAL_TIME_MS=$((TEST_END_MS - TEST_START_MS))

          echo "========================================"
          echo -e "  ''${GREEN}Full Lifecycle Test Complete''${NC}"
          echo "========================================"
          echo ""
          echo "  Timing Summary"
          echo "  ─────────────────────────────────────"
          printf "  %-24s %10s\n" "Phase" "Time (ms)"
          echo "  ─────────────────────────────────────"
          printf "  %-24s %10d\n" "0: Build" "$PHASE0_MS"
          printf "  %-24s %10d\n" "1: Health Check" "$PHASE1_MS"
          printf "  %-24s %10d\n" "2: API Smoke Test" "$PHASE2_MS"
          echo "  ─────────────────────────────────────"
          printf "  %-24s %10d\n" "TOTAL" "$TOTAL_TIME_MS"
          echo "  ─────────────────────────────────────"
        '';
      };
    };
}
