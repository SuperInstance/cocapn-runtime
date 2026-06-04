# Room Trait Mapping — cocapn-runtime ↔ ternary-room

*Exact mapping of cocapn-runtime concepts to ternary-room types, doors, and coordinator operations.*

---

## 1. Concept Mapping Table

| cocapn-runtime Concept | ternary-room Type | Notes |
|---|---|---|
| Agent vessel repo | `Room { id, name, agents, environment }` | Each vessel IS a room |
| Codespace instance | `Room { env("tier", "codespace") }` | Created by `RoomBuilder` |
| Jetson/Pi device | `Room { env("tier", "edge") }` | Always-on, Layer 1 |
| ESP32 sensor | `Room { env("tier", "bare") }` | No heap, compiled policy |
| Docker container | `Room { env("tier", "sandbox") }` | Resource-limited |
| Lighthouse Keeper | `RoomCoordinator` with fleet-wide scope | The coordinator IS the keeper |
| Tender | Agent (u64) that `transfer()`s between rooms | Carries messages via room env |
| Holodeck MUD | `RoomCoordinator` + `HolodeckRoom` wrappers | Spatial overlay |
| Fleet | All rooms in a `RoomCoordinator` | The coordinator IS the fleet |
| I2I message | `RoomEvent { kind, detail }` | Event log = I2I history |
| Bottle | `Room::set_env("bottle_{}", payload)` | Bottles stored in room env |
| Beachcomb | `Room::receive()` poll loop | Check for new messages |
| CHARTER.md | `Room::environment` map | Room config IS the charter |
| STATE.md | `RoomState` snapshot | Snapshot = state file |
| Git commit | `RoomHistory::record()` | History = git log |
| Boot mode | `Room::get_env("mode")` | Environment determines mode |

---

## 2. Door Access Mapping

| cocapn-runtime Concept | DoorAccess | Example |
|---|---|---|
| Public fleet channel | `DoorAccess::Open` | Any agent can enter/leave |
| Org boundary (SuperInstance ↔ Lucineer) | `DoorAccess::OneWay(src, dst)` | Fork-PR pattern: code flows one way |
| Sandboxed agent | `DoorAccess::Locked` | Cannot leave sandbox |
| Tender delivery | `DoorAccess::OneWay(tender, edge)` | Tender delivers, edge cannot push back directly |
| PLATO tile sync | `DoorAccess::OneWay(plato, room)` | Tiles flow from PLATO to room |
| Training dojo | `DoorAccess::OneWay(entry, dojo)` | Must complete challenge to exit |
| Captain-only room | `DoorAccess::Locked` | Only capitaine agents can enter |

---

## 3. Room Environment Variables

Every room uses the `environment` HashMap for configuration. Here's the canonical key set:

```rust
// Standard environment keys for all rooms
pub mod env_keys {
    // Identity
    pub const MODE: &str = "mode";           // "lighthouse" | "codespace" | "tender" | "container" | "bare-metal"
    pub const TIER: &str = "tier";           // "codespace" | "edge" | "bare" | "sandbox"
    pub const BACKEND: &str = "backend";     // "dgx" | "pi" | "esp" | "wasm"

    // Fleet connection
    pub const PLATO_ENDPOINT: &str = "plato_endpoint";
    pub const KEEPER_URL: &str = "keeper_url";
    pub const HOLODECK_HOST: &str = "holodeck_host";

    // Codespace-specific
    pub const CODESPACE_ID: &str = "codespace_id";
    pub const TEMPLATE_REPO: &str = "template_repo";
    pub const MACHINE_TYPE: &str = "machine_type";

    // Edge-specific
    pub const TENDER_BT: &str = "tender_bt";
    pub const OFFLINE: &str = "offline";
    pub const LOCAL_MODEL: &str = "local_model";

    // Container-specific
    pub const MEMORY_LIMIT: &str = "memory_limit";
    pub const CPU_LIMIT: &str = "cpu_limit";
    pub const NETWORK_LIMIT: &str = "network_limit";

    // Bare metal-specific
    pub const GPU: &str = "gpu";
    pub const CUDA_CORES: &str = "cuda_cores";

    // Tender sync
    pub const SYNC_MODE: &str = "sync";      // "tender" | "direct" | "offline"
    pub const LAST_SYNC: &str = "last_sync";
}
```

