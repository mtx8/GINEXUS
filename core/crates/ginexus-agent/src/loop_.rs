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
    /// Token usage for THIS model call, as reported by the model server (OpenAI-compatible
    /// `usage`). Zero when the server doesn't report it (e.g. mocks) — never fabricated.
    pub usage: Usage,
}

/// Token usage. `total` is derived (`prompt + completion`), so only two real fields are stored.
/// `u64` (not u32) so a long-context or always-on run can never silently truncate the count.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Usage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

impl Usage {
    /// Saturating accumulation — token counts only ever grow across a run.
    pub fn add(&mut self, other: Usage) {
        self.prompt_tokens = self.prompt_tokens.saturating_add(other.prompt_tokens);
        self.completion_tokens = self.completion_tokens.saturating_add(other.completion_tokens);
    }
    pub fn total_tokens(&self) -> u64 {
        self.prompt_tokens.saturating_add(self.completion_tokens)
    }
}

#[async_trait]
pub trait ModelCall: Send + Sync {
    async fn call(&self, messages: &[Value], tools: &[Value]) -> AssistantTurn;
    /// Streaming variant: forward each content delta to `on_token` as it arrives, returning the
    /// assembled turn. `on_event(tool, phase)` lets the binding report a tool the model is ABOUT to
    /// call ("intent") as soon as its name is known — before the (possibly long) arguments finish —
    /// so the UI can show "Creating document / Generating image …" for the whole time it's working.
    /// Default just calls `call` then emits the whole content once (no intent) — so mocks and the
    /// non-streaming path work unchanged; real model bindings override this to truly stream.
    async fn call_streaming(
        &self,
        messages: &[Value],
        tools: &[Value],
        on_token: &(dyn Fn(String) + Send + Sync),
        _on_event: &(dyn Fn(String, String) + Send + Sync),
    ) -> AssistantTurn {
        let turn = self.call(messages, tools).await;
        if let Some(c) = &turn.content {
            if !c.is_empty() {
                on_token(c.clone());
            }
        }
        turn
    }
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
    /// Aggregated token usage across EVERY model call in this run — main-loop iterations plus the
    /// synthetic delegate / council / deep_research fan-outs and all of their workers.
    pub total_usage: Usage,
    /// Result of the LAST in-loop context compaction this run performed (zeroed if the conversation
    /// never crossed the budget). Lets the UI show a context meter and a "trimmed" indicator.
    pub compaction: crate::context_compress::CompactionStats,
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
/// Per-RUN budget for EXPENSIVE synthetic tools (delegate / council / deep_research). Each of these
/// fans out into many model calls (e.g. deep_research ≈ 1 + N workers×iters + 1), so without a cap a
/// single turn emitting several of them could multiply into hundreds of model calls. The internal
/// caps (MAX_SUBTASKS, MAX_COUNCIL) bound each CALL; this bounds the COUNT of calls across the run.
const MAX_SYNTHETIC_CALLS: usize = 3;

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

/// Max council members per convening (caps cost: N opinions + 1 synthesis model calls).
const MAX_COUNCIL: usize = 5;

/// Default council — deliberately DIVERGENT lenses so the members disagree productively. Diversity
/// comes from the system prompt (deterministic even at temperature 0: each member sees a different
/// prompt → a different answer).
fn default_personas() -> Vec<(String, String)> {
    vec![
        ("Analyst".into(),
         "You are a rigorous analyst. Reason step by step, make your assumptions explicit, and \
          prioritize correctness, evidence, and precision.".into()),
        ("Strategist".into(),
         "You are a creative strategist. Explore non-obvious angles, alternatives, trade-offs, and \
          second-order effects that others overlook.".into()),
        ("Skeptic".into(),
         "You are a hard skeptic. Stress-test the question: surface risks, failure modes, hidden \
          assumptions, and the strongest counter-arguments.".into()),
    ]
}

/// Resolve the council roster: custom persona names (known ones get their rich prompt; unknown ones
/// a generic expert frame), else the default trio. Capped at MAX_COUNCIL.
fn select_personas(custom: Option<&Vec<Value>>) -> Vec<(String, String)> {
    match custom {
        Some(arr) if arr.iter().any(|v| v.is_string()) => {
            let known = default_personas();
            arr.iter()
                .filter_map(|v| v.as_str())
                .take(MAX_COUNCIL)
                .map(|name| {
                    let lname = name.to_lowercase();
                    known
                        .iter()
                        .find(|(n, _)| n.to_lowercase() == lname)
                        .cloned()
                        .unwrap_or_else(|| {
                            (name.to_string(),
                             format!("You are {name}. Give your sharpest, most distinctive expert \
                                      perspective on the question."))
                        })
                })
                .collect()
        }
        _ => default_personas(),
    }
}

/// The synthetic `council` tool: convene a panel of personas to deliberate a hard question in
/// parallel, then synthesize. Handled by the loop (uses the bound model directly), like `delegate`.
fn council_def() -> Value {
    json!({"type": "function", "function": {
        "name": "council",
        "description": "Convene a council of expert personas (Analyst, Strategist, Skeptic by \
                        default) to deliberate a hard question IN PARALLEL, then synthesize their \
                        best combined answer. Use for high-stakes, ambiguous, or multi-faceted \
                        questions where one perspective is risky. Pass 'question' and optionally \
                        'personas' (array of role names).",
        "parameters": {"type": "object", "properties": {
            "question": {"type": "string"},
            "personas": {"type": "array", "items": {"type": "string"}}},
            "required": ["question"]}
    }})
}

/// Best-effort extract a JSON array of non-empty strings from model output (tolerates prose or a
/// ```json fence around it by slicing the outermost `[` … `]`).
fn parse_string_array(s: &str) -> Option<Vec<String>> {
    let start = s.find('[')?;
    let end = s.rfind(']')?;
    if end <= start {
        return None;
    }
    let arr: Value = serde_json::from_str(&s[start..=end]).ok()?;
    let v: Vec<String> = arr
        .as_array()?
        .iter()
        .filter_map(|x| x.as_str().map(str::to_string))
        .filter(|x| !x.trim().is_empty())
        .collect();
    (!v.is_empty()).then_some(v)
}

/// The synthetic `deep_research` tool (handled by the loop): decompose → parallel research → report.
fn deep_research_def() -> Value {
    json!({"type": "function", "function": {
        "name": "deep_research",
        "description": "Conduct DEEP RESEARCH on a question: decompose it into sub-questions, \
                        investigate each IN PARALLEL with fresh worker agents (web search/fetch + \
                        memory recall), then synthesize a cited report. Use for open-ended questions \
                        that need multiple sources or angles. Pass 'question'.",
        "parameters": {"type": "object",
                       "properties": {"question": {"type": "string"}},
                       "required": ["question"]}
    }})
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
    /// Non-streaming entry point — a thin wrapper over `run_streaming` with no-op callbacks, so the
    /// whole agent loop lives in ONE place (and all existing callers/tests are unchanged).
    pub async fn run(
        &self,
        messages: Vec<Value>,
        grants: &[ApprovalGrant],
        approvals: Option<&ApprovalVerifier>,
        now_ms: i64,
    ) -> AgentResult {
        self.run_streaming(messages, grants, approvals, now_ms, &|_| {}, &|_, _| {}).await
    }

    /// Streaming entry point: identical agent logic, but forwards content tokens to `on_token` as
    /// the model emits them, and reports tool activity via `on_event(tool_name, phase)` where phase
    /// is "start" or "done". Content from a tool-calling turn streams too (model "thinking"); the
    /// client resets its buffer on a tool event so only the final answer remains. `run` passes
    /// no-op callbacks. Sub-agents (workers) go through `run` → no-op, so only the TOP loop streams.
    #[allow(clippy::too_many_arguments)]
    pub async fn run_streaming(
        &self,
        messages: Vec<Value>,
        grants: &[ApprovalGrant],
        approvals: Option<&ApprovalVerifier>,
        now_ms: i64,
        on_token: &(dyn Fn(String) + Send + Sync),
        on_event: &(dyn Fn(String, String) + Send + Sync),
    ) -> AgentResult {
        let mut msgs = messages;
        let mut trace: Vec<(String, bool)> = Vec::new();
        // Per-run budget consumed by delegate / council / deep_research (the multiplicative tools).
        let mut synthetic_used: usize = 0;
        // Real token usage accumulated across every model call this run makes.
        let mut total_usage = Usage::default();
        // Deterministic, no-LLM context compaction config (env-overridable). Applied before each
        // model call so a long agentic turn never overflows the local model's context window.
        let compaction_cfg = crate::context_compress::CompactionConfig::from_env();
        let mut compaction = crate::context_compress::CompactionStats::default();

        // Subagent delegation: advertise + handle `delegate` only below the depth ceiling. Workers
        // get a READ-ONLY registry (they can never perform an irreversible/HITL action on their own).
        let can_delegate = self.depth < MAX_DELEGATE_DEPTH;
        // Council is top-level only: a worker never convenes its own council (bounds total cost).
        let can_council = self.depth == 0;
        let sub_registry = if can_delegate { Some(self.registry.readonly()) } else { None };
        let mut defs = self.registry.definitions();
        if can_delegate {
            defs.push(delegate_def());
            defs.push(deep_research_def()); // also spawns workers → same depth gate as delegate
        }
        if can_council {
            defs.push(council_def());
        }

        for _ in 0..self.max_iters {
            // Keep the running transcript within the model's context budget BEFORE the call. A no-op
            // (single vector walk) while the conversation is small; only mutates once it overflows.
            let step = crate::context_compress::compact(&mut msgs, &compaction_cfg);
            if step.changed() {
                compaction = step;
            }
            let turn = self.model.call_streaming(&msgs, &defs, on_token, on_event).await;
            total_usage.add(turn.usage);
            if turn.tool_calls.is_empty() {
                return AgentResult {
                    status: AgentStatus::Final,
                    answer: turn.content.unwrap_or_default(),
                    pending: None,
                    trace,
                    total_usage,
                    compaction,
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
                // Synthetic tools (delegate / deep_research / council) are handled by the loop itself,
                // not the registry. Each fans out into many model calls, so they share a per-run
                // budget: once exhausted, further such calls are refused (the loop keeps going and the
                // model must answer from what it has) — bounds total cost against a runaway turn.
                let is_synthetic = (can_delegate && (tc.name == "delegate" || tc.name == "deep_research"))
                    || (can_council && tc.name == "council");
                if is_synthetic {
                    if synthetic_used >= MAX_SYNTHETIC_CALLS {
                        trace.push((tc.name.clone(), false));
                        msgs.push(tool_msg(
                            &tc.id,
                            &format!(
                                "error: this run's budget of {MAX_SYNTHETIC_CALLS} delegate/council/\
                                 deep_research calls is exhausted — answer using the results already \
                                 gathered, or use a single regular tool."
                            ),
                        ));
                        continue;
                    }
                    synthetic_used += 1;
                    on_event(tc.name.clone(), "start".into());
                    let (out, syn_usage) = match tc.name.as_str() {
                        "delegate" => {
                            self.run_delegate(&tc.arguments, sub_registry.as_ref().unwrap(), now_ms).await
                        }
                        "deep_research" => {
                            self.run_deep_research(&tc.arguments, sub_registry.as_ref().unwrap(), now_ms)
                                .await
                        }
                        _ => self.run_council(&tc.arguments).await, // "council"
                    };
                    total_usage.add(syn_usage);
                    on_event(tc.name.clone(), "done".into());
                    trace.push((tc.name.clone(), true));
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
                            total_usage,
                            compaction,
                        };
                    }
                }
                // Run the tool on the blocking pool — file/network tools must not block the loop.
                on_event(tc.name.clone(), "start".into());
                let runner = tool.runner();
                let args = tc.arguments.clone();
                let res = tokio::task::spawn_blocking(move || runner(args))
                    .await
                    .unwrap_or_else(|_| crate::tools::ToolResult::err("tool execution failed"));
                on_event(tc.name.clone(), "done".into());
                trace.push((tc.name.clone(), res.ok));
                msgs.push(tool_msg(&tc.id, &res.output));
            }
        }

        AgentResult {
            status: AgentStatus::MaxIters,
            answer: "(stopped: reached max iterations)".to_string(),
            pending: None,
            trace,
            total_usage,
            compaction,
        }
    }

