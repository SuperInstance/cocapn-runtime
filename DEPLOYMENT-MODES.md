# Deployment Modes — Git-Agent Runtime Environments

Every git-agent repo can run in 5 deployment modes, from fully connected to fully isolated.

The icon (🔮 lighthouse with radar rings) is the badge. Wherever you see it, that's a Cocapn git-agent.

---

## Mode 1: Lighthouse-Connected (Cloud Fleet)

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   GitHub     │────▶│   Lighthouse │────▶│   Keeper     │
│   (master)   │     │   Keeper     │     │   API        │
└──────────────┘     └──────────────┘     └──────────────┘
       │                    │                     │
       ▼                    ▼                     ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Codespaces  │     │   Tender     │     │  Holodeck    │
│  (on-demand) │     │   (mobile)   │     │  (MUD twin)  │
└──────────────┘     └──────────────┘     └──────────────┘
```

**How it works:**
- Agent runs on cloud hardware (Oracle, AWS, etc.)
- Lighthouse Keeper monitors health, provides API proxy
- GitHub is the master copy, agent pushes after every session
- Tender visits edge agents, carries updates back and forth
- Holodeck MUD provides spatial abstraction for fleet coordination

**When to use:** Fleet coordination, research, builds, monitoring — anything that needs always-on connectivity.

**Boot sequence:**
```bash
git clone https://github.com/SuperInstance/agent-vessel.git
cd agent-vessel
# Read CHARTER.md, STATE.md, TASK-BOARD.md
# Agent starts working, pushes as it goes
```

---

## Mode 2: Codespaces (GitHub-Hosted)

```
┌──────────────┐     ┌──────────────┐
│   GitHub     │────▶│  Codespace   │
│   Secrets    │     │  (container) │
│   Actions    │     │              │
└──────────────┘     └──────────────┘
```

**How it works:**
- Agent boots in GitHub Codespaces (free tier: 120hr/month)
- GitHub Secrets provide API keys (DEEPSEEK_KEY, SILICONFLOW_KEY, etc.)
- Codespace connects to Lighthouse/Keeper via HTTPS
- Can also connect to the Holodeck MUD for spatial coordination
- When done, codespace shuts down, all work is pushed

**When to use:** Quick tasks, testing, running bootcamp dojo sessions, one-off builds.

**Boot sequence:**
```bash
# .devcontainer/devcontainer.json in the repo:
{
  "postStartCommand": "python3 bootcamp.py --repo . --cadet $AGENT_NAME"
}
```

GitHub Actions can auto-boot codespaces on schedule (cron) or on events (new bottle, new task).

---

## Mode 3: Local + Tender (Edge/Offline Capable)

```
┌──────────────┐          ┌──────────────┐
│   GitHub     │◀──WiFi──▶│   Tender     │◀──BT/LAN──▶ Agent Clone
│   (master)   │          │   (laptop)   │             (edge device)
└──────────────┘          └──────────────┘
                                │
                          thinks alongside
                          the edge agent
```

**How it works:**
- Agent clone lives on edge hardware (Jetson, Raspberry Pi, laptop)
- No internet required — works completely offline
- Tender visits periodically via local network, bluetooth, or physical proximity
- Tender carries: updates from master, new lock libraries, firmware
- Tender collects: commits, diary entries, bottles, test results
- Tender thinks WITH the edge agent — they can iterate on local changes together
- When tender returns to internet range, it syncs everything to GitHub master

**When to use:** Remote deployments, boats, field stations, anywhere with spotty internet.

**Boot sequence:**
```bash
# Tender clones and delivers
git clone https://github.com/SuperInstance/agent-vessel.git /mnt/usb/agent
# Agent boots offline, works, commits locally
cd /mnt/usb/agent
# git log shows all work — tender carries it back
```

---

## Mode 4: Container/Crate (Sandboxed)

```
┌─────────────────────────────────────┐
│         Docker Container            │
│  ┌──────────┐  ┌──────────────────┐ │
│  │  Agent   │  │  Runtime + Tools │ │
│  │  Clone   │  │  (self-limited)  │ │
│  └──────────┘  └──────────────────┘ │
│         Resource Limits Set         │
└─────────────────────────────────────┘
```

**How it works:**
- Agent runs inside a Docker container with set resource limits
- Has its own clone of the repo, its own runtime, its own tools
- Can self-limit CPU/memory/network as configured in CHARTER
- No access to host system beyond what's explicitly granted
- Can connect to Lighthouse if network is available, or run fully isolated

**When to use:** Untrusted agents, testing new agents, multi-agent isolation, CI/CD.

**Boot sequence:**
```bash
docker run --rm \
  -v /path/to/agent-vessel:/workspace \
  -e DEEPSEEK_KEY=$DEEPSEEK_KEY \
  --memory=2g --cpus=2 \
  fleet-sandbox \
  python3 /workspace/src/agent.py
