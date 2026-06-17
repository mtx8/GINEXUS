//! Model-driven agent loop (Rust core). Port of `agent/loop.py`.
//! model → tool-calls? → execute (HITL-gated) → feed results back → iterate → final answer.
//! Guard rails: iteration ceiling; irreversible tools require a single-use approval token
//! (ginexus-security) unless default-confirm-allow-listed; read-only tools run autonomously.

use crate::tools::ToolRegistry;
use async_trait::async_trait;
use ginexus_security::approval::ApprovalVerifier;
use ginexus_security::hitl::{Action, HitlPolicy};
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

#[derive(Clone, Debug, Default)]
pub struct AssistantTurn {
    pub content: Option<String>,
    pub tool_calls: Vec<ToolCall>,
}

#[async_trait]
pub trait ModelCall: Send + Sync {
    async fn call(&self, messages: &[Value], tools: &[Value]) -> AssistantTurn;
}

pub struct ApprovalGrant {
    pub action: String,
    pub args: Value,
    pub target: String,
    pub token: String,
    pub nonce: String,
    pub expiry_ms: i64,
    pub boot_id: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum AgentStatus {
    Final,
    PendingApproval,
    MaxIters,
}

pub struct AgentResult {
    pub status: AgentStatus,
    pub answer: String,
    pub pending: Option<Value>,
    pub trace: Vec<(String, bool)>,
}

fn target_of(name: &str, args: &Value) -> String {
    args.get("name")
        .and_then(|v| v.as_str())
        .or_else(|| args.get("target").and_then(|v| v.as_str()))
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("tool:{name}"))
}

fn tool_msg(call_id: &str, output: &str) -> Value {
    json!({"role": "tool", "tool_call_id": call_id, "content": output})
}

/// Max delegation depth: the top agent may delegate; a subagent may not delegate further. Bounds
/// the recursion (no runaway fan-out / infinite spawning).
pub const MAX_DELEGATE_DEPTH: usize = 1;
/// Max sub-tasks per delegate call (caps fan-out).
const MAX_SUBTASKS: usize = 4;

/// Autonomy mode (per request/agent).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Human-in-the-loop (default): every irreversible tool requires approval.
    Hitl,
    /// Fully autonomous: irreversible tools run unattended — EXCEPT hard-gated ones (money /
    /// external comms / legal / irreversible delete / arbitrary execution), which always gate.
    Autonomous,
}

pub struct AgentLoop<'a> {
    pub model: &'a dyn ModelCall,
    pub registry: &'a ToolRegistry,
    pub hitl: &'a HitlPolicy,
    pub max_iters: usize,
    /// Delegation depth (0 = top-level agent). Subagents run at depth+1 and can't delegate at MAX.
    pub depth: usize,
    /// Autonomy mode for this run.
    pub mode: Mode,
}

/// The synthetic `delegate` tool the loop advertises (handled by the loop itself, not the registry).
fn delegate_def() -> Value {
    json!({"type": "function", "function": {
        "name": "delegate",
        "description": "Delegate focused sub-task(s) to fresh worker agents — each gets its own clean \
                        context and the read-only tools (web_fetch, recall, system_status, …) and returns \
                        a result. Use to decompose a complex job or research several things at once. Pass \
                        'tasks' (array of self-contained instructions) or a single 'task'.",
        "parameters": {"type": "object", "properties": {
            "tasks": {"type": "array", "items": {"type": "string"}},
            "task": {"type": "string"}}}
    }})
}

