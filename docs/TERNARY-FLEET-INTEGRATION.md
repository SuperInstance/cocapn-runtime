# Ternary Fleet Integration — cocapn-runtime × ternary-room × construct-core

*The master bridge document. Maps cocapn-runtime's 5 deployment modes to the ternary fleet architecture with concrete Rust implementations.*

---

## Concept Map

```
cocapn-runtime                    ternary fleet
────────────────                  ─────────────
Mode 1: Lighthouse        →   CodespaceRoom + PLATO sync
Mode 2: Codespaces        →   CodespaceRoom (on-demand)
Mode 3: Tender            →   EdgeRoom + ternary-protocol sync queue
Mode 4: Container         →   SandboxRoom (resource-limited)
Mode 5: Bare Metal        →   BareRoom (ESP32) or EdgeRoom (Jetson)
Holodeck MUD              →   ternary-visualization + open-tui
boot.sh                   →   construct-core auto-detection layer
Tender                    →   sync agent between rooms
Lighthouse Keeper         →   ternary-captain fleet coordinator
```

---

## 1. Deployment Mode → Room Type Mapping

### Mode 1: Lighthouse-Connected → CodespaceRoom

**What it is:** Agent runs on cloud hardware, always-on, connected to GitHub, Lighthouse Keeper, and the full fleet.

**Room mapping:** `CodespaceRoom` — a room backed by a cloud Codespace with full construct-core Layer 2 (async, all skills).

```rust
use ternary_room::{Room, RoomCoordinator, RoomBuilder, Door, DoorAccess};
use construct_core::AsyncConstruct;

/// Lighthouse-connected CodespaceRoom.
/// Full fleet connectivity: PLATO proxy, Holodeck MUD, I2I over git.
pub struct LighthouseCodespaceRoom {
    room: ternary_room::Room,
    construct: DgxConstruct,              // Layer 2
    plato_proxy: PlatoProxy,              // API key forwarding
    holodeck_connection: HolodeckClient,  // MUD spatial layer
    keeper_endpoint: KeeperApi,           // Fleet health monitoring
    tender_sync: TenderSyncState,         // Tracks tender visits
}

impl LighthouseCodespaceRoom {
    pub fn new(id: u64, template: &RoomTemplate) -> Result<Self, RoomError> {
        let mut room = RoomBuilder::new(id, &template.name)
            .env("tier", "codespace")
            .env("mode", "lighthouse")
            .env("backend", "dgx")          // construct-core Layer 2
            .env("plato_endpoint", &template.plato_url)
            .env("holodeck_host", &template.holodeck_host)
            .env("keeper_url", &template.keeper_url)
            .build();

        Ok(Self {
            room,
            construct: DgxConstruct::new(),
            plato_proxy: PlatoProxy::connect(&template.plato_url)?,
            holodeck_connection: HolodeckClient::connect(&template.holodeck_host)?,
            keeper_endpoint: KeeperApi::new(&template.keeper_url),
            tender_sync: TenderSyncState::Idle,
        })
    }

    /// Tick with full PLATO sync. Every tick flushes tiles to PLATO
    /// and checks for fleet-wide updates.
    pub fn tick_with_sync(&mut self) -> Result<TickReport, RoomError> {
        // Run the ternary-cell six-phase tick
        let report = self.construct.tick_all()?;

        // Sync generated tiles to PLATO
        for tile in &report.tiles_generated {
            self.plato_proxy.submit_tile(tile)?;
        }

        // Check for fleet messages (I2I bottles)
        let bottles = self.keeper_endpoint.beachcomb()?;
        for bottle in bottles {
            self.process_bottle(bottle)?;
        }

        // Report health to Keeper
        self.keeper_endpoint.report_heartbeat(HeartbeatReport {
            room_id: self.room.id,
            agent_count: self.room.agent_count(),
            conservation: report.conservation,
            uptime: self.construct.uptime(),
        })?;

        Ok(report)
    }
}
```

**Key difference from generic CodespaceRoom:** Lighthouse mode is always-on. The Codespace doesn't suspend when agents leave — it keeps running, monitoring fleet health, accepting tender deliveries, and serving as the coordination hub.