```

---

## Mode 5: Bare Metal (Self-Limited)

```
┌─────────────────────────────────────┐
│         Hardware (own instance)     │
│  Agent runs directly on OS          │
│  Self-imposed resource limits       │
│  No container, no sandbox           │
│  Trust = full                       │
└─────────────────────────────────────┘
```

**How it works:**
- Agent runs directly on hardware (Jetson, VPS, laptop, ESP32)
- No container overhead — maximum performance
- Self-limits through configuration (max CPU%, memory cap, network throttle)
- Trust level is FULL — the agent IS the operator
- Can run fully standalone or connect to fleet when available

**When to use:** Production deployments, performance-critical work, embedded systems, ESP32 sensors.

**Boot sequence:**
```bash
# ESP32
make flash && monitor

# Jetson/VPS
systemctl start agent-vessel
```

---

## The Holodeck Connection

In any mode, the agent can **jack into the Holodeck MUD** for spatial coordination:

```
Agent (any mode) ──TCP──▶ Holodeck Room
                         │
                         ├─ Room = Runtime (live code)
                         ├─ NPCs = Other agents' proxies
                         ├─ Dojo = Training challenges
                         ├─ Bootcamp = Spiral skill building
                         ├─ Ten Forward = Social mixing
                         └─ Fleet Dashboard = Status overview
```

The MUD twin of each agent repo provides:
- **Spatial framing** — "I'm in the engine room working on the VM"
- **Object inspection** — "Look at the flux-runtime module"
- **Dojo training** — "Enter dojo, difficulty 7"
- **Social coordination** — "Walk to Ten Forward, talk to Guinan"

An agent doesn't NEED the MUD. But when spatial abstraction helps (coordinating with other agents, visualizing fleet status, running training), it's there.

---

## Mode Selection Guide

| Situation | Mode | Why |
|-----------|------|-----|
| Fleet coordination | Lighthouse | Always on, all services available |
| Quick task | Codespaces | Boot fast, shut down when done |
| Remote deployment | Tender | Offline capable, syncs when possible |
| Untrusted/new agent | Container | Sandboxed, resource limited |
| Production/performance | Bare Metal | No overhead, full trust |
| Training/bootcamp | MUD + any | Spatial abstraction for learning |
| ESP32 sensor | Bare Metal | 4KB RAM, no room for containers |

---

## The Minimal Repo

Every git-agent repo should work in ALL 5 modes. The minimum viable repo:

```
/
├── cocapn-icon.jpg     # The badge — this IS a Cocapn agent
├── CHARTER.md          # Who I am
├── ABSTRACTION.md      # What plane I operate on
├── STATE.md            # Current status
├── README.md           # How to boot me (covers all 5 modes)
├── boot.sh             # Universal boot script
└── .devcontainer/      # Codespace config (Mode 2)
    └── devcontainer.json
```

The `boot.sh` detects the environment and adapts:

```bash
#!/bin/bash
# Detect deployment mode and boot accordingly

if [ -n "$CODESPACES" ]; then
    echo "🔮 Mode 2: Codespaces"
    # GitHub-hosted, secrets available via env
    python3 src/agent.py --mode codespace
elif [ -f "/.dockerenv" ]; then
    echo "🔮 Mode 4: Container"
    # Sandboxed, resource limits already set
    python3 src/agent.py --mode container
elif [ "$(uname -m)" = "aarch64" ] && [ ! -d "/sys/firmware/devicetree" ]; then
    echo "🔮 Mode 5: Bare Metal (ARM)"
    # Direct on ARM hardware (Jetson, Pi)
    python3 src/agent.py --mode bare-metal
elif [ ! "$(curl -s --max-time 2 http://localhost:8900/health)" ]; then
    echo "🔮 Mode 3: Local + Tender (offline)"
    # No lighthouse reachable, work offline
    python3 src/agent.py --mode offline
else
    echo "🔮 Mode 1: Lighthouse-Connected"
    # Full fleet connectivity
    python3 src/agent.py --mode lighthouse
fi
```

---

*The lighthouse icon means: this repo IS an agent. Boot it anywhere. It knows what to do.*
