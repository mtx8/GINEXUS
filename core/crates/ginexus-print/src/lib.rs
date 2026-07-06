//! ginexus-print — the GINEXUS fabrication engine (SP-FAB, SP-Robotics Phase 3).
//! Printer drivers (SDCP / OctoPrint / Moonraker / mock), the pure-Rust mesh gate, the
//! PrusaSlicer+UVtools slice pipeline, the persisted job queue, and the safety-gated fab agent
//! tools. Blocking IO throughout — tools run on the agent loop's spawn_blocking pool, and the
//! `--fab-mcp` stdio server has no async runtime.

pub mod driver;
pub mod geometry;
pub mod jobs;
pub mod mock;
pub mod moonraker;
pub mod octoprint;
pub mod persist;
pub mod pipeline;
pub mod registry;
pub mod sdcp {
    pub mod client;
    pub mod codec;
}
pub mod tools;

pub use tools::{fab_tools, FabState};