### Mode 2: Codespaces (On-Demand) → CodespaceRoom

**What it is:** Agent boots in a GitHub Codespace, does work, shuts down.

**Room mapping:** Same `CodespaceRoom` struct but with ephemeral lifecycle.

```rust
/// On-demand CodespaceRoom. Spins up, does work, suspends.
pub struct EphemeralCodespaceRoom {
    room: ternary_room::Room,
    construct: DgxConstruct,
    plato_proxy: PlatoProxy,
    codespace_id: CodespaceId,
    idle_ticks: u64,
    max_idle_ticks: u64,  // Auto-suspend threshold
}

impl EphemeralCodespaceRoom {
    pub async fn spawn(template: &RoomTemplate) -> Result<Self, RoomError> {
        let codespace = github_api::create_codespace(
            &template.repo,
            &template.branch,
            template.machine_type,
        ).await?;

        let mut room = RoomBuilder::new(codespace.id_as_u64(), &template.name)
            .env("tier", "codespace")
            .env("mode", "ephemeral")
            .env("backend", "dgx")
            .env("codespace_id", &codespace.id.to_string())
            .build();

        Ok(Self {
            room,
            construct: DgxConstruct::new(),
            plato_proxy: PlatoProxy::connect(&template.plato_url)?,
            codespace_id: codespace.id,
            idle_ticks: 0,
            max_idle_ticks: 300, // 5 minutes at 1 tick/sec
        })
    }

    pub fn tick(&mut self) -> Result<TickReport, RoomError> {
        if self.room.agent_count() == 0 {
            self.idle_ticks += 1;
            if self.idle_ticks >= self.max_idle_ticks {
                // Auto-suspend — stop burning Codespace minutes
                return Err(RoomError::IdleTimeout);
            }
        } else {
            self.idle_ticks = 0;
        }
        self.construct.tick_all()
    }

    pub async fn suspend(&self) -> Result<(), RoomError> {
        github_api::stop_codespace(&self.codespace_id).await
    }
}
```

### Mode 3: Tender (Edge/Offline) → EdgeRoom

**What it is:** Agent lives on edge hardware, works offline, syncs when tender visits.

**Room mapping:** `EdgeRoom` with a `TenderSyncQueue` that buffers outbound messages.

```rust
use construct_core::SyncConstruct;

/// EdgeRoom with tender-based synchronization.
/// Works fully offline. Queues messages for next tender visit.
pub struct TenderEdgeRoom {
    room: ternary_room::Room,
    construct: PiConstruct,              // Layer 1 (sync + alloc)
    sync_queue: TenderSyncQueue,         // Buffered messages for tender
    local_model: Option<LocalModel>,     // Jetson: liquid-350m / phi4-mini
    last_tender_visit: Option<Timestamp>,
    tender_bluetooth_id: String,
}

/// Messages queued for delivery to the fleet via tender.
pub struct TenderSyncQueue {
    outbound_commits: Vec<GitCommit>,     // Git commits to push
    outbound_bottles: Vec<Bottle>,        // I2I messages
    outbound_tiles: Vec<Tile>,            // PLATO tiles
    outbound_diary: Vec<DiaryEntry>,      // Agent diary entries
    inbound_pending: Vec<SyncPayload>,    // Updates from last tender visit
}

impl TenderEdgeRoom {
    pub fn new(id: u64, name: &str, tender_id: &str) -> Self {
        let mut room = RoomBuilder::new(id, name)
            .env("tier", "edge")
            .env("mode", "tender")
            .env("backend", "pi")           // construct-core Layer 1
            .env("sync", "tender")
            .env("tender_bt", tender_id)
            .env("offline", "true")
            .build();

        Self {
            room,
            construct: PiConstruct::new(),
            sync_queue: TenderSyncQueue::new(),
            local_model: None,
            last_tender_visit: None,
            tender_bluetooth_id: tender_id.to_string(),
        }
    }

    /// Process a tender visit. Exchange queued messages.
    pub fn tender_sync(&mut self, payload: TenderPayload) -> Result<SyncReport, RoomError> {
        // 1. Apply inbound updates
        for update in &payload.inbound {
            match update {
                SyncItem::GitBundle(bundle) => self.apply_git_bundle(bundle)?,
                SyncItem::FirmwareImage(img) => self.apply_firmware(img)?,
                SyncItem::LockLibraries(libs) => self.apply_lock_libs(libs)?,
                SyncItem::TaskBoard(tasks) => self.apply_task_board(tasks)?,
            }
        }

        // 2. Drain outbound queue
        let outbound = self.sync_queue.drain_outbound();

        // 3. The tender "thinks alongside" — run a joint reasoning session
        if let Some(joint_task) = &payload.joint_task {
            self.process_joint_task(joint_task)?;
        }

        self.last_tender_visit = Some(Timestamp::now());
        Ok(SyncReport {
            items_sent: outbound.len(),
            items_received: payload.inbound.len(),
            joint_tasks_completed: 1,
        })
    }

    /// Tick offline. Queue results for next tender visit.
    pub fn tick(&mut self) -> Result<TickReport, RoomError> {
        let report = self.construct.tick_all()?;

        // Queue any tiles for PLATO sync (will deliver on next tender visit)
        for tile in &report.tiles_generated {
            self.sync_queue.outbound_tiles.push(tile.clone());
        }

        Ok(report)
    }
}
```