    /// Run `tasks` as fresh worker agents (own clean context, read-only tools, depth+1), CONCURRENTLY.
    /// Returns each worker's trimmed answer in INPUT ORDER. Shared by `delegate` and `deep_research`.
    ///
    /// Concurrency: the workers run together (`join_all`) — model calls are I/O-bound, so while one
    /// awaits the model another fires its request; wall-clock is the slowest worker, not the sum.
    /// Each worker future is boxed (heap indirection breaks the recursive run→worker→run type into a
    /// finite size). The futures stay CONCRETE (not `dyn … + Send`): all worker blocks share one
    /// anonymous type, so auto-trait inference propagates Send through the recursion concretely — a
    /// `dyn … + Send` cast can't (its Send bound is circular through the recursion), and the server's
    /// multi-thread runtime needs the loop future to be Send. Workers get the read-only registry + no
    /// approvals (nothing to gate); safe to run unattended.
    async fn run_workers(
        &self, tasks: &[String], sub_registry: &ToolRegistry, now_ms: i64,
    ) -> (Vec<String>, Usage) {
        // System brief for every fan-out worker — the dedicated GINEXUS research agents (Nexus RND/STR).
        // Drives safe, source-grounded investigation: discover with web_search, read with web_fetch,
        // prefer primary/official sources, cite URLs, never fabricate. (PSS: factual, no invented cites.)
        const WORKER_SYSTEM: &str =
            "You are a GINEXUS research worker — one of the Nexus research agents (RND/STR). Investigate \
             your task rigorously: call web_search to find current, reputable sources, then web_fetch to \
             read the most relevant ones; prefer primary/official sources and cross-check key claims. Be \
             concise and factual, list the source URLs you actually used, and flag uncertainty honestly. \
             Never fabricate facts or citations.";
        // One worker AgentLoop per task, kept in a Vec that outlives the join so each worker future
        // can borrow its loop (run takes &self) across the concurrent await.
        let subs: Vec<AgentLoop> = (0..tasks.len())
            .map(|_| AgentLoop {
                model: self.model,
                registry: sub_registry,
                hitl: self.hitl,
                max_iters: self.max_iters.min(4),
                depth: self.depth + 1,
                mode: Mode::Hitl, // workers are read-only; mode is moot, Hitl is the safe default
            })
            .collect();
        let futs: Vec<_> = subs
            .iter()
            .zip(tasks.iter())
            .map(|(sub, task)| {
                let msgs = vec![
                    json!({"role": "system", "content": WORKER_SYSTEM}),
                    json!({"role": "user", "content": task}),
                ];
                Box::pin(async move {
                    let res = sub.run(msgs, &[], None, now_ms).await;
                    (res.answer.trim().to_string(), res.total_usage)
                })
            })
            .collect();
        let results = futures_util::future::join_all(futs).await;
        // Roll each worker's full run usage up into the fan-out total (workers go through `run`,
        // which itself accumulates their internal calls).
        let mut usage = Usage::default();
        let answers = results
            .into_iter()
            .map(|(ans, u)| {
                usage.add(u);
                ans
            })
            .collect();
        (answers, usage)
    }

