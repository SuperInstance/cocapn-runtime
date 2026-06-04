# Construct-Core Bridge — boot.sh × construct-core Layers

*How cocapn-runtime's boot.sh environment detection maps to construct-core's three-layer trait system.*

---

## The Three Layers

construct-core defines three hardware abstraction layers:

| Layer | Trait | Environment | Hardware | Feature Gate |
|---|---|---|---|---|
| 0 | `BareMetalConstruct` | `no_std`, no alloc | ESP32, Cortex-M | `bare-metal` |
| 1 | `SyncConstruct` | `no_std` + alloc | Pi, Jetson, embedded Linux | `alloc` |
| 2 | `AsyncConstruct` | `std` + async | Workstation, DGX, Cloud | `std` |

Each higher layer supersedes the one below. `DgxConstruct` implements all three. `EspConstruct` implements only Layer 0.

---

## boot.sh Detection → construct-core Layer

### Detection Logic (boot.sh side)

```bash
detect_layer() {
    # Layer 0: Bare metal (ESP32 — Xtensa architecture, no OS)
    if [ "$(uname -m)" = "xtensa" ] 2>/dev/null; then
        echo "layer0"
        return
    fi

    # Layer 0: Bare metal (ARM Cortex-M — no Linux)
    if [ -d "/sys/firmware/devicetree" ] && [ "$(uname -s)" != "Linux" ]; then
        echo "layer0"
        return
    fi

    # Layer 2: Codespace (GitHub sets CODESPACES env var)
    if [ -n "$CODESPACES" ]; then
        echo "layer2"
        return
    fi

    # Layer 2: Container (Docker sets /.dockerenv)
    if [ -f "/.dockerenv" ]; then
        echo "layer2"
        return
    fi

    # Layer 2: Kubernetes (KUBERNETES_SERVICE_HOST)
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        echo "layer2"
        return
    fi

    # Layer 1: ARM64 Linux (Jetson, Pi)
    if [ "$(uname -m)" = "aarch64" ] && [ "$(uname -s)" = "Linux" ]; then
        echo "layer1"
        return
    fi

    # Layer 1: ARM32 Linux (older Pi)
    if [ "$(uname -m)" = "armv7l" ] && [ "$(uname -s)" = "Linux" ]; then
        echo "layer1"
        return
    fi

    # Layer 2: x86_64 (workstation, VPS, cloud)
    if [ "$(uname -m)" = "x86_64" ]; then
        echo "layer2"
        return
    fi

    # Default: Layer 1 (conservative)
    echo "layer1"
}
```

### Detection Logic (Rust side)

```rust
/// Runtime environment detection — mirrors boot.sh logic.
pub fn detect_layer() -> ConstructLayer {
    // Layer 0 is compile-time only (no_std). If this code runs, we're Layer 1+.

    // Check for Codespace
    if std::env::var("CODESPACES").is_ok() {
        return ConstructLayer::Layer2;
    }

    // Check for container
    if std::path::Path::new("/.dockerenv").exists() {
        return ConstructLayer::Layer2;
    }

    // Check for Kubernetes
    if std::env::var("KUBERNETES_SERVICE_HOST").is_ok() {
        return ConstructLayer::Layer2;
    }

    // Check architecture
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;

    match (arch, os) {
        ("aarch64", "linux") => {
            // Jetson or Pi — Layer 1 (sync + alloc)
            // Could be Layer 2 if we detect tokio availability
            ConstructLayer::Layer1
        }
        ("x86_64", _) => ConstructLayer::Layer2,
        _ => ConstructLayer::Layer1, // Conservative default
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConstructLayer {
    Layer0, // BareMetalConstruct — compile-time only
    Layer1, // SyncConstruct — alloc, no async
    Layer2, // AsyncConstruct — std + async
}
```

---

## Layer Capability Matrix

### Layer 0: BareMetalConstruct (ESP32)

```rust
// What Layer 0 can do:
pub trait BareMetalConstruct {
    /// Static capability introspection. No dynamic loading.
    fn query_capability(&self, skill: SkillId) -> CapabilityStatus;

    /// Get the compiled lookup table (279 bytes).
    fn lookup_table(&self) -> &[u8; 279];

    /// Tick one cycle. Pure reflex: predict → perceive → signal.
    fn tick(&mut self) -> BareTickResult;

    /// Read sensor value (GPIO/ADC).
    fn read_sensor(&self, channel: u8) -> u8;

    /// Signal output (GPIO/UART).
    fn signal(&self, value: TernaryMessenger);
}

// What Layer 0 CANNOT do:
// - No dynamic skill loading
// - No network
// - no heap allocation
// - No async I/O
// - No PLATO proxy
// - No ensign loading
// - No room transitions (fixed at compile time)
```

### Layer 1: SyncConstruct (Pi, Jetson)

