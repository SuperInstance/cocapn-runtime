#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# boot.sh — Universal boot script for cocapn-runtime × ternary-room
#
# Detects deployment environment and loads the correct ternary-room
# implementation via construct-core's layered trait system.
#
# Modes:
#   ESP32 bare metal  → BareRoom (Layer 0, no_std, compiled policy)
#   Jetson/Pi edge    → EdgeRoom (Layer 1, sync + alloc)
#   Codespace         → CodespaceRoom (Layer 2, async, PLATO sync)
#   Docker container  → SandboxRoom (Layer 2, resource-limited)
#   Offline/edge      → EdgeRoom + Tender sync queue
#   Lighthouse/cloud  → CodespaceRoom (Layer 2, always-on fleet)
#
# Usage:
#   ./boot.sh                    # Auto-detect and boot
#   ./boot.sh --mode codespace   # Force specific mode
#   ./boot.sh --dry-run          # Print detection results without booting
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
TERNARY_BIN="${TERNARY_BIN:-/usr/local/bin/ternary-agent}"
TERNARY_CONFIG="${TERNARY_CONFIG:-/etc/ternary/config.toml}"
LOG_TAG="ternary-boot"
MAX_IDLE_TICKS="${MAX_IDLE_TICKS:-300}"      # 5 min auto-suspend for ephemeral
LIGHTHOUSE_URL="${LIGHTHOUSE_URL:-http://localhost:8900}"
PLATO_ENDPOINT="${PLATO_ENDPOINT:-}"
HOLODECK_HOST="${HOLODECK_HOST:-}"
KEEPER_URL="${KEEPER_URL:-}"

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Logging ────────────────────────────────────────────────────────────────────
log()   { echo -e "${CYAN}[${LOG_TAG}]${NC} $*"; }
warn()  { echo -e "${YELLOW}[${LOG_TAG}]${NC} WARN: $*" >&2; }
error() { echo -e "${RED}[${LOG_TAG}]${NC} ERROR: $*" >&2; }

# ── Parse Arguments ────────────────────────────────────────────────────────────
FORCE_MODE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            FORCE_MODE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            head -25 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ═══════════════════════════════════════════════════════════════════════════════
# DETECTION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

is_esp32() {
    # ESP32 runs Xtensa architecture
    local arch
    arch="$(uname -m 2>/dev/null || echo unknown)"
    [ "$arch" = "xtensa" ] && return 0

    # Alternative: check for ESP-IDF environment
    [ -n "${IDF_PATH:-}" ] && [ -f "${IDF_PATH}/tools/idf.py" ] && return 0

    # Check for ESP32 device tree
    [ -f "/dev/ttyUSB0" ] && [ -f "/sys/class/tty/ttyUSB0/device/uevent" ] && return 0

    return 1
}

is_jetson() {
    # NVIDIA Jetson has this file
    [ -f "/etc/nv_tegra_release" ] && return 0

    # Check for CUDA on ARM64
    local arch
    arch="$(uname -m 2>/dev/null || echo unknown)"
    [ "$arch" = "aarch64" ] && [ -f "/usr/local/cuda/bin/nvcc" ] && return 0

    return 1
}

is_raspberry_pi() {
    # Raspberry Pi has this file or device tree model
    [ -f "/proc/device-tree/model" ] && grep -qi "raspberry" /proc/device-tree/model 2>/dev/null && return 0
    [ -f "/etc/rpi-issue" ] && return 0
    return 1
}

is_codespace() {
    # GitHub Codespaces sets this environment variable
    [ -n "${CODESPACES:-}" ] && return 0
    return 1
}

is_container() {
    # Docker creates this file
    [ -f "/.dockerenv" ] && return 0

    # Check cgroup for container indicators
    if [ -f /proc/1/cgroup ]; then
        grep -qE '(docker|kubepods|containerd)' /proc/1/cgroup 2>/dev/null && return 0
    fi

    # Check for Kubernetes
    [ -n "${KUBERNETES_SERVICE_HOST:-}" ] && return 0

    return 1
}

