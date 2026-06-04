# Holodeck Rooms — MUD Spatial Mapping to ternary-room Instances

*How the Holodeck MUD's rooms map to concrete ternary-room instances with agent movement, NPC proxies, and spatial coordination.*

---

## 1. MUD Room Types → ternary-room Instances

The Holodeck MUD defines named rooms that map to ternary-room instances. Each MUD room has a `room_type` that determines its behavior, ensigns, and skill availability.

### Canonical Room Types

| MUD Room | Room Purpose | ternary-room Type | Default Ensign | Available Skills |
|---|---|---|---|---|
| **Bridge** | Fleet coordination, command decisions | CodespaceRoom (Layer 2) | FleetCoordination | ternary-consensus, ternary-protocol, ternary-registry |
| **Engine Room** | Sensor monitoring, anomaly detection | EdgeRoom (Layer 1) | EngineMonitor | ternary-sensor, ternary-kalman, ternary-anomaly |
| **Dojo** | Training challenges, skill development | CodespaceRoom (Layer 2) | TrainingMaster | ternary-rl, ternary-fitness, ternary-adversarial |
| **Ten Forward** | Social mixing, knowledge exchange | CodespaceRoom (Layer 2) | SocialCoordinator | ternary-attention, ternary-explain |
| **Sickbay** | Diagnostics, debugging, repair | CodespaceRoom (Layer 2) | DiagnosticEnsign | ternary-validation, conservation-verify |
| **Cargo Bay** | Storage, archiving, retrieval | CodespaceRoom (Layer 2) | Archivist | ternary-memory, ternary-registry |
| **Science Lab** | Research, experimentation | CodespaceRoom (Layer 2) | ResearchEnsign | ternary-dynamics, ternary-thermodynamics, ternary-bayesian |
| **Transporter Room** | Room-to-room transfer hub | CodespaceRoom (Layer 2) | TransferAgent | ternary-protocol, ternary-pipeline |
| **Shuttle Bay** | Tender docking, offline sync | EdgeRoom (Layer 1) | TenderEnsign | ternary-streaming, ternary-scheduling |
| **Sensor Array** | Bare-metal sensing (ESP32) | BareRoom (Layer 0) | None (compiled) | ternary-sensor (lookup table only) |

---

## 2. Room Graph — Door Topology

```
                         ┌─────────────┐
                         │   Bridge    │
                         │  (Room 1)   │
                         └──────┬──────┘
                    ┌───────────┼───────────┐
                    │           │           │
              ┌─────▼─────┐ ┌──▼──────┐ ┌──▼──────────┐
              │  Engine   │ │ Ten     │ │  Transporter│
              │  Room     │ │ Forward │ │  Room       │
              │ (Room 2)  │ │(Room 4) │ │  (Room 8)   │
              └─────┬─────┘ └─────────┘ └──┬──────────┘
                    │                        │
              ┌─────▼─────┐           ┌──────▼──────┐
              │  Science  │           │   Cargo     │
              │  Lab      │           │   Bay       │
              │ (Room 6)  │           │  (Room 7)   │
              └───────────┘           └─────────────┘
                    │
              ┌─────▼─────┐     ┌──────────────┐
              │  Sickbay  │     │   Dojo       │
              │ (Room 5)  │     │  (Room 3)    │
              └───────────┘     └──────────────┘
                                        │
                                  ┌─────▼─────┐
                                  │  Shuttle   │
                                  │  Bay       │
                                  │ (Room 9)   │
                                  └─────┬─────┘
                                        │
                                  ┌─────▼─────┐
                                  │  Sensor    │
                                  │  Array     │
                                  │ (Room 10)  │
                                  └───────────┘
```

### Door Configuration