impl<'a> AgentLoop<'a> {
    pub async fn run(
        &self,
        messages: Vec<Value>,
        grants: &[ApprovalGrant],
        approvals: Option<&ApprovalVerifier>,
        now_ms: i64,
    ) -> AgentResult {
        let mut msgs = messages;
        let mut trace: Vec<(String, bool)> = Vec::new();

        // Subagent delegation: advertise + handle `delegate` only below the depth ceiling. Workers
        // get a READ-ONLY registry (they can never perform an irreversible/HITL action on their own).
        let can_delegate = self.depth < MAX_DELEGATE_DEPTH;
        let sub_registry = if can_delegate { Some(self.registry.readonly()) } else { None };
        let mut defs = self.registry.definitions();
        if can_delegate {
            defs.push(delegate_def());
        }

        for _ in 0..self.max_iters {
            let turn = self.model.call(&msgs, &defs).await;
            if turn.tool_calls.is_empty() {
                return AgentResult {
                    status: AgentStatus::Final,
                    answer: turn.content.unwrap_or_default(),
                    pending: None,
                    trace,
                };
            }

            let tcs: Vec<Value> = turn
                .tool_calls
                .iter()
                .map(|tc| {
                    json!({"id": tc.id, "type": "function",
                           "function": {"name": tc.name, "arguments": tc.arguments.to_string()}})
                })
                .collect();
            msgs.push(json!({"role": "assistant",
                             "content": turn.content.clone().unwrap_or_default(),
                             "tool_calls": tcs}));

            for tc in &turn.tool_calls {
                // Delegation is handled by the loop itself (spawns a sub-agent), not the registry.
                if can_delegate && tc.name == "delegate" {
                    let out = self
                        .run_delegate(&tc.arguments, sub_registry.as_ref().unwrap(), now_ms)
                        .await;
                    trace.push(("delegate".to_string(), true));
                    msgs.push(tool_msg(&tc.id, &out));
                    continue;
                }
                let tool = match self.registry.get(&tc.name) {
                    Some(t) => t,
                    None => {
                        trace.push(("unknown_tool".to_string(), false));
                        msgs.push(tool_msg(&tc.id, &format!("error: unknown tool {}", tc.name)));
                        continue;
                    }
                };
                let target = target_of(&tc.name, &tc.arguments);
                // HITL mode gates every irreversible tool; autonomous mode gates only hard-gated
                // ones (money/comms/legal/delete/arbitrary-exec) — the non-overridable hard gate.
                let needs_approval = tool.irreversible
                    && self.hitl.requires_confirmation(&Action::new(tc.name.clone(), target.clone()))
                    && (self.mode == Mode::Hitl || tool.hard_gate);
                if needs_approval {
                    let mut ok = false;
                    if let Some(v) = approvals {
                        for g in grants {
                            if g.action == tc.name && g.args == tc.arguments && g.target == target {
                                ok = v
                                    .verify(&g.token, &g.action, &g.args, &g.target, &g.nonce,
                                            g.expiry_ms, &g.boot_id, now_ms)
                                    .is_ok();
                                break;
                            }
                        }
                    }
                    if !ok {
                        return AgentResult {
                            status: AgentStatus::PendingApproval,
                            answer: String::new(),
                            pending: Some(json!({
                                "tool": tc.name, "arguments": tc.arguments, "target": target,
                                "preview": format!("{}({})", tc.name, tc.arguments),
                            })),
                            trace,
                        };
                    }
                }
                // Run the tool on the blocking pool — file/network tools must not block the loop.
                let runner = tool.runner();
                let args = tc.arguments.clone();
                let res = tokio::task::spawn_blocking(move || runner(args))
                    .await
                    .unwrap_or_else(|_| crate::tools::ToolResult::err("tool execution failed"));
                trace.push((tc.name.clone(), res.ok));
                msgs.push(tool_msg(&tc.id, &res.output));
            }
        }

        AgentResult {
            status: AgentStatus::MaxIters,
            answer: "(stopped: reached max iterations)".to_string(),
            pending: None,
            trace,
        }
    }