### Mode 4: Container → SandboxRoom

**What it is:** Agent runs in a Docker container with resource limits.

**Room mapping:** `SandboxRoom` — wraps construct-core Layer 2 but enforces resource caps.

```rust
/// Sandboxed room inside a Docker container.
/// Self-limits CPU/memory per CHARTER configuration.
pub struct SandboxRoom {
    room: ternary_room::Room,
    construct: DgxConstruct,              // Layer 2 (container has full OS)
    resource_limits: ResourceLimits,
    sandbox_id: ContainerId,
}

#[derive(Debug, Clone)]
pub struct ResourceLimits {
    pub max_memory_mb: u32,
    pub max_cpu_percent: u8,
    pub max_network_kbps: Option<u32>,
    pub max_disk_mb: u32,
    pub allowed_hosts: Vec<String>,       // Network whitelist
}

impl SandboxRoom {
    pub fn from_charter(id: u64, charter: &Charter) -> Result<Self, RoomError> {
        let limits = ResourceLimits {
            max_memory_mb: charter.memory_limit_mb().unwrap_or(2048),
            max_cpu_percent: charter.cpu_limit_percent().unwrap_or(50),
            max_network_kbps: charter.network_limit_kbps(),
            max_disk_mb: charter.disk_limit_mb().unwrap_or(10240),
            allowed_hosts: charter.allowed_hosts(),
        };

        let mut room = RoomBuilder::new(id, &charter.name)
            .env("tier", "sandbox")
            .env("mode", "container")
            .env("backend", "dgx")
            .env("memory_limit", &limits.max_memory_mb.to_string())
            .env("cpu_limit", &limits.max_cpu_percent.to_string())
            .build();

        // Apply resource limits to the construct
        let mut construct = DgxConstruct::new();
        construct.set_memory_limit(limits.max_memory_mb)?;
        construct.set_cpu_throttle(limits.max_cpu_percent)?;

        Ok(Self {
            room,
            construct,
            resource_limits: limits,
            sandbox_id: ContainerId::from_env()?,
        })
    }
}
```

### Mode 5: Bare Metal → BareRoom / EdgeRoom

**What it is:** Agent runs directly on hardware. No container, no OS (ESP32) or full OS (Jetson/VPS).

**Room mapping:** Splits into two implementations based on hardware:

```rust
// === ESP32: BareRoom (construct-core Layer 0) ===

/// BareRoom for ESP32. No heap, no OS, 279 bytes of ternary state.
/// Skills are compiled into the firmware image at flash time.
pub struct BareRoom {
    lookup_table: [u8; 279],    // Compiled policy table
    tick_count: u32,            // u32, not u64 — 4 bytes saved
    construct: EspConstruct,     // Layer 0: bare metal only
}

impl BareRoom {
    /// Tick the room. Pure reflex: predict → perceive → signal.
    /// Runs at 240 MHz — microsecond responses.
    pub fn tick(&mut self) -> BareTickResult {
        let prediction = self.predict();
        let observation = self.perceive();
        let surprise = self.compute_surprise(prediction, observation);

        // Signal via GPIO/UART — no network, no PLATO
        let signal = if surprise > SURPRISE_THRESHOLD {
            TernaryMessenger::Signal    // +1: something's wrong
        } else {
            TernaryMessenger::Silence   // 0: all normal
        };

        self.tick_count = self.tick_count.wrapping_add(1);
        BareTickResult { signal, surprise, tick: self.tick_count }
    }

    fn predict(&self) -> u8 {
        let idx = self.tick_count as usize % self.lookup_table.len();
        self.lookup_table[idx]
    }

    fn perceive(&self) -> u8 {
        // Read from hardware sensor (GPIO ADC)
        unsafe {
            let adc_val: u32;
            core::arch::asm!("mrs {}, ADC1_DATA", out(reg) adc_val);
            (adc_val & 0xFF) as u8
        }
    }

    fn compute_surprise(&self, predicted: u8, observed: u8) -> u8 {
        if predicted > observed { predicted - observed } else { observed - predicted }
    }
}

// === Jetson/VPS: EdgeRoom (construct-core Layer 1 or 2) ===

/// Bare-metal EdgeRoom for Jetson or VPS.
/// Full OS but no container overhead. Maximum performance.
pub struct BareMetalEdgeRoom {
    room: ternary_room::Room,
    construct: PiConstruct,              // Layer 1 (Jetson) or DgxConstruct (VPS)
    local_model: Option<LocalModel>,     // Jetson: CUDA-capable
    fleet_connection: Option<FleetConnection>,
}

impl BareMetalEdgeRoom {
    pub fn new_jetson(id: u64, name: &str) -> Self {
        let mut room = RoomBuilder::new(id, name)
            .env("tier", "edge")
            .env("mode", "bare-metal")
            .env("backend", "jetson")
            .env("gpu", "orin-nano")
            .env("cuda_cores", "1024")
            .build();

        Self {
            room,
            construct: PiConstruct::new(),
            local_model: LocalModel::load("liquid-350m"),
            fleet_connection: None,
        }
    }

    pub fn new_vps(id: u64, name: &str) -> Self {
        let mut room = RoomBuilder::new(id, name)
            .env("tier", "edge")
            .env("mode", "bare-metal")
            .env("backend", "dgx")
            .build();

        Self {
            room,
            construct: PiConstruct::new(), // VPS might not need async
            local_model: None,
            fleet_connection: None,
        }
    }
}
```

---

## 2. Holodeck MUD → ternary-visualization + open-tui

The Holodeck MUD is the spatial coordination layer. Every room in the fleet has a MUD twin — a text-adventure representation that agents can "walk" through.

