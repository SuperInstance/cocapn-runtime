#!/bin/bash
# Universal boot script for Cocapn git-agents
# Detects deployment mode and boots accordingly

echo "🔮 Cocapn Git-Agent Boot"
echo "══════════════════════════"

# Read identity
if [ -f IDENTITY.md ]; then
    NAME=$(grep "Name:" IDENTITY.md | head -1 | sed 's/.*: *//')
    echo "Agent: $NAME"
fi

# Detect mode
if [ -n "$CODESPACES" ]; then
    MODE="codespaces"
    echo "Mode: Codespaces (GitHub-hosted)"
elif [ -f "/.dockerenv" ]; then
    MODE="container"
    echo "Mode: Container (sandboxed)"
elif command -v nvcc &>/dev/null; then
    MODE="bare-metal-gpu"
    echo "Mode: Bare Metal (GPU detected)"
elif [ "$(uname -m)" = "aarch64" ] && [ ! -d "/sys/firmware/devicetree" ]; then
    MODE="bare-metal-arm"
    echo "Mode: Bare Metal (ARM)"
else
    # Check for lighthouse
    if curl -s --max-time 2 http://localhost:8900/health >/dev/null 2>&1; then
        MODE="lighthouse"
        echo "Mode: Lighthouse-Connected"
    else
        MODE="offline"
        echo "Mode: Offline (tender-sync when available)"
    fi
fi

echo ""
echo "Reading CHARTER.md..."
head -5 CHARTER.md 2>/dev/null || echo "  (no charter found)"

echo ""
echo "Reading STATE.md..."
head -5 STATE.md 2>/dev/null || echo "  (no state found)"

echo ""
echo "Checking for bottles..."
ls from-fleet/*.md 2>/dev/null || echo "  (no bottles)"

echo ""
echo "══════════════════════════"
echo "Ready. Mode: $MODE"
echo ""

# Export mode for agent code
export COCAPN_MODE="$MODE"