    /// `delegate`: split a job into sub-tasks and run fresh workers on them concurrently. Output
    /// preserves task order. Fan-out is capped (MAX_SUBTASKS).
    async fn run_delegate(
        &self, args: &Value, sub_registry: &ToolRegistry, now_ms: i64,
    ) -> (String, Usage) {
        let tasks: Vec<String> = match args.get("tasks").and_then(|t| t.as_array()) {
            Some(arr) => arr.iter().filter_map(|t| t.as_str().map(str::to_string)).collect(),
            None => args
                .get("task")
                .and_then(|t| t.as_str())
                .map(|s| vec![s.to_string()])
                .unwrap_or_default(),
        };
        if tasks.is_empty() {
            return (
                "error: delegate requires 'task' (string) or 'tasks' (array of strings)".into(),
                Usage::default(),
            );
        }
        let tasks: Vec<String> = tasks.into_iter().take(MAX_SUBTASKS).collect();
        let (answers, usage) = self.run_workers(&tasks, sub_registry, now_ms).await;
        let out = tasks
            .iter()
            .zip(answers.iter())
            .enumerate()
            .map(|(i, (task, ans))| format!("[subagent {}] {} → {}\n\n", i + 1, task, ans))
            .collect::<String>()
            .trim_end()
            .to_string();
        (out, usage)
    }

