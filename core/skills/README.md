# GINEXUS Skills (hot-loadable modular plugins)

The core runs with **zero skills**. Drop a folder here (or in
`~/Library/Application Support/GINEXUS/skills/`), restart GINEXUS, and the agent gains its tools —
no recompile. This is the "everything beyond the kernel is a plugin" pillar.

## Layout
```
skills/
  <skill-name>/
    skill.json
```

## Manifest (`skill.json`)
```jsonc
{
  "name": "speech",
  "description": "Speak text aloud.",
  "version": "0.1.0",
  "tools": [
    {
      "name": "say",                         // the tool name the agent calls
      "description": "Speak text aloud.",     // shown to the model — be precise
      "type": "command",                      // "command" | "mcp"
      "autonomy": "auto",                     // "auto" (unattended) | "hitl" (Touch-ID approve) — default hitl
      "timeout_secs": 30,                     // killed after this (max 120)
      "params": { "type": "object", "properties": { "text": {"type":"string"} }, "required": ["text"] },
      "run": ["/usr/bin/say", "{text}"]       // argv; {param} placeholders are filled from the call
    }
  ]
}
```
- **`type: "command"`** — runs an executable. `{param}` values are substituted as **separate argv
  elements** (no shell). Put literal flags in `run` yourself (e.g. `["/usr/bin/git","log","--","{path}"]`).
- **`type: "mcp"`** — `run` is spawned as an MCP server; its tools are imported (namespaced
  `<skill>.`), default-deny / HITL.

## Security model (enforced by the runtime, not by trust)
- **No shell.** Commands run via `execvp`; metacharacters in arg values are literal.
- **No flag injection.** A supplied value may not turn into an argv element starting with `-`.
- **Executable trust.** `run[0]` must be an **absolute path that exists** and resolves **outside the
  skills dir** (a skill can't run a binary it shipped in its own folder; no `$PATH` hijack).
- **Unattended is gated.** `autonomy:"auto"` is honored **only** for core-vouched executables
  (`/usr/bin/say`, `/usr/bin/pbpaste`, plus any the operator adds via `GINEXUS_SKILLS_AUTO_ALLOW`).
  Any other command is **HITL (Touch-ID) regardless** of what the manifest says — a skill can never
  self-grant unattended execution of a destructive command.
- **Confined.** Children run with a **scrubbed environment** (no inherited secrets), a dedicated
  working dir, in their **own process group** (killed as a tree on timeout), with **bounded output**.
- **No shadowing.** A skill tool whose name collides with a built-in is skipped.

The hard approval gate (money, external comms, legal, irreversible deletes, self-merge) always
applies on top of this.

## Examples shipped here
- `speech/` — `say(text)`: speak aloud (auto).
- `clipboard/` — `clipboard_read()`: read the macOS clipboard (auto).