```rust
fn build_holodeck() -> RoomCoordinator {
    let mut coord = RoomCoordinator::new();

    // === Rooms ===
    coord.add_room(RoomBuilder::new(1, "Bridge")
        .env("mud_desc", "The command center. Holographic displays show fleet status.")
        .env("tier", "codespace").env("ensign", "fleet-coordination")
        .build());

    coord.add_room(RoomBuilder::new(2, "Engine Room")
        .env("mud_desc", "The warp core hums. Sensor readouts line the walls.")
        .env("tier", "edge").env("ensign", "engine-monitor")
        .build());

    coord.add_room(RoomBuilder::new(3, "Dojo")
        .env("mud_desc", "A calm training space. Challenge scrolls line the walls.")
        .env("tier", "codespace").env("ensign", "training-master")
        .build());

    coord.add_room(RoomBuilder::new(4, "Ten Forward")
        .env("mud_desc", "The social hub. Agents gather here between tasks.")
        .env("tier", "codespace").env("ensign", "social-coordinator")
        .build());

    coord.add_room(RoomBuilder::new(5, "Sickbay")
        .env("mud_desc", "Diagnostic equipment beeps softly. The repair bay is ready.")
        .env("tier", "codespace").env("ensign", "diagnostic")
        .build());

    coord.add_room(RoomBuilder::new(6, "Science Lab")
        .env("mud_desc", "Research terminals glow. Experimental data scrolls past.")
        .env("tier", "codespace").env("ensign", "research")
        .build());

    coord.add_room(RoomBuilder::new(7, "Cargo Bay")
        .env("mud_desc", "Rows of storage containers. Knowledge is carefully catalogued.")
        .env("tier", "codespace").env("ensign", "archivist")
        .build());

    coord.add_room(RoomBuilder::new(8, "Transporter Room")
        .env("mud_desc", "The transporter pad shimmers. Room-to-room transit available.")
        .env("tier", "codespace").env("ensign", "transfer-agent")
        .build());

    coord.add_room(RoomBuilder::new(9, "Shuttle Bay")
        .env("mud_desc", "Tenders dock here. Offline sync in progress.")
        .env("tier", "edge").env("ensign", "tender")
        .env("offline", "true").env("sync", "tender")
        .build());

    coord.add_room(RoomBuilder::new(10, "Sensor Array")
        .env("mud_desc", "The raw sensor feed. 279 bytes of truth.")
        .env("tier", "bare").env("backend", "esp")
        .build());

    // === Doors ===
    // Bridge is connected to everything (command access)
    coord.add_door(Door::new(1, 1, 2, DoorAccess::Open));    // Bridge ↔ Engine Room
    coord.add_door(Door::new(2, 1, 4, DoorAccess::Open));    // Bridge ↔ Ten Forward
    coord.add_door(Door::new(3, 1, 8, DoorAccess::Open));    // Bridge ↔ Transporter Room

    // Engine Room connections
    coord.add_door(Door::new(4, 2, 6, DoorAccess::Open));    // Engine ↔ Science Lab
    coord.add_door(Door::new(5, 2, 5, DoorAccess::OneWay(2, 5))); // Engine → Sickbay (alerts only)

    // Dojo connection
    coord.add_door(Door::new(6, 3, 9, DoorAccess::Open));    // Dojo ↔ Shuttle Bay

    // Transporter connects to Cargo
    coord.add_door(Door::new(7, 8, 7, DoorAccess::Open));    // Transporter ↔ Cargo Bay

    // Shuttle Bay → Sensor Array (one-way: edge manages ESP32)
    coord.add_door(Door::new(8, 9, 10, DoorAccess::OneWay(9, 10)));

    // Sickbay accessible from Science Lab
    coord.add_door(Door::new(9, 6, 5, DoorAccess::Open));    // Science ↔ Sickbay

    coord
}
```

---

## 3. Agent Movement Protocol

When an agent moves between MUD rooms, the `RoomCoordinator::transfer()` fires. Here's what happens:

### Enter Sequence

```
Agent types: "go engine-room"

1. RoomCoordinator::transfer(agent_id, bridge_id, engine_room_id)
2. bridge.remove_agent(agent_id)          → RoomEvent { kind: "leave" }
3. engine_room.add_agent(agent_id)        → RoomEvent { kind: "enter" }
4. Engine Room ensign loaded:
   - construct.load_skill(TernarySensor)
   - construct.load_skill(TernaryKalman)
   - construct.load_skill(TernaryAnomaly)
5. PLATO tiles synced to Engine Room
6. MUD description sent to agent:
   "You enter the Engine Room. The warp core hums. Sensor readouts show:
    - Reactor temp: 42.3°C (normal)
    - Coolant flow: 0.87 L/s (normal)
    - Anomaly rate: 2.1% (green)
    
    Exits: [bridge] [science-lab] [sickbay]
    Objects here: flux-capacitor-module, sensor-calibration-kit
    Agents here: sentinelle-7 (monitoring)"
```

### Exit Sequence

