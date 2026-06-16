//! GINEXUS agent tool-loop (Rust core). Port of the proven Python `brainstem.agent`.
//! The step from answering to DOING: a model-driven, HITL-gated, iteration-capped ReAct loop.

pub mod tools;
pub mod loop_;
pub mod app_tools;

pub use loop_::{AgentLoop, AgentResult, AgentStatus, ApprovalGrant, AssistantTurn, ModelCall, ToolCall};
pub use tools::{Tool, ToolRegistry, ToolResult, notes_registry};