```rust
// Extends BareMetalConstruct with:
pub trait SyncConstruct: BareMetalConstruct {
    /// Dynamically load a skill (heap allocation required).
    fn load_skill(&mut self, skill: SkillId) -> Result<SkillHandle, ConstructError>;

    /// Unload a skill, extracting muscle-memory trigger.
    fn unload_skill(&mut self, handle: SkillHandle) -> Result<Trigger, ConstructError>;

    /// List loaded skills.
    fn loaded_skills(&self) -> &[SkillId];

    /// Run the full tick cycle on all loaded cells.
    fn tick_all(&mut self) -> Result<TickReport, ConstructError>;

    /// Read from local filesystem.
    fn read_file(&self, path: &str) -> Result<Vec<u8>, ConstructError>;

    /// Write to local filesystem.
    fn write_file(&mut self, path: &str, data: &[u8]) -> Result<(), ConstructError>;
}

// What Layer 1 CANNOT do:
// - No async I/O (no tokio)
// - No network (unless using blocking sockets)
// - No PLATO proxy (no async HTTP)
// - Limited model inference (sync only)
```

### Layer 2: AsyncConstruct (DGX, Cloud, Codespace)

```rust
// Extends SyncConstruct with:
pub trait AsyncConstruct: SyncConstruct {
    /// Request an async tool (LLM, database, network service).
    fn request_tool(&mut self, tool: ToolId) -> Result<ToolHandle, ConstructError>;

    /// Release a tool when no longer needed.
    fn release_tool(&mut self, handle: ToolHandle) -> Result<(), ConstructError>;

    /// Async tick with PLATO sync.
    fn tick_with_sync(&mut self) -> impl std::future::Future<Output = Result<TickReport, ConstructError>> + Send;

    /// Query PLATO tile store.
    fn query_plato(&self, domain: &str, query: &str) -> impl std::future::Future<Output = Result<Vec<Tile>, ConstructError>> + Send;

    /// Submit tiles to PLATO.
    fn submit_tiles(&self, tiles: Vec<Tile>) -> impl std::future::Future<Output = Result<(), ConstructError>> + Send;

    /// Connect to Holodeck MUD.
    fn connect_holodeck(&mut self, host: &str) -> impl std::future::Future<Output = Result<HolodeckClient, ConstructError>> + Send;
}
```

---

## Feature Gate Agreement

boot.sh and Cargo.toml must agree on features:

| boot.sh Mode | Cargo feature | Rust layer | Construct type |
|---|---|---|---|
| ESP32 bare metal | `--features bare-metal` | Layer 0 | `EspConstruct` |
| Jetson/Pi | `--features alloc` | Layer 1 | `PiConstruct` |
| Codespace/Cloud/VPS | `--features std` | Layer 2 | `DgxConstruct` |

The boot.sh passes this to the Rust binary:

```bash
#!/bin/bash
LAYER=$(detect_layer)

case "$LAYER" in
    layer0)
        # ESP32: cross-compile and flash, no runtime selection
        echo "🔮 Layer 0: Bare metal (ESP32)"
        # Binary was compiled with --features bare-metal at flash time
        ;;
    layer1)
        echo "🔮 Layer 1: Sync + alloc (Edge)"
        exec /usr/local/bin/ternary-agent --features alloc --mode edge
        ;;
    layer2)
        echo "🔮 Layer 2: Async (Cloud/Codespace)"
        exec /usr/local/bin/ternary-agent --features std --mode cloud
        ;;
esac
```

---

## Construct Instantiation by Mode

```rust
/// Factory function — create the right construct for the detected layer.
pub fn create_construct(layer: ConstructLayer) -> Box<dyn CoreConstruct> {
    match layer {
        ConstructLayer::Layer0 => {
            // This branch is unreachable at runtime — Layer 0 is no_std
            // and this code runs in std context. ESP32 gets its own binary.
            panic!("Layer 0 constructs are compile-time only");
        }
        ConstructLayer::Layer1 => {
            Box::new(PiConstruct::new())
        }
        ConstructLayer::Layer2 => {
            Box::new(DgxConstruct::new())
        }
    }
}
```

---

## Resource Limits by Layer

| Resource | Layer 0 (ESP32) | Layer 1 (Pi/Jetson) | Layer 2 (Cloud) |
|---|---|---|---|
| RAM | 520 KB SRAM | 4-8 GB | 4-64 GB |
| Flash/Disk | 4 MB | 32+ GB SD | 100+ GB |
| CPU | 240 MHz single | 4-6 ARM cores | 2-32 x86 cores |
| GPU | None | 0-1024 CUDA | None or multi-GPU |
| Network | None | WiFi/Ethernet | Full internet |
| Heap | None (no_std) | Yes (alloc) | Yes (std) |
| Async | None | None | Yes (tokio) |
| Skills | Compiled in | Dynamic load | Dynamic load + async tools |
| Max cells | ~279 bytes | ~10K cells | ~1M cells |
| Tick rate | µs | ms | s |

---

*Written 2026-06-04 by synthesis-cocapn-fleet subagent.*