is_arm64_linux() {
    local arch os
    arch="$(uname -m 2>/dev/null || echo unknown)"
    os="$(uname -s 2>/dev/null || echo unknown)"
    [ "$arch" = "aarch64" ] && [ "$os" = "Linux" ] && return 0
    [ "$arch" = "armv7l" ] && [ "$os" = "Linux" ] && return 0
    return 1
}

has_network() {
    # Check if lighthouse keeper is reachable
    curl -sf --max-time 3 "${LIGHTHOUSE_URL}/health" >/dev/null 2>&1
}

get_mem_mb() {
    if [ -f /proc/meminfo ]; then
        awk '/MemTotal/ { printf "%.0f", $2/1024 }' /proc/meminfo
    else
        echo "unknown"
    fi
}

get_cpu_count() {
    nproc 2>/dev/null || echo "unknown"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MODE DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

detect_mode() {
    # Forced mode takes priority
    if [ -n "$FORCE_MODE" ]; then
        echo "$FORCE_MODE"
        return
    fi

    # Detection priority:
    # 1. ESP32 bare metal
    # 2. Codespace
    # 3. Container
    # 4. Jetson/Pi (with network check for lighthouse vs tender)
    # 5. x86_64 (lighthouse or offline)

    if is_esp32; then
        echo "bare-metal-esp32"
        return
    fi

    if is_codespace; then
        echo "codespace"
        return
    fi

    if is_container; then
        echo "container"
        return
    fi

    if is_jetson; then
        if has_network; then
            echo "edge-lighthouse"
        else
            echo "edge-tender"
        fi
        return
    fi

    if is_raspberry_pi || is_arm64_linux; then
        if has_network; then
            echo "edge-lighthouse"
        else
            echo "edge-tender"
        fi
        return
    fi

    # x86_64 with lighthouse = Mode 1, without = Mode 3 (offline)
    if has_network; then
        echo "lighthouse"
    else
        echo "offline"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ROOM BOOT FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

boot_bare_metal_esp32() {
    log "🔮 Mode 5: Bare Metal (ESP32)"
    log "   Layer 0: BareMetalConstruct (no_std, no alloc)"
    log "   Room type: BareRoom (compiled policy, 279 bytes)"
    log "   Hardware: $(uname -m), $(get_mem_mb) MB RAM"

    if [ "$DRY_RUN" = true ]; then return; fi

    # ESP32 is flashed at compile time — boot.sh just monitors
    log "   ESP32 firmware runs at flash time. Monitoring via UART..."

    if [ -f "/dev/ttyUSB0" ]; then
        log "   Connecting to ESP32 on /dev/ttyUSB0..."
        if command -v idf.py >/dev/null 2>&1; then
            idf.py -p /dev/ttyUSB0 monitor
        else
            picocom /dev/ttyUSB0 -b 115200
        fi
    else
        error "No ESP32 detected on /dev/ttyUSB0"
        error "Flash firmware first: make flash"
        exit 1
    fi
}

boot_codespace() {
    local codespace_name="${CODESPACES:-unknown}"
    log "🔮 Mode 2: Codespaces (GitHub-Hosted)"
    log "   Layer 2: AsyncConstruct (std + async)"
    log "   Room type: CodespaceRoom (ephemeral, PLATO proxy)"
    log "   Codespace: $codespace_name"
    log "   Hardware: $(uname -m), $(get_cpu_count) CPUs, $(get_mem_mb) MB RAM"

    if [ "$DRY_RUN" = true ]; then return; fi

    # Read CHARTER.md for room configuration
    local room_name="codespace"
    if [ -f CHARTER.md ]; then
        room_name="$(grep -m1 '^## Mission' CHARTER.md 2>/dev/null | head -1 | sed 's/## Mission//' | xargs || echo 'codespace')"
        log "   Charter: $room_name"
    fi

    # Boot the ternary agent in Codespace mode
    log "   Starting ternary-agent (codespace, ephemeral)..."

    TERNARY_MODE=codespace \
    TERNARY_TIER=codespace \
    TERNARY_BACKEND=dgx \
    TERNARY_LAYER=layer2 \
    TERNARY_PLATO="${PLATO_ENDPOINT}" \
    TERNARY_HOLODECK="${HOLODECK_HOST}" \
    TERNARY_MAX_IDLE="${MAX_IDLE_TICKS}" \
    TERNARY_ROOM_NAME="${room_name}" \
    "$TERNARY_BIN" \
        --mode codespace \
        --features std \
        --config "$TERNARY_CONFIG"
}

boot_container() {
    log "🔮 Mode 4: Container (Sandboxed)"
    log "   Layer 2: AsyncConstruct (std + async, resource-limited)"
    log "   Room type: SandboxRoom (resource-capped)"
    log "   Hardware: $(uname -m), $(get_cpu_count) CPUs, $(get_mem_mb) MB RAM"

    # Detect resource limits from cgroups
    local mem_limit cpu_limit
    if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        mem_limit="$(awk '{ printf "%.0f", $1/1048576 }' /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    elif [ -f /sys/fs/cgroup/memory.max ]; then
        mem_limit="$(awk '{ printf "%.0f", $1/1048576 }' /sys/fs/cgroup/memory.max)"
    else
        mem_limit="$(get_mem_mb)"
    fi

    if [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        local quota period
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 100000)"
        if [ "$quota" != "-1" ]; then
            cpu_limit=$(( quota * 100 / period ))
        else
            cpu_limit="100"
        fi
    else
        cpu_limit="100"
    fi

    log "   Container limits: ${mem_limit} MB RAM, ${cpu_limit}% CPU"

    if [ "$DRY_RUN" = true ]; then return; fi

    TERNARY_MODE=container \
    TERNARY_TIER=sandbox \
    TERNARY_BACKEND=dgx \
    TERNARY_LAYER=layer2 \
    TERNARY_MEMORY_LIMIT="${mem_limit}" \
    TERNARY_CPU_LIMIT="${cpu_limit}" \
    TERNARY_ROOM_NAME="sandbox-$(hostname)" \
    "$TERNARY_BIN" \
        --mode container \
        --features std \
        --config "$TERNARY_CONFIG"
}

boot_edge_lighthouse() {
    local device_type="edge"
    if is_jetson; then device_type="jetson"; fi
    if is_raspberry_pi; then device_type="pi"; fi

    log "🔮 Mode 1/5: Edge + Lighthouse (connected)"
    log "   Layer 1: SyncConstruct (alloc, no async)"
    log "   Room type: EdgeRoom (always-on, connected)"
    log "   Device: ${device_type} ($(uname -m))"
    log "   Hardware: $(get_cpu_count) CPUs, $(get_mem_mb) MB RAM"
    log "   Lighthouse: ${LIGHTHOUSE_URL} ✓"

    if [ "$DRY_RUN" = true ]; then return; fi

    local gpu_flag=""
    if is_jetson; then
        gpu_flag="--gpu orin-nano --cuda-cores 1024"
        log "   GPU: NVIDIA Orin Nano (1024 CUDA cores)"
    fi

    TERNARY_MODE=lighthouse \
    TERNARY_TIER=edge \
    TERNARY_BACKEND="${device_type}" \
    TERNARY_LAYER=layer1 \
    TERNARY_KEEPER="${KEEPER_URL}" \
    TERNARY_PLATO="${PLATO_ENDPOINT}" \
    TERNARY_HOLODECK="${HOLODECK_HOST}" \
    TERNARY_ROOM_NAME="${device_type}-$(hostname)" \
    "$TERNARY_BIN" \
        --mode lighthouse \
        --features alloc \
        $gpu_flag \
        --config "$TERNARY_CONFIG"
}

boot_edge_tender() {
    local device_type="edge"
    if is_jetson; then device_type="jetson"; fi
    if is_raspberry_pi; then device_type="pi"; fi

    log "🔮 Mode 3/5: Edge + Tender (offline)"
    log "   Layer 1: SyncConstruct (alloc, no async)"
    log "   Room type: EdgeRoom (offline, tender sync queue)"
    log "   Device: ${device_type} ($(uname -m))"
    log "   Hardware: $(get_cpu_count) CPUs, $(get_mem_mb) MB RAM"
    log "   Network: offline (tender will sync)"

    # Check for local model availability
    local local_model="none"
    for model in liquid-350m liquid-1.2b phi4-mini; do
        if [ -d "/opt/models/${model}" ] || [ -f "/usr/share/models/${model}.gguf" ]; then
            local_model="$model"
            log "   Local model: ${model} ✓"
            break
        fi
    done

    if [ "$local_model" = "none" ]; then
        warn "No local model found. Install one in /opt/models/ for offline inference."
    fi

    if [ "$DRY_RUN" = true ]; then return; fi

    TERNARY_MODE=tender \
    TERNARY_TIER=edge \
    TERNARY_BACKEND="${device_type}" \
    TERNARY_LAYER=layer1 \
    TERNARY_SYNC=tender \
    TERNARY_OFFLINE=true \
    TERNARY_LOCAL_MODEL="${local_model}" \
    TERNARY_ROOM_NAME="${device_type}-$(hostname)" \
    "$TERNARY_BIN" \
        --mode tender \
        --features alloc \
        --offline \
        --config "$TERNARY_CONFIG"
}

boot_lighthouse() {
    log "🔮 Mode 1: Lighthouse-Connected (Cloud Fleet)"
    log "   Layer 2: AsyncConstruct (std + async)"
    log "   Room type: CodespaceRoom (always-on, fleet coordination)"
    log "   Hardware: $(uname -m), $(get_cpu_count) CPUs, $(get_mem_mb) MB RAM"
    log "   Lighthouse: ${LIGHTHOUSE_URL} ✓"

    if [ "$DRY_RUN" = true ]; then return; fi

    TERNARY_MODE=lighthouse \
    TERNARY_TIER=codespace \
    TERNARY_BACKEND=dgx \
    TERNARY_LAYER=layer2 \
    TERNARY_KEEPER="${KEEPER_URL}" \
    TERNARY_PLATO="${PLATO_ENDPOINT}" \
    TERNARY_HOLODECK="${HOLODECK_HOST}" \
    TERNARY_ROOM_NAME="lighthouse-$(hostname)" \
    "$TERNARY_BIN" \
        --mode lighthouse \
        --features std \
        --config "$TERNARY_CONFIG"
}

boot_offline() {
    log "🔮 Mode 3: Offline (No network, no tender)"
    log "   Layer 2: AsyncConstruct (local only)"
    log "   Room type: EdgeRoom (isolated)"
    log "   Hardware: $(uname -m), $(get_cpu_count) CPUs, $(get_mem_mb) MB RAM"
    log "   Network: offline"

    if [ "$DRY_RUN" = true ]; then return; fi

    TERNARY_MODE=offline \
    TERNARY_TIER=codespace \
    TERNARY_BACKEND=dgx \
    TERNARY_LAYER=layer2 \
    TERNARY_OFFLINE=true \
    TERNARY_ROOM_NAME="offline-$(hostname)" \
    "$TERNARY_BIN" \
        --mode offline \
        --features std \
        --offline \
        --config "$TERNARY_CONFIG"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  🔮 cocapn-runtime × ternary-room universal boot${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Print system info
    log "System: $(uname -s) $(uname -r) $(uname -m)"
    log "Memory: $(get_mem_mb) MB"
    log "CPUs: $(get_cpu_count)"
    echo ""

    # Detect mode
    MODE=$(detect_mode)
    log "Detected mode: ${GREEN}${MODE}${NC}"
    echo ""

    # Boot the appropriate room
    case "$MODE" in
        bare-metal-esp32)
            boot_bare_metal_esp32
            ;;
        codespace)
            boot_codespace
            ;;
        container)
            boot_container
            ;;
        edge-lighthouse)
            boot_edge_lighthouse
            ;;
        edge-tender)
            boot_edge_tender
            ;;
        lighthouse)
            boot_lighthouse
            ;;
        offline)
            boot_offline
            ;;
        *)
            error "Unknown mode: ${MODE}"
            error "Valid modes: bare-metal-esp32, codespace, container, edge-lighthouse, edge-tender, lighthouse, offline"
            exit 1
            ;;
    esac
}

main "$@"
