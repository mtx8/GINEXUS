//! GINEXUS core security primitives (Rust).
//!
//! Ports the proven Python spine (`MTX-NEXUS/backend/src/brainstem/{approval,audit,
//! killswitch,hitl}.py`). The Python test suite and the cross-language **golden vectors**
//! are the behavioral contract — see the parity tests in each module.
//!
//! Rust is the core engine: speed, memory safety, and constant-time crypto by construction.

pub mod approval;
pub mod audit;
pub mod hitl;
pub mod killswitch;