    /// `deep_research`: decompose a question into focused sub-questions, investigate each in parallel
    /// with fresh web-enabled workers, then synthesize a cited report. The flagship research flow —
    /// decompose (1 call) → concurrent worker research → synthesize (1 call).
    async fn run_deep_research(
        &self, args: &Value, sub_registry: &ToolRegistry, now_ms: i64,
    ) -> (String, Usage) {
        let question = args.get("question").and_then(|q| q.as_str()).unwrap_or("").trim();
        if question.is_empty() {
            return ("error: deep_research requires 'question' (string)".into(), Usage::default());
        }
        let mut usage = Usage::default();
        // 1 — decompose into independent sub-questions (fall back to the question itself).
        let decompose = format!(
            "Break this research question into 3-5 focused, independent sub-questions that together \
             fully cover it. Return ONLY a JSON array of strings.\n\nQuestion: {question}"
        );
        let turn = self.model.call(&[json!({"role": "user", "content": decompose})], &[]).await;
        usage.add(turn.usage);
        let subqs = turn
            .content
            .as_deref()
            .and_then(parse_string_array)
            .unwrap_or_else(|| vec![question.to_string()]);
        let subqs: Vec<String> = subqs.into_iter().take(MAX_SUBTASKS).collect();

        // 2 — research each sub-question concurrently (workers have read-only web/recall tools).
        let (findings, worker_usage) = self.run_workers(&subqs, sub_registry, now_ms).await;
        usage.add(worker_usage);

        // 3 — synthesize a cited report from the findings.
        let mut prompt = format!(
            "You are a research analyst. Research question:\n\n{question}\n\nFindings from \
             parallel sub-investigations:\n"
        );
        for (q, f) in subqs.iter().zip(findings.iter()) {
            prompt.push_str(&format!("\n### {q}\n{}\n", f.trim()));
        }
        prompt.push_str(
            "\nWrite a clear, well-structured report that answers the research question, drawing on \
             and citing the findings above. Flag any gaps or uncertainty honestly.",
        );
        let report = self.model.call(&[json!({"role": "user", "content": prompt})], &[]).await;
        usage.add(report.usage);
        (report.content.unwrap_or_default(), usage)
    }

