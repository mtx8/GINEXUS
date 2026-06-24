//! GINEXUS agent tool-loop (Rust core). Port of the proven Python `brainstem.agent`.
//! The step from answering to DOING: a model-driven, HITL-gated, iteration-capped ReAct loop.

pub mod tools;
pub mod loop_;
pub mod app_tools;
pub mod obsidian;
pub mod documents;
pub mod robotics;

pub use loop_::{AgentLoop, AgentResult, AgentStatus, ApprovalGrant, AssistantTurn, Mode, ModelCall, ToolCall, Usage};
pub use tools::{Tool, ToolRegistry, ToolResult, notes_registry};

/// Replace the user's home-directory prefix with `~` so tool output (and the model's echo of it)
/// never leaks the macOS username or absolute home path. Privacy-by-default — the operator can still
/// ask for the full path explicitly.
pub fn abbreviate_home(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) => abbreviate_with(path, &home),
        Err(_) => path.to_string(),
    }
}

fn abbreviate_with(path: &str, home: &str) -> String {
    let home = home.trim_end_matches('/');
    // Only a true path-component prefix (avoid "/Users/tom" matching "/Users/tommy").
    if !home.is_empty() && (path == home || path.starts_with(&format!("{home}/"))) {
        return format!("~{}", &path[home.len()..]);
    }
    path.to_string()
}

#[cfg(test)]
mod privacy_tests {
    use super::abbreviate_with;
    #[test]
    fn abbreviates_home_to_tilde() {
        assert_eq!(abbreviate_with("/Users/tom/Downloads/x.pdf", "/Users/tom"), "~/Downloads/x.pdf");
        assert_eq!(abbreviate_with("/Users/tom", "/Users/tom"), "~");
        assert_eq!(abbreviate_with("/Users/tom/", "/Users/tom"), "~/");
        assert_eq!(abbreviate_with("/opt/data/x", "/Users/tom"), "/opt/data/x"); // outside home untouched
        assert_eq!(abbreviate_with("/Users/tommy/x", "/Users/tom"), "/Users/tommy/x"); // no false prefix
    }
}