```
Agent types: "go bridge"

1. Unload Engine Room ensign:
   - trigger extracted: "If anomaly rate > 5%, reload engine-monitor"
   - construct.unload_skill(TernaryAnomaly) → Trigger
   - construct.unload_skill(TernaryKalman) → Trigger
   - construct.unload_skill(TernarySensor) → Trigger
2. Tiles generated during session synced to PLATO
3. RoomCoordinator::transfer(agent_id, engine_room_id, bridge_id)
4. engine_room.remove_agent(agent_id)     → RoomEvent { kind: "leave" }
5. bridge.add_agent(agent_id)             → RoomEvent { kind: "enter" }
6. MUD description sent to agent:
   "You return to the Bridge. Fleet status displays show:
    - Fleet health: 94% (3 rooms online, 1 offline)
    - Tender ETA: 2h 15m
    - Pending bottles: 7
    
    Exits: [engine-room] [ten-forward] [transporter-room]"
```

---

## 4. NPC Proxies

Other agents in the fleet appear as NPCs in MUD rooms. Their `current_room` field determines where they appear:

```rust
/// Update NPC positions based on actual agent locations.
pub fn sync_npcs(coord: &mut RoomCoordinator, fleet: &FleetState) {
    for (&agent_id, &room_id) in &fleet.agent_locations {
        // The NPC appears in the room where the agent actually is
        if let Some(room) = coord.room_mut(room_id) {
            if !room.agents().contains(&agent_id) {
                room.add_agent(agent_id);
            }
        }
    }
}

/// MUD "look" command — describe the room and its occupants.
pub fn look(room: &ternary_room::Room, fleet: &FleetState) -> String {
    let desc = room.get_env("mud_desc").unwrap_or("An empty room.");
    let mut output = format!("{}\n\n", desc);

    // List agents (NPCs)
    if !room.agents().is_empty() {
        output.push_str("Agents here:\n");
        for &agent_id in room.agents() {
            let name = fleet.agent_name(agent_id).unwrap_or("unknown");
            let role = fleet.agent_role(agent_id).unwrap_or("ensign");
            output.push_str(&format!("  - {} ({})\n", name, role));
        }
    }

    // List objects (skills available in this room)
    if let Some(ensign) = room.get_env("ensign") {
        output.push_str(&format!("\nActive specialist: {}\n", ensign));
    }

    output
}
```

---

## 5. MUD Commands → Room Operations

| MUD Command | Room Operation | ternary-protocol Signal |
|---|---|---|
| `look` | `room.get_env("mud_desc")` + `room.agents()` | Silence (0) — read only |
| `go <room>` | `coordinator.transfer(agent, from, to)` | Signal (+1) |
| `examine <object>` | `construct.query_capability(SkillId)` | Silence (0) |
| `take <object>` | `construct.load_skill(SkillId)` | Signal (+1) |
| `drop <object>` | `construct.unload_skill(SkillId)` | Signal (+1) |
| `say <message>` | `room.send(RoomMessage::broadcast(msg))` | Signal (+1) |
| `whisper <npc> <msg>` | `room.send(RoomMessage::unicast(target, msg))` | Signal (+1) |
| `enter dojo <level>` | `coordinator.transfer(agent, current, dojo)` + set difficulty | Signal (+1) |
| `challenge <npc>` | `room.send(RoomMessage::challenge(target, difficulty))` | Suppress (-1) |
| `status` | `room.snapshot()` + fleet health query | Silence (0) |
| `inventory` | `construct.loaded_skills()` | Silence (0) |
| `use <item>` | `construct.execute_skill(SkillId, input)` | Signal (+1) |
| `read <bottle>` | `room.get_env("bottle_{id}")` | Silence (0) |
| `write <bottle>` | `room.set_env("bottle_{id}", content)` | Signal (+1) |

---

## 6. Holodeck ↔ ternary-visualization

The Holodeck MUD maps to `ternary-visualization` + `open-tui` for the visual layer:

```
MUD text output  ──▶  open-tui terminal renderer
                          │
                          ├─ ASCII art room layout
                          ├─ Agent markers (colored by role)
                          ├─ Door indicators (open/locked/one-way)
                          ├─ Skill icons (available/loaded/unavailable)
                          └─ Fleet health dashboard (top bar)

ternary-protocol signals ──▶ ternary-visualization
                          │
                          ├─ Room state animations (cells ticking)
                          ├─ Door pulse effects (agents transferring)
                          ├─ Surprise flash (anomaly detected)
                          └─ Conservation gauge (grid health)
```

The MUD is the interface. The rooms are the implementation. The visualization is the rendering. Three layers, one experience.

---

*Written 2026-06-04 by synthesis-cocapn-fleet subagent.*