---

## 4. RoomCoordinator as Fleet Topology

The `RoomCoordinator` IS the fleet topology. Adding rooms and doors builds the fleet graph:

```rust
fn build_fleet_coordinator() -> RoomCoordinator {
    let mut coord = RoomCoordinator::new();

    // Mode 1: Lighthouse rooms (always-on cloud)
    let lighthouse = RoomBuilder::new(1, "lighthouse-oracle1")
        .env("mode", "lighthouse")
        .env("tier", "codespace")
        .env("backend", "dgx")
        .agent(1001)  // Capitaine agent
        .build();
    coord.add_room(lighthouse);

    // Mode 2: Ephemeral codespace
    let codespace = RoomBuilder::new(2, "codespace-dojo")
        .env("mode", "codespace")
        .env("tier", "codespace")
        .build();
    coord.add_room(codespace);

    // Mode 3: Edge room (tender sync)
    let edge_jetson = RoomBuilder::new(3, "jetson-claw1")
        .env("mode", "tender")
        .env("tier", "edge")
        .env("backend", "pi")
        .env("tender_bt", "AA:BB:CC:DD:EE:FF")
        .env("offline", "true")
        .agent(2001)  // Sentinelle agent
        .build();
    coord.add_room(edge_jetson);

    // Mode 4: Sandbox
    let sandbox = RoomBuilder::new(4, "sandbox-test")
        .env("mode", "container")
        .env("tier", "sandbox")
        .env("memory_limit", "2048")
        .build();
    coord.add_room(sandbox);

    // Mode 5: Bare metal
    let bare_esp32 = RoomBuilder::new(5, "esp32-sensor-bay")
        .env("mode", "bare-metal")
        .env("tier", "bare")
        .env("backend", "esp")
        .build();
    coord.add_room(bare_esp32);

    // Fleet topology via doors
    // Lighthouse ↔ Codespace (open — both cloud)
    coord.add_door(Door::new(1, 1, 2, DoorAccess::Open));
    // Lighthouse → Edge (one-way sync: tiles flow out, tender carries back)
    coord.add_door(Door::new(2, 1, 3, DoorAccess::OneWay(1, 3)));
    // Lighthouse → Sandbox (one-way: can send tasks, sandbox can't reach fleet)
    coord.add_door(Door::new(3, 1, 4, DoorAccess::OneWay(1, 4)));
    // Edge ← → Bare (one-way: edge manages ESP32)
    coord.add_door(Door::new(4, 3, 5, DoorAccess::OneWay(3, 5)));

    coord
}
```

---

## 5. Event Kind Mapping

| I2I Message Type | RoomEvent Kind | Ternary Signal |
|---|---|---|
| TELL | `"tell"` | +1 Signal |
| ASK | `"ask"` | +1 Signal |
| ALERT | `"alert"` | -1 Suppress |
| WARN | `"warn"` | -1 Suppress |
| HEARTBEAT | `"heartbeat"` | 0 Silence |
| COMPLETE | `"complete"` | +1 Signal |
| CHALLENGE | `"challenge"` | -1 Suppress |
| BOTTLE | `"bottle"` | +1 Signal |
| TASK | `"task"` | +1 Signal |
| CAPABILITY | `"capability"` | 0 Silence |
| REVIEW | `"review"` | 0 Silence |
| FORK | `"fork"` | +1 Signal |
| MERGE | `"merge"` | +1 Signal |
| DEPLOY | `"deploy"` | +1 Signal |
| ERROR | `"error"` | -1 Suppress |

---

*Written 2026-06-04 by synthesis-cocapn-fleet subagent.*