    /// Run sub-task(s) as fresh worker agents (own clean context, read-only tools, depth+1) and
    /// return their results. Sequential; recursion is depth-bounded (MAX_DELEGATE_DEPTH) so the
    /// boxed future is finite. Workers get no approvals (read-only registry → nothing to gate).
    async fn run_delegate(&self, args: &Value, sub_registry: &ToolRegistry, now_ms: i64) -> String {
        let tasks: Vec<String> = match args.get("tasks").and_then(|t| t.as_array()) {
            Some(arr) => arr.iter().filter_map(|t| t.as_str().map(str::to_string)).collect(),
            None => args
                .get("task")
                .and_then(|t| t.as_str())
                .map(|s| vec![s.to_string()])
                .unwrap_or_default(),
        };
        if tasks.is_empty() {
            return "error: delegate requires 'task' (string) or 'tasks' (array of strings)".into();
        }
        let mut out = String::new();
        for (i, task) in tasks.into_iter().take(MAX_SUBTASKS).enumerate() {
            let sub = AgentLoop {
                model: self.model,
                registry: sub_registry,
                hitl: self.hitl,
                max_iters: self.max_iters.min(4),
                depth: self.depth + 1,
                mode: Mode::Hitl, // workers are read-only; mode is moot, Hitl is the safe default
            };
            let msgs = vec![json!({"role": "user", "content": &task})];
            // Box the recursive call so the returned future has a finite size.
            let res = Box::pin(sub.run(msgs, &[], None, now_ms)).await;
            out.push_str(&format!("[subagent {}] {} → {}\n\n", i + 1, task, res.answer.trim()));
        }
        out.trim_end().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::notes_registry;
    use ginexus_security::approval::mint;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    static CTR: AtomicU64 = AtomicU64::new(0);
    fn tmp_dir() -> PathBuf {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let d = std::env::temp_dir().join(format!(
            "ginexus-agent-{}-{}-{}",
            std::process::id(), n, CTR.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }
    fn key() -> Vec<u8> {
        (0u8..32).collect()
    }
    const BOOT: &str = "boot-agent";
    const NOW: i64 = 1_000_000;
    const EXP: i64 = 1_060_000;

    struct Mock {
        turns: Vec<AssistantTurn>,
        idx: Mutex<usize>,
    }
    impl Mock {
        fn new(turns: Vec<AssistantTurn>) -> Self {
            Self { turns, idx: Mutex::new(0) }
        }
    }
    #[async_trait]
    impl ModelCall for Mock {
        async fn call(&self, _m: &[Value], _t: &[Value]) -> AssistantTurn {
            let mut i = self.idx.lock().unwrap();
            let turn = self.turns[(*i).min(self.turns.len() - 1)].clone();
            *i += 1;
            turn
        }
    }

    fn tc(name: &str, args: Value) -> ToolCall {
        ToolCall { id: "c1".into(), name: name.into(), arguments: args }
    }
    fn final_turn(s: &str) -> AssistantTurn {
        AssistantTurn { content: Some(s.into()), tool_calls: vec![] }
    }
    fn call_turn(tc: ToolCall) -> AssistantTurn {
        AssistantTurn { content: None, tool_calls: vec![tc] }
    }

    #[tokio::test]
    async fn readonly_tool_runs_without_approval() {
        let dir = tmp_dir();
        let reg = notes_registry(dir.clone());
        reg.get("write_note").unwrap().run(json!({"name": "n", "content": "hello world"}));
        let model = Mock::new(vec![
            call_turn(tc("read_note", json!({"name": "n"}))),
            final_turn("The note says: hello world"),
        ]);
        let hitl = HitlPolicy::new();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![json!({"role": "user", "content": "read n"})], &[], None, NOW).await;
        assert_eq!(res.status, AgentStatus::Final);
        assert!(res.answer.contains("hello world"));
        assert!(res.trace.contains(&("read_note".to_string(), true)));
    }

    #[tokio::test]
    async fn irreversible_without_grant_pends() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        let model = Mock::new(vec![call_turn(tc("write_note", json!({"name": "x", "content": "d"})))]);
        let hitl = HitlPolicy::new();
        let av = ApprovalVerifier::new(key(), BOOT).unwrap();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![], &[], Some(&av), NOW).await;
        assert_eq!(res.status, AgentStatus::PendingApproval);
        assert_eq!(res.pending.unwrap()["tool"], "write_note");
    }