    /// Convene a council: gather N persona-diverse opinions CONCURRENTLY on the bound model, then
    /// synthesize the single best answer. Pure reasoning (no tools) → read-only/autonomous. Members
    /// run in parallel (`join_all`), so wall-clock is ~2 calls (opinions phase + synthesis), not N+1.
    async fn run_council(&self, args: &Value) -> (String, Usage) {
        let question = args.get("question").and_then(|q| q.as_str()).unwrap_or("").trim();
        if question.is_empty() {
            return ("error: council requires 'question' (string)".into(), Usage::default());
        }
        let personas = select_personas(args.get("personas").and_then(|p| p.as_array()));
        let mut usage = Usage::default();

        // Phase 1 — gather independent opinions concurrently (each member sees only its persona).
        let futs: Vec<_> = personas
            .iter()
            .map(|(name, sys)| {
                let msgs = vec![
                    json!({"role": "system", "content": sys}),
                    json!({"role": "user", "content": question}),
                ];
                Box::pin(async move {
                    let turn = self.model.call(&msgs, &[]).await;
                    (name.clone(), turn.content.unwrap_or_default(), turn.usage)
                })
            })
            .collect();
        let results = futures_util::future::join_all(futs).await;
        let opinions: Vec<(String, String)> = results
            .into_iter()
            .map(|(name, content, u)| {
                usage.add(u);
                (name, content)
            })
            .collect();

        // Phase 2 — synthesize. The chair sees the question + every member's opinion.
        let mut prompt = format!(
            "You are the chair of an expert council deliberating this question:\n\n{question}\n\n\
             The members gave independent opinions:\n"
        );
        for (name, op) in &opinions {
            prompt.push_str(&format!("\n## {name}\n{}\n", op.trim()));
        }
        prompt.push_str(
            "\nSynthesize the single best answer to the question. Reconcile disagreements, combine \
             the strongest reasoning, and briefly note any critical dissent. Answer directly.",
        );
        let synth = self.model.call(&[json!({"role": "user", "content": prompt})], &[]).await;
        usage.add(synth.usage);
        (synth.content.unwrap_or_default(), usage)
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

    /// Concurrency-safe mock: response is a PURE FUNCTION of the messages (no shared counter), so it
    /// behaves deterministically even when workers call it in nondeterministic order under join_all.
    struct RoutingMock;
    #[async_trait]
    impl ModelCall for RoutingMock {
        async fn call(&self, m: &[Value], _t: &[Value]) -> AssistantTurn {
            let blob: String =
                m.iter().filter_map(|x| x["content"].as_str()).collect::<Vec<_>>().join(" ");
            let last = m.last().and_then(|x| x["content"].as_str()).unwrap_or("");
            // Parent's 2nd call: both workers' results are present → synthesize. (Checked FIRST so the
            // task strings echoed in the delegate output don't re-trigger a worker branch.)
            if blob.contains("ALPHA_OK") && blob.contains("BETA_OK") {
                final_turn("both done: ALPHA_OK + BETA_OK")
            } else if last.contains("alpha subtask") {
                final_turn("ALPHA_OK")
            } else if last.contains("beta subtask") {
                final_turn("BETA_OK")
            } else {
                // Parent's 1st call: fan out two concurrent workers.
                call_turn(tc("delegate", json!({"tasks": ["alpha subtask", "beta subtask"]})))
            }
        }
    }

    /// Mock that SLEEPS inside each worker call, to prove fan-out is concurrent (wall-clock = slowest
    /// worker, not the sum). Routes by message shape (no shared counter → concurrency-safe).
    struct SleepMock {
        per_call_ms: u64,
    }
    #[async_trait]
    impl ModelCall for SleepMock {
        async fn call(&self, m: &[Value], _t: &[Value]) -> AssistantTurn {
            let has_tool = m.iter().any(|x| x["role"] == "tool");
            let last = m.last().and_then(|x| x["content"].as_str()).unwrap_or("");
            if has_tool {
                final_turn("done") // parent synthesis after workers return
            } else if last.contains("slow") {
                tokio::time::sleep(std::time::Duration::from_millis(self.per_call_ms)).await;
                final_turn("OK")
            } else {
                call_turn(tc("delegate", json!({"tasks": ["slow1", "slow2", "slow3"]})))
            }
        }
    }

    /// Concurrency-safe council mock: routes purely by message shape. Each persona returns a tagged
    /// opinion; the synthesis call (chair) counts how many opinions it received; the parent's
    /// post-council turn echoes the council result.
    struct CouncilMock;
    #[async_trait]
    impl ModelCall for CouncilMock {
        async fn call(&self, m: &[Value], _t: &[Value]) -> AssistantTurn {
            let sys: String =
                m.iter().filter(|x| x["role"] == "system").filter_map(|x| x["content"].as_str()).collect();
            let usr: String =
                m.iter().filter(|x| x["role"] == "user").filter_map(|x| x["content"].as_str()).collect();
            let has_tool = m.iter().any(|x| x["role"] == "tool");
            if has_tool {
                // Parent's turn after the council returns: echo the synthesized result.
                let tool_out: String = m
                    .iter()
                    .filter(|x| x["role"] == "tool")
                    .filter_map(|x| x["content"].as_str())
                    .collect();
                final_turn(&format!("FINAL[{}]", tool_out))
            } else if usr.contains("chair of an expert council") {
                // Synthesis: prove every member's opinion arrived (count the _VIEW tags).
                let n = usr.matches("_VIEW").count();
                final_turn(&format!("SYNTHESIS(views={n})"))
            } else if sys.contains("rigorous analyst") {
                final_turn("ANALYST_VIEW")
            } else if sys.contains("creative strategist") {
                final_turn("STRATEGIST_VIEW")
            } else if sys.contains("hard skeptic") {
                final_turn("SKEPTIC_VIEW")
            } else {
                // Top-level: convene a council on the user's question.
                call_turn(tc("council", json!({"question": usr})))
            }
        }
    }

    /// Concurrency-safe deep-research mock: routes by content. Top-level → deep_research; decompose
    /// → a JSON array of sub-questions; each worker → a finding; synthesis → counts findings.
    struct ResearchMock;
    #[async_trait]
    impl ModelCall for ResearchMock {
        async fn call(&self, m: &[Value], _t: &[Value]) -> AssistantTurn {
            let usr: String =
                m.iter().filter(|x| x["role"] == "user").filter_map(|x| x["content"].as_str()).collect();
            let has_tool = m.iter().any(|x| x["role"] == "tool");
            if has_tool {
                let out: String = m
                    .iter()
                    .filter(|x| x["role"] == "tool")
                    .filter_map(|x| x["content"].as_str())
                    .collect();
                final_turn(&format!("FINAL[{out}]"))
            } else if usr.contains("research analyst") {
                let n = usr.matches("FOUND_").count();
                final_turn(&format!("REPORT(found={n})"))
            } else if usr.contains("Break this research question") {
                final_turn("here you go: [\"subq alpha\", \"subq beta\", \"subq gamma\"]")
            } else if usr.contains("subq alpha") {
                final_turn("FOUND_ALPHA")
            } else if usr.contains("subq beta") {
                final_turn("FOUND_BETA")
            } else if usr.contains("subq gamma") {
                final_turn("FOUND_GAMMA")
            } else {
                call_turn(tc("deep_research", json!({"question": usr})))
            }
        }
    }

    fn tc(name: &str, args: Value) -> ToolCall {
        ToolCall { id: "c1".into(), name: name.into(), arguments: args }
    }
    fn final_turn(s: &str) -> AssistantTurn {
        AssistantTurn { content: Some(s.into()), tool_calls: vec![], ..Default::default() }
    }
    fn call_turn(tc: ToolCall) -> AssistantTurn {
        AssistantTurn { content: None, tool_calls: vec![tc], ..Default::default() }
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
    async fn usage_accumulates_across_model_calls() {
        // Two model calls in one run: a tool-call turn (10/5) then a final turn (8/12).
        // The loop must report the SUM as total_usage (18/17, total 35) — real counts, summed.
        let dir = tmp_dir();
        let reg = notes_registry(dir.clone());
        reg.get("write_note").unwrap().run(json!({"name": "n", "content": "hello"}));
        let turn1 = AssistantTurn {
            tool_calls: vec![tc("read_note", json!({"name": "n"}))],
            usage: Usage { prompt_tokens: 10, completion_tokens: 5 },
            ..Default::default()
        };
        let turn2 = AssistantTurn {
            content: Some("done".into()),
            usage: Usage { prompt_tokens: 8, completion_tokens: 12 },
            ..Default::default()
        };
        let model = Mock::new(vec![turn1, turn2]);
        let hitl = HitlPolicy::new();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![json!({"role": "user", "content": "read n"})], &[], None, NOW).await;
        assert_eq!(res.status, AgentStatus::Final);
        assert_eq!(res.total_usage.prompt_tokens, 18);
        assert_eq!(res.total_usage.completion_tokens, 17);
        assert_eq!(res.total_usage.total_tokens(), 35);
    }

    #[tokio::test]
    async fn usage_defaults_to_zero_when_unreported() {
        // Mocks report no usage → total stays zero (so the server omits it → app shows an empty state).
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        let model = Mock::new(vec![final_turn("hi")]);
        let hitl = HitlPolicy::new();
        let loop_ = AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 3, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![], &[], None, NOW).await;
        assert_eq!(res.total_usage.total_tokens(), 0);
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
    async fn delegate_runs_subagents_concurrently_and_preserves_order() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        let model = RoutingMock;
        let hitl = HitlPolicy::new();
        let loop_ =
            AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_
            .run(vec![json!({"role": "user", "content": "do the parallel job"})], &[], None, NOW)
            .await;
        assert_eq!(res.status, AgentStatus::Final);
        // The synthesis only fires if BOTH workers completed and their results reached the parent —
        // proving the concurrent fan-out ran both sub-agents to completion.
        assert!(res.answer.contains("ALPHA_OK") && res.answer.contains("BETA_OK"), "got: {}", res.answer);
        assert_eq!(res.trace.iter().filter(|(n, _)| n == "delegate").count(), 1);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn delegate_fan_out_is_concurrent_not_sequential() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        let model = SleepMock { per_call_ms: 150 };
        let hitl = HitlPolicy::new();
        let loop_ =
            AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let t0 = std::time::Instant::now();
        let res = loop_.run(vec![json!({"role": "user", "content": "begin"})], &[], None, NOW).await;
        let elapsed = t0.elapsed();
        assert_eq!(res.status, AgentStatus::Final);
        // 3 workers × 150ms each: concurrent ≈ 150ms, sequential ≈ 450ms. Generous ceiling at 350ms
        // proves they overlapped (would be impossible if run one-after-another).
        assert!(elapsed.as_millis() < 350, "fan-out not concurrent: took {}ms (sequential would be ~450ms)", elapsed.as_millis());
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

    #[test]
    fn parse_string_array_tolerates_prose_and_fences() {
        assert_eq!(parse_string_array(r#"["a","b"]"#).unwrap(), vec!["a", "b"]);
        assert_eq!(parse_string_array("sure: [\"x\", \"y\"] done").unwrap(), vec!["x", "y"]);
        assert_eq!(
            parse_string_array("```json\n[\"one\", \"two\"]\n```").unwrap(),
            vec!["one", "two"]
        );
        assert!(parse_string_array("no array here").is_none());
        assert!(parse_string_array("[]").is_none()); // empty → None (caller falls back)
        assert!(parse_string_array(r#"["", "  "]"#).is_none()); // all-blank → None
    }

    #[tokio::test]
    async fn deep_research_decomposes_researches_and_synthesizes() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        let model = ResearchMock;
        let hitl = HitlPolicy::new();
        let loop_ =
            AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 6, depth: 0, mode: Mode::Hitl };
        let res = loop_
            .run(vec![json!({"role": "user", "content": "Research the future of local AI"})], &[], None, NOW)
            .await;
        assert_eq!(res.status, AgentStatus::Final);
        assert!(res.trace.iter().any(|(n, _)| n == "deep_research"));
        // All 3 decomposed sub-questions were researched and reached synthesis → found=3.
        assert!(res.answer.contains("found=3"), "report missing findings: {}", res.answer);
    }

    #[tokio::test]
    async fn council_deliberates_and_synthesizes_all_personas() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        let model = CouncilMock;
        let hitl = HitlPolicy::new();
        let loop_ =
            AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_
            .run(vec![json!({"role": "user", "content": "Should we ship Friday?"})], &[], None, NOW)
            .await;
        assert_eq!(res.status, AgentStatus::Final);
        assert!(res.trace.iter().any(|(n, _)| n == "council"));
        // The default trio (Analyst/Strategist/Skeptic) all reached synthesis → views=3.
        assert!(res.answer.contains("views=3"), "synthesis did not see all 3 opinions: {}", res.answer);
    }

    #[tokio::test]
    async fn council_persona_selection() {
        // Custom names: a known persona keeps its rich prompt; unknown gets a generic frame. Capped.
        let custom = vec![json!("Skeptic"), json!("Economist"), json!("Analyst")];
        let chosen = select_personas(Some(&custom));
        assert_eq!(chosen.len(), 3);
        assert_eq!(chosen[0].0, "Skeptic");
        assert!(chosen[0].1.contains("hard skeptic")); // known → rich prompt
        assert_eq!(chosen[1].0, "Economist");
        assert!(chosen[1].1.contains("You are Economist")); // unknown → generic frame
        // No personas → default trio.
        assert_eq!(select_personas(None).len(), 3);
        // Over-cap is truncated.
        let many: Vec<Value> = (0..10).map(|i| json!(format!("p{i}"))).collect();
        assert_eq!(select_personas(Some(&many)).len(), MAX_COUNCIL);
    }

    #[tokio::test]
    async fn synthetic_tool_budget_caps_runaway_calls() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        // One turn emitting 6 delegate calls (empty args → no nested model calls, deterministic),
        // then a final. Only MAX_SYNTHETIC_CALLS may execute; the rest are refused by the budget.
        let burst = AssistantTurn {
            content: None,
            tool_calls: (0..6)
                .map(|i| ToolCall { id: format!("c{i}"), name: "delegate".into(), arguments: json!({}) })
                .collect(),
            ..Default::default()
        };
        let model = Mock::new(vec![burst, final_turn("done")]);
        let hitl = HitlPolicy::new();
        let loop_ =
            AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 0, mode: Mode::Hitl };
        let res = loop_.run(vec![], &[], None, NOW).await;
        assert_eq!(res.status, AgentStatus::Final);
        let executed = res.trace.iter().filter(|(n, ok)| n == "delegate" && *ok).count();
        let refused = res.trace.iter().filter(|(n, ok)| n == "delegate" && !ok).count();
        assert_eq!(executed, MAX_SYNTHETIC_CALLS, "budget should cap executions");
        assert_eq!(refused, 6 - MAX_SYNTHETIC_CALLS, "over-budget calls must be refused, not run");
    }

    #[tokio::test]
    async fn worker_cannot_convene_council() {
        let dir = tmp_dir();
        let reg = notes_registry(dir);
        // At depth>0 (a worker), `council` is neither advertised nor handled → unknown tool, recover.
        let model = Mock::new(vec![
            call_turn(tc("council", json!({"question": "x"}))),
            final_turn("recovered"),
        ]);
        let hitl = HitlPolicy::new();
        let loop_ =
            AgentLoop { model: &model, registry: &reg, hitl: &hitl, max_iters: 5, depth: 1, mode: Mode::Hitl };
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