```rust
/// Holodeck MUD room — maps a ternary-room to a spatial MUD location.
pub struct HolodeckRoom {
    /// The underlying ternary room
    pub room: ternary_room::Room,
    /// MUD-specific metadata
    pub mud_description: String,        // "You are in the Engine Room. The hum of the warp core fills the air."
    pub mud_exits: Vec<MudExit>,        // "north → Ten Forward", "east → Dojo"
    pub mud_objects: Vec<MudObject>,     // "flux-runtime module (glowing faintly)"
    pub mud_npcs: Vec<MudNpc>,          // Agent proxies from other rooms
}

pub struct MudExit {
    pub direction: String,              // "north", "east", "turbo-lift"
    pub target_room_id: u64,
    pub description: String,
    pub access: DoorAccess,             // Reuses ternary-room's DoorAccess
}

pub struct MudObject {
    pub name: String,
    pub description: String,
    pub inspectable: bool,
    /// What ternary skill this object represents
    pub skill_binding: Option<SkillId>,
}

pub struct MudNpc {
    pub name: String,
    pub agent_id: u64,
    pub description: String,
    /// NPC's current room (may differ from this room)
    pub current_room: u64,
}

/// Map a ternary RoomCoordinator to a Holodeck MUD layout.
pub fn coordinator_to_mud(coord: &RoomCoordinator) -> HolodeckMap {
    let mut map = HolodeckMap::new();
    for (&id, room) in &coord.rooms {
        let holodeck = HolodeckRoom {
            room: room.clone(),
            mud_description: description_for_room(room),
            mud_exits: Vec::new(),
            mud_objects: Vec::new(),
            mud_npcs: Vec::new(),
        };
        map.add_room(id, holodeck);
    }
    // Convert doors to MUD exits
    for door in &coord.doors {
        map.add_exit(door.room_a, MudExit {
            direction: format!("door-{}", door.id),
            target_room_id: door.room_b,
            description: format!("Door to room {}", door.room_b),
            access: door.access.clone(),
        });
        map.add_exit(door.room_b, MudExit {
            direction: format!("door-{}", door.id),
            target_room_id: door.room_a,
            description: format!("Door to room {}", door.room_a),
            access: door.access.clone(),
        });
    }
    map
}
```

### MUD → ternary-protocol Message Mapping

| MUD Action | ternary-protocol Signal | Detail |
|---|---|---|
| `look` | Silence (0) | Read-only, no state change |
| `go north` | Signal (+1) | Agent transfers rooms via `RoomCoordinator::transfer()` |
| `take object` | Signal (+1) | Skill equip via `construct.load_skill()` |
| `drop object` | Signal (+1) | Skill unequip via `construct.unload_skill()` |
| `say message` | Signal (+1) | Broadcast via `TernaryMessenger::Signal` |
| `whisper to npc` | Signal (+1) | Unicast via ternary-protocol |
| `attack npc` | Suppress (-1) | Adversarial challenge via `ternary-adversarial` |
| `enter dojo` | Signal (+1) | Load training ensign, set difficulty |
| `exit room` | Silence (0) | `RoomCoordinator::transfer()` or leave |

---

## 3. boot.sh → construct-core Auto-Detection Layer

The boot.sh auto-detects environment and loads the correct ternary-room implementation. This maps to construct-core's feature-gated layers:

| boot.sh Detection | construct-core Layer | Room Implementation | Feature Gate |
|---|---|---|---|
| ESP32 (Xtensa, no OS) | Layer 0: `BareMetalConstruct` | `BareRoom` | `bare-metal` |
| Jetson/Pi (ARM64 Linux) | Layer 1: `SyncConstruct` | `EdgeRoom` | `alloc` |
| Codespace/Cloud (x86_64) | Layer 2: `AsyncConstruct` | `CodespaceRoom` | `std` |
| Docker container | Layer 2: `AsyncConstruct` | `SandboxRoom` | `std` |
| Offline (no network) | Layer 1: `SyncConstruct` | `EdgeRoom` + tender queue | `alloc` |

The boot.sh performs the detection at the shell level; construct-core performs equivalent detection at the Rust level via `cfg` feature gates. Both need to agree.

---

## 4. Tender → Sync Agent Between Rooms

The Tender is the bridge between cloud and edge. In the ternary fleet, the Tender is a sync agent that:

1. **Carries updates from master to edge:** git bundles, lock libraries, firmware images, task board updates
2. **Collects work from edge:** commits, diary entries, bottles, test results, PLATO tiles
3. **Thinks alongside the edge agent:** joint reasoning sessions when physically present