    #[tokio::test]
    async fn irreversible_with_grant_executes() {
        let dir = tmp_dir();
        let reg = notes_registry(dir.clone());
        let args = json!({"name": "x", "content": "data"});
        let tok = mint(&key(), "write_note", &args, "x", "n1", EXP, BOOT).unwrap();
        let grant = ApprovalGrant {
            action: "write_note".into(), args: args.clone(), target: "x".into(),
            token: tok, nonce: "n1".into(), expiry_ms: EXP, boot_id: BOOT.into(),
        };
        let model = Mock::new(vec![call_turn(tc("write_note", args)), final_turn("saved")]);
        let hitl = HitlPolicy::new();
        let av = ApprovalVerifier::new(key(), BOOT).unwrap();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![], &[grant], Some(&av), NOW).await;
        assert_eq!(res.status, AgentStatus::Final);
        assert_eq!(res.answer, "saved");
        let read = reg.get("read_note").unwrap().run(json!({"name": "x"}));
        assert_eq!(read.output, "data");
    }

    #[tokio::test]
    async fn iteration_ceiling_enforced() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        let model = Mock::new(vec![call_turn(tc("read_note", json!({"name": "n"})))]); // never finals
        let hitl = HitlPolicy::new();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 3, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![], &[], None, NOW).await;
        assert_eq!(res.status, AgentStatus::MaxIters);
    }

    #[tokio::test]
    async fn unknown_tool_recovers() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        let model = Mock::new(vec![
            call_turn(tc("nonexistent", json!({}))),
            final_turn("recovered"),
        ]);
        let hitl = HitlPolicy::new();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![], &[], None, NOW).await;
        assert_eq!(res.status, AgentStatus::Final);
        assert_eq!(res.answer, "recovered");
        assert!(res.trace.contains(&("unknown_tool".to_string(), false)));
    }

    #[tokio::test]
    async fn delegate_spawns_a_subagent() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        // Shared Mock advances: parent(0)→delegate, subagent(1)→final, parent(2)→final.
        let model = Mock::new(vec![
            call_turn(tc("delegate", json!({"task": "find the answer"}))),
            final_turn("the answer is 42"),
            final_turn("Done — a subagent reported: 42"),
        ]);
        let hitl = HitlPolicy::new();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![json!({"role": "user", "content": "do it"})], &[], None, NOW).await;
        assert_eq!(res.status, AgentStatus::Final);
        assert!(res.trace.iter().any(|(n, _)| n == "delegate"));
        assert!(res.answer.contains("42"));
    }

    #[tokio::test]
    async fn subagent_cannot_delegate_further() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        // At the depth ceiling, `delegate` is neither advertised nor handled → treated as an
        // unknown tool, and the agent recovers. (Bounds the recursion.)
        let model = Mock::new(vec![
            call_turn(tc("delegate", json!({"task": "x"}))),
            final_turn("recovered"),
        ]);
        let hitl = HitlPolicy::new();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: MAX_DELEGATE_DEPTH, mode: Mode::Hitl };
        let res = loop_.run(vec![], &[], None, NOW).await;
        assert_eq!(res.status, AgentStatus::Final);
        assert_eq!(res.answer, "recovered");
        assert!(res.trace.contains(&("unknown_tool".to_string(), false)));
    }

    #[tokio::test]
    async fn autonomous_runs_ordinary_irreversible_without_approval() {
        let dir = tmp_dir();
        let reg = notes_registry(dir.clone());
        let args = json!({"name": "x", "content": "data"});
        let model = Mock::new(vec![call_turn(tc("write_note", args)), final_turn("saved")]);
        let hitl = HitlPolicy::new();
        let av = ApprovalVerifier::new(key(), BOOT).unwrap();
        // write_note is irreversible but NOT hard-gated → autonomous mode runs it unattended.
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Autonomous };
        let res = loop_.run(vec![], &[], Some(&av), NOW).await;
        assert_eq!(res.status, AgentStatus::Final);
        assert_eq!(res.answer, "saved");
        assert_eq!(reg.get("read_note").unwrap().run(json!({"name": "x"})).output, "data");
    }

    #[tokio::test]
    async fn autonomous_still_gates_hard_gate_tool() {
        let dir = tmp_dir();
        let mut reg = notes_registry(dir.clone());
        reg.register(crate::tools::terminal_tool(dir, vec!["echo".to_string()])); // hard_gated
        let model = Mock::new(vec![call_turn(tc("run_command", json!({"program": "echo", "args": ["hi"]})))]);
        let hitl = HitlPolicy::new();
        let av = ApprovalVerifier::new(key(), BOOT).unwrap();
        // Even in autonomous mode, the hard gate (arbitrary execution) requires approval.
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Autonomous };
        let res = loop_.run(vec![], &[], Some(&av), NOW).await;
        assert_eq!(res.status, AgentStatus::PendingApproval);
    }
}