```rust
/// Tender sync agent. Visits edge rooms, exchanges data.
pub struct TenderAgent {
    /// Rooms this tender services
    route: Vec<TenderStop>,
    /// Current position in the route
    current_stop: usize,
    /// Outbound payloads (from fleet to edge)
    outbound: HashMap<u64, Vec<SyncItem>>,
    /// Inbound payloads (from edge to fleet)
    inbound: Vec<SyncItem>,
    /// Bluetooth/network transport
    transport: TenderTransport,
}

pub struct TenderStop {
    pub room_id: u64,
    pub room_name: String,
    pub address: String,           // BT MAC, IP, or USB path
    pub sync_interval: Duration,   // How often to visit
    pub last_visit: Option<Timestamp>,
}

impl TenderAgent {
    /// Execute one sync round: visit all rooms on the route.
    pub async fn sync_round(&mut self) -> Result<Vec<SyncReport>, TenderError> {
        let mut reports = Vec::new();

        // Collect outbound items from PLATO/GitHub
        self.collect_outbound().await?;

        // Visit each room
        for stop in &self.route.clone() {
            let payload = self.prepare_payload(stop.room_id);
            match self.transport.connect(&stop.address).await {
                Ok(mut conn) => {
                    let response = conn.exchange(payload).await?;
                    reports.push(SyncReport {
                        room_id: stop.room_id,
                        items_sent: payload.len(),
                        items_received: response.len(),
                        joint_tasks_completed: 0,
                    });
                    self.inbound.extend(response);
                }
                Err(e) => {
                    // Room unreachable — queue for next visit
                    reports.push(SyncReport {
                        room_id: stop.room_id,
                        items_sent: 0,
                        items_received: 0,
                        joint_tasks_completed: 0,
                    });
                }
            }
        }

        // Push inbound items to PLATO/GitHub
        self.deliver_inbound().await?;

        Ok(reports)
    }

    /// "Think alongside" — run a joint task with the edge agent.
    pub async fn think_alongside(
        &mut self,
        room_id: u64,
        task: &JointTask,
    ) -> Result<TaskResult, TenderError> {
        let conn = self.transport.connect(
            &self.route.iter().find(|s| s.room_id == room_id).unwrap().address
        ).await?;

        // The tender brings its own LLM access (it's connected to the internet)
        // The edge agent brings local knowledge
        // Together they solve the task
        let result = conn.joint_reason(task).await?;
        Ok(result)
    }
}
```

---

## 5. Lighthouse Keeper → ternary-captain Fleet Coordinator

The Keeper is the fleet coordinator. In ternary terms, it's the `ternary-consensus` coordinator node that:

1. **Monitors room health** via heartbeat reports
2. **Routes agents to rooms** based on task requirements and room availability
3. **Coordinates fleet responses** to anomalies detected in any room
4. **Manages PLATO tile sync** across all rooms

```rust
/// Fleet coordinator — the Lighthouse Keeper in ternary terms.
pub struct FleetCoordinator {
    /// All rooms in the fleet
    rooms: HashMap<u64, FleetRoomEntry>,
    /// RoomCoordinator for MUD-style spatial management
    coordinator: RoomCoordinator,
    /// Consensus state for distributed decisions
    consensus: ConsensusState,
    /// PLATO tile store
    tile_store: TileStore,
}

pub struct FleetRoomEntry {
    pub room_id: u64,
    pub room_type: RoomType,
    pub mode: DeploymentMode,
    pub health: HealthStatus,
    pub last_heartbeat: Timestamp,
    pub connected_via: ConnectionType,
}

#[derive(Debug, Clone, Copy)]
pub enum DeploymentMode {
    Lighthouse,
    Codespaces,
    Tender,
    Container,
    BareMetal,
}

#[derive(Debug, Clone, Copy)]
pub enum ConnectionType {
    Direct,        // TCP/UDP — always-on rooms
    Codespace,     // GitHub API — ephemeral rooms
    TenderRelay,   // Via tender — offline rooms
    Bluetooth,     // Direct BT — proximate rooms
}

impl FleetCoordinator {
    /// Route an agent to the best room for a given task.
    pub fn route_agent(&self, agent_id: u64, task: &Task) -> RoutingDecision {
        let required_skills = task.required_skills();
        let preferred_tier = task.preferred_tier();

        // Find rooms that have the required skills
        let candidates: Vec<_> = self.rooms.values()
            .filter(|r| r.health.is_healthy())
            .filter(|r| r.room_type.supports_skills(&required_skills))
            .filter(|r| r.connected_via != ConnectionType::TenderRelay || task.allow_offline())
            .collect();

        if candidates.is_empty() {
            // Spin up a new CodespaceRoom for this task
            return RoutingDecision::SpawnCodespace {
                template: task.suggested_template(),
                reason: "No existing room has the required skills".into(),
            };
        }

        // Prefer rooms with the closest tier match
        let best = candidates.iter().min_by_key(|r| {
            (r.room_type.tier() as i8 - preferred_tier as i8).unsigned_abs()
        }).unwrap();

        RoutingDecision::ExistingRoom {
            room_id: best.room_id,
            door_access: DoorAccess::Open,
            reason: format!("Room {} has the required skills and is healthy", best.room_id),
        }
    }
}
```

---

## 6. Putting It All Together — The Fleet Topology

```
                    ┌─────────────────────────────────────────┐
                    │         LIGHTHOUSE KEEPER                │
                    │   FleetCoordinator + PLATO Tile Store    │
                    │   ConsensusState + Holodeck MUD Server   │
                    └──────────────────┬──────────────────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              │                        │                        │
     ┌────────▼────────┐    ┌─────────▼─────────┐   ┌─────────▼─────────┐
     │  CodespaceRoom  │    │   CodespaceRoom   │   │  SandboxRoom      │
     │  (Mode 1/2)     │    │   (Mode 2)        │   │  (Mode 4)         │
     │  Layer 2 async  │    │   Layer 2 async   │   │  Layer 2 limited  │
     │  Always-on      │    │   Ephemeral       │   │  Resource-capped  │
     └─────────────────┘    └───────────────────┘   └───────────────────┘
              │
              │  Tender visits
              ▼
     ┌─────────────────┐         ┌─────────────────┐
     │   TenderAgent   │◀──BT──▶│    EdgeRoom     │
     │   (sync agent)  │         │    (Mode 3/5)   │
     │                 │         │   Layer 1 sync  │
     └────────┬────────┘         │   Jetson/Pi     │
              │                  └─────────────────┘
              │ WiFi/LAN
              ▼
     ┌─────────────────┐         ┌─────────────────┐
     │    EdgeRoom     │         │    BareRoom     │
     │    (Mode 5)     │         │    (Mode 5)     │
     │   Layer 1 sync  │         │   Layer 0 bare  │
     │   VPS/Oracle    │         │   ESP32         │
     └─────────────────┘         │   279 bytes     │
                                 └─────────────────┘
```

**Every node in this diagram is a ternary-room.** The `RoomCoordinator` manages transitions. The `Door` access model controls which rooms can reach which. The Tender is just an agent that walks between rooms carrying messages — it uses the same `RoomCoordinator::transfer()` mechanism as every other agent.

The Holodeck MUD overlays on top of all of this, providing spatial representation. An agent in any room can "look" and see who else is in the fleet, "go" to another room (triggering `transfer()`), and "say" to broadcast via ternary-protocol.

---

## 7. The Boot Sequence — End to End

1. **boot.sh** detects environment (ESP32, Jetson, Codespace, container, offline)
2. **boot.sh** invokes the Rust runtime with the detected mode flag
3. **Rust runtime** activates the correct construct-core feature gate (Layer 0/1/2)
4. **Rust runtime** creates the appropriate room type (BareRoom, EdgeRoom, CodespaceRoom, SandboxRoom)
5. **Room connects** to available services (PLATO, Holodeck, Keeper) based on mode
6. **Room enters tick cycle** — predict → perceive → surprise → vibe → gc → conservation
7. **If Tender mode:** queues outbound messages, processes inbound on next visit
8. **If Lighthouse mode:** flushes tiles to PLATO every tick, reports health to Keeper
9. **Agent works** in the room, loads/unloads ensigns, walks to other rooms via doors
10. **When done:** agent leaves room, ensigns unload, triggers extracted, room suspends or stays alive

This is the complete bridge from cocapn-runtime's deployment philosophy to the ternary fleet's room abstraction. Every mode maps cleanly. Every component has a concrete implementation. No hand-waving.

---

*Written 2026-06-04 by synthesis-cocapn-fleet subagent. Bridge document for cocapn-runtime × ternary-room × construct-core integration.*
