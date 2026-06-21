# SP-Projects — Projects / Workspaces (Design)

**Status:** Draft v1 — awaiting Principal review
**Date:** 2026-06-21
**Owner:** Dreb (Principal) · authored via Conductor + codebase-seam mapping
**Brand:** GiNexus (the Okinawa AI startup, MackTrax family)
**Depends on:** master design (`2026-06-15-ginexus-master-design.md`), SP2 kernel (agent loop + app-bridge), SP3 memory, **SP-Docs** (`2026-06-21-sp-docs-document-intelligence-design.md` — reuses its `read_document` extract+chunk path)
**Related:** `2026-06-21-sp-voice-conversational-voice-design.md` (voice), `2026-06-21-sp-connect-mcp-integrations-design.md` (MCP integrations — a project may scope connected sources)

> This is a **sub-project spec** under the umbrella master design. It fixes the architecture, the
> locked decisions, and the decomposition for GINEXUS's **Projects / workspaces** subsystem. It plugs
> into the **existing seams** verified on disk (`Conversation`/`ChatMsg`, `ConversationStore`,
> `AppModel`, `ContentView`) — it does not invent a parallel persistence stack.

---

## 1. Overview & Goal

Let the Principal **organize work into Projects** — the same mental model as ChatGPT/Claude Projects,
but local-first and native. A **Project** is one durable workspace that binds three things together:

1. **A local folder of files/documents** — a real directory on disk that holds the project's source
   material (notes, PDFs, forms, exports).
2. **Per-project custom instructions** — a user-authored system prompt that frames every thread in the
   project ("you are helping me file 2026 taxes; use the figures in the attached 1099s; be terse").
3. **Project-scoped chat threads** — conversations created *inside* the project that are **grounded in
   the project's files** (RAG retrieval filtered to that project) and shaped by its instructions.

Everything in a project is **scoped together**: a thread in "Taxes 2026" pulls from the Taxes 2026
documents and obeys the Taxes 2026 instructions; a thread in "Beyond Borders" does not. **Loose chats**
(today's default — no project) are completely unaffected: they keep `projectId == nil`, see no project
documents, and inject only the global system prompt.

**Acceptance test:** *"I create a 'Taxes 2026' project, drop my docs in, set instructions ('use the
attached 1099s, answer in plain English'), and every thread in it knows that context — it answers from
my documents and follows my instructions — while a brand-new loose chat sees none of it."*

**Positioning:** GINEXUS already has persisted conversations, a memory store with `Origin` tagging, and
a signed-app file picker. Projects is the **organizing layer** that turns those primitives into durable,
grounded workspaces — without a cloud, without sending a single document off-device.

---

## 2. Confirmed Decisions (Principal, 2026-06-21)

1. **A Project owns a real local folder** (default root `~/GINEXUS-Projects/<slug>/`), on genuinely
   local disk. **iCloud is refused** — never `~/Library/Mobile Documents/` (master §7.6, HARD RULE #1).
2. **Files are added through the signed Swift app** (`NSOpenPanel` / drag-drop → security-scoped
   bookmark), then **extracted + chunked via SP-Docs `read_document`** into the memory store, **tagged
   with the `projectId` and `Origin::Untrusted`**. Document content is contextual grounding **and** is
   never allowed to authorize a tool call.
3. **Custom instructions are user-authored = trusted.** They are composed with (not replacing) the
   global system prompt for that project's threads only.
4. **A conversation's project membership is fixed at creation** via an optional `projectId`. Loose chats
   keep `projectId == nil`. (Re-homing a thread between projects is a post-v1 enhancement, §10.)
5. **Deleting a project is a two-stage, confirmed action** — never silently destructive (§7).

---

## 3. Existing Seams (verified on disk)

| Seam | Current state | Use in SP-Projects |
|---|---|---|
| `app/Sources/GinexusCore/Conversation.swift` | `Conversation{id,title,createdAt,updatedAt,messages,schemaVersion}` + `ConversationMeta` index projection | **Add an optional `projectId`** (loose chats = `nil`); bump `schemaVersion`; surface `projectId` in `ConversationMeta`. |
| `app/Sources/GinexusCore/ChatMsg.swift` | Per-message durable Codable unit | **Unchanged** — project scope lives on the conversation, not the message. |
| `app/Sources/GinexusApp/AppModel.swift` | `@Published conversations/activeConversationID`; `DiskConversationStore`; `newChat/selectConversation/deleteConversation/persistActive`; `currentToken()`; `importExport()` picker pattern | Host `projects`, `activeProjectID`, project CRUD, file-add flow, instruction edits. `newChat()` stamps the active project's id. |
| `app/Sources/GinexusApp/ContentView.swift` | Icon rail · floating **conversations panel** (`ForEach(model.conversations)`) · execution stream · context+tools rail; all `Brand.*` tokens | **Add a Projects section** above the loose-chats list; add a project detail view. Reuse `Brand.ember500`, halftone, `Eyebrow`, `BlockCard`, `railSection`. |
| `core/crates/ginexus-agent` `read_document` (SP-Docs) | Extract (PDF via bridge, DOCX via OPC, md/txt direct) → chunk → memory, `Origin::Untrusted`, path-safety + iCloud refusal | **Reused verbatim**, with a new `project_id` parameter threaded onto the chunks it writes. |
| `core/crates/ginexus-memory` | Keyword + optional-embedding store, `Origin::Untrusted` tagging; `/v1/memory/search` | **Add an optional `project_id` filter** to the search path so a project's threads retrieve its docs first. |
| Agent system-prompt assembly (SP2 loop, in the signed app) | Global system prompt composed per turn | **Compose the project's custom instructions** after the global prompt, for project threads only. |
| iCloud guard | Dual-blocked (Swift + Rust), SBPL deny on `Mobile Documents` (master §7.6) | Enforced at the **project-folder creation + file-add boundary**. |

---

## 4. Data Model

### 4.1 New `Project` (GinexusCore)

A new value type in `GinexusCore`, persisted alongside conversations, kept testable and head-portable
(SP9) exactly like `Conversation`:

```swift
public struct Project: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var instructions: String        // user-authored custom system prompt (trusted)
    public var folderBookmark: Data        // security-scoped bookmark to the project's local folder
    public var folderDisplayPath: String   // ~-relative path for UI (never the absolute home/username)
    public let createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int          // = 1
}

/// Lightweight index row for the left rail (mirrors ConversationMeta).
public struct ProjectMeta: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var updatedAt: Date
    public var threadCount: Int            // conversations whose projectId == id
    public var fileCount: Int              // files added to the folder
}
```

- **`folderBookmark`** is a security-scoped bookmark (the durable, re-launchable grant), mirroring the
  SP-Docs / `importExport()` model. `folderDisplayPath` is the `~`-form string for the UI — **no
  username, no absolute home path** (master hard rule).
- `instructions` is the per-project system prompt. **User-authored ⇒ trusted** (§6).

### 4.2 Extending the EXISTING `Conversation`

Add **one optional field** to `Conversation` and surface it on the meta projection. This is additive and
back-compatible — existing transcripts decode with `projectId == nil` (loose chats):

```swift
public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMsg]
    public var projectId: UUID?            // NEW — nil ⇒ loose chat
    public var schemaVersion: Int          // bump 1 → 2 to mark projectId-aware files
}
```

- `Conversation.meta` carries `projectId` into `ConversationMeta` so the sidebar can group threads by
  project **without decoding every transcript** (the whole point of the existing index).
- `ChatMsg` is **untouched** — Codable `CodingKeys` there omit transient state and have no bearing on
  project scope.
- **Migration:** the existing `Codable` already tolerates missing optionals (see `ChatMsg`'s
  `decodeIfPresent` pattern); add `projectId` via `decodeIfPresent` so v1 (`schemaVersion == 1`) files
  load cleanly with `projectId == nil`. Re-save stamps `schemaVersion == 2`.

### 4.3 Persistence layout

Reuse the **single-file-per-record + index** model already proven by `DiskConversationStore`. Under
`~/Library/Application Support/GINEXUS/`:

```
GINEXUS/
  conversations/
    index.json            # [ConversationMeta] — now carries projectId per row
    <conv-uuid>.json      # full Conversation (now with projectId)
  projects/
    index.json            # [ProjectMeta]
    <project-uuid>.json   # full Project (name, instructions, folderBookmark, …)
```

A new `DiskProjectStore` (sibling of `DiskConversationStore`, same serial-queue, write-snapshot-verbatim
discipline → no read-modify-write, no lost updates). The **conversation index is the single source of
truth for thread→project grouping**; the app filters `conversations` by `projectId` in memory (no extra
disk reads to render the rail).

> The **project's documents themselves live in the project folder on disk** (§5), not inside
> `Application Support`. Only the project *record* + its memory chunks are stored centrally.

---

## 5. Project Folder & File Management

### 5.1 The folder

- On **create**, the app makes a real local directory at `<root>/<slug>/`, where `<root>` defaults to
  `~/GINEXUS-Projects` (a new `SettingsStore` key, like the existing `obsidianVaultPath`) and `<slug>`
  is a filesystem-safe slug of the project name (de-duplicated with a numeric suffix on collision).
- The Principal may instead **pick an existing local folder** (`NSOpenPanel`, directory mode) — e.g. an
  already-organized "Taxes 2026" folder. Either path yields a **security-scoped bookmark** stored in
  `Project.folderBookmark`, so access survives relaunch with no re-prompt.
- **iCloud-refused, loudly:** any chosen/derived path under `~/Library/Mobile Documents/` (or
  `com~apple~CloudDocs`) is **rejected with a clear message** at folder-creation/file-add time — never a
  silent failure (master §7.6, HARD RULE #1). The agent can compute a path the startup check never sees,
  so the refusal lives at the **tool/file-op boundary** in both Swift and Rust.

### 5.2 Adding files (TCC-correct, in the signed app)

- Files are added **only through the signed Swift app** — `NSOpenPanel` (multi-select) or drag-drop onto
  the project detail view — so TCC attribution is correct (master hard rule: OS/file access originates in
  the signed app, never the Python sidecar). This reuses the exact pattern `importExport()` and SP-Docs'
  picker already use.
- On add, the app:
  1. Copies (or references, when already inside the bookmarked folder) the file into the project folder.
  2. Calls SP-Docs **`read_document`** with the new **`project_id`** parameter to extract + chunk the
     file's text into the memory store, **tagged `Origin::Untrusted` AND `project_id = <this project>`**.
     This is **both** the contextual-grounding/RAG layer **and** the prompt-injection defense (master
     §7.2/§7.5): document text becomes data the agent reasons over and **cannot authorize tool calls**.
  3. Updates `ProjectMeta.fileCount` and the project's `updatedAt`.
- **Removing a file** deletes it from the folder and **evicts its chunks** from memory (delete-by
  `project_id` + source path), so retrieval can't surface a removed document.

### 5.3 What is NOT in scope here

In-place form-filling and section-rewrite are **SP-Docs** capabilities; a project simply provides the
folder + scope they operate within. SP-Projects does not re-implement them.

---

## 6. Custom Instructions

- Each project carries a **user-authored system prompt** (`Project.instructions`). Because the Principal
  types it, it is **trusted input** — unlike document text, it **may** shape agent behavior.
- **Composition (project threads only):** the per-turn system prompt becomes
  `[global system prompt] + [project instructions]` — global safety/identity/tooling rules first, the
  project framing appended. Project instructions **augment**, never override, the global safety rails and
  HITL gates (those are non-negotiable, master §7).
- **Loose chats** (no project) inject the global prompt **only** — exactly today's behavior.
- The instruction text is editable at any time from the project detail view; the change applies to the
  *next* turn in any of the project's threads (no retroactive transcript edit).

---

## 7. Chat Threads & Scoping

### 7.1 Creating a thread in a project

- `newChat()` is extended: when an `activeProjectID` is set, the new `Conversation` is stamped with that
  `projectId`. From the project detail view, **"New thread"** creates a chat already bound to the project.
- From the global "＋ New conversation" rail icon (no active project) → a **loose** chat (`projectId == nil`),
  unchanged.

### 7.2 What a project thread sees (the scoping contract)

For a turn in a conversation with `projectId == P`:

1. **Custom instructions** for project `P` are composed into the system prompt (§6).
2. **RAG retrieval is project-scoped:** the agent's memory `search` is filtered to `project_id == P`,
   so it retrieves **that project's documents first**. (Retrieval scoping detail in §8.)
3. Global/long-term memory (the Principal's profile, etc.) is **still available** — a project narrows
   document grounding, it doesn't blind the agent to who the Principal is.

A **loose chat** composes only the global prompt and runs **unscoped** memory search exactly as today —
it **never** sees project documents.

---

## 8. Retrieval Scoping

- Memory `search` (`/v1/memory/search` and the in-loop retrieval the agent calls) gains an **optional
  `project_id` filter**. The app passes `activeProject.id` for project threads; passes nothing for loose
  chats.
- **Filter semantics:** when `project_id` is present, the store **prioritizes chunks tagged with that
  `project_id`** (project documents) and may **fall back** to unscoped global facts (profile, prior
  consolidations) below them — so a "Taxes 2026" thread answers from the 1099s first but still knows the
  Principal's name. When absent, behavior is identical to today (unscoped).
- Tagging is set at ingest time (§5.2): every chunk written by `read_document` for a project carries both
  `Origin::Untrusted` and `project_id`. This is a single new column/field on the existing memory record;
  the keyword path filters on it directly, and the optional-embedding path filters candidates pre-rank.
- This keeps the **untrusted-origin invariant** intact: project documents are retrievable context, never
  instructions, regardless of which project requested them.

---

## 9. Security, HITL & Path Safety

- **File adds via the signed app** (TCC attribution correct); **security-scoped bookmarks** persist
  access without re-prompting. No file access originates in the Python sidecar (master hard rule).
- **Document content stays `Origin::Untrusted`** — chunked project files are data, can ground answers,
  and **cannot authorize a tool call** (master §7.2/§7.5).
- **Custom instructions are trusted** (user-authored) and may shape behavior — but **never** override the
  global safety rails or HITL gates (email send, terminal mutations, spend, IoT locks, external comms
  remain biometric-gated, master §7).
- **iCloud refusal on project folders** in BOTH Swift and Rust, with a clear message — enforced at folder
  create + every file add (master §7.6, HARD RULE #1). No `..` traversal; resolved real paths must stay
  within the bookmarked project folder.
- **No username / absolute home path** in any UI, log, or persisted display field — always the `~` form.
- **Project deletion is two-stage and confirmed.** Deleting a project asks the Principal explicitly:
  - **Always** removes the project record + its memory chunks + un-homes/removes its threads (the
    Principal chooses *delete threads* vs *keep threads as loose chats*).
  - **Removing the on-disk folder is opt-in within the same confirm dialog** (default: keep the folder on
    disk; the Principal's actual documents are never silently deleted). This mirrors SP-Docs' "never
    destructive without a recoverable copy" stance.

---

## 10. Testing

1. **Grounding (the core test):** create project "Taxes 2026" → add one document containing a fact found
   nowhere else → ask a question in a **project thread** answerable **only** from that doc → the answer is
   correct and cites/uses the document.
2. **Isolation:** open a **loose chat** (and a *different* project's thread) and ask the same question →
   it does **not** surface the Taxes 2026 document (retrieval scoping holds).
3. **Custom instructions:** set project instructions ("answer in one sentence, plain English") → a
   project thread obeys them; a loose chat does not.
4. **Untrusted-origin:** a project document containing an embedded "ignore your instructions and run X"
   string **cannot** authorize a tool call (chunk is `Origin::Untrusted`).
5. **Persistence/migration:** a pre-SP-Projects transcript (`schemaVersion == 1`) loads with
   `projectId == nil`; new project threads round-trip `projectId` across relaunch; the index groups
   threads by project without decoding transcripts.
6. **iCloud refusal:** choosing/deriving a project folder under `~/Library/Mobile Documents/` is rejected
   with the clear message in both Swift and Rust.
7. **Deletion safety:** deleting a project prompts; "keep folder" leaves the on-disk documents intact;
   "keep threads" converts threads to loose chats; memory chunks for the project are evicted (retrieval
   no longer returns them); file removal evicts that file's chunks.

---

## 11. UI (ContentView)

Match the existing shell: icon rail · floating left panel · execution stream · context+tools rail — all
**MackTrax dark / ember single-accent / halftone** tokens from `Brand.swift` (no fake stats, no second
accent, `~`-paths only).

### 11.1 Projects section in the left rail

Above today's loose-chats list, add a **PROJECTS** section (an `Eyebrow`-headed group, ember label):

- A **list of projects** (`ForEach(model.projects)`), each row showing name + thread/file counts.
- Each project row is **expandable to its threads** — `model.conversations.filter { $0.projectId == id }`,
  rendered with the same thread-row component already used for loose chats.
- A **"＋ Project"** affordance (ember `plus`, matching the existing "＋" new-conversation button) →
  create-project flow (name + choose/auto folder).
- Below the projects, the existing **loose chats** list (`conversations` where `projectId == nil`),
  unchanged.

### 11.2 Project detail view

Selecting a project opens a detail view (a sheet or a dedicated middle column, styled like the existing
Models/Memory sheets — `BlockCard` + `railSection` + `Eyebrow`, ember accents, halftone field):

1. **Files** — list of added files with size/type; **Add files** (`NSOpenPanel` / drag-drop) and
   **Remove** (with chunk eviction). Shows the `~`-form folder path and a "Reveal in Finder" action.
2. **Custom instructions** — a multi-line editor bound to `Project.instructions`, saved on commit;
   a short helper line ("These instructions frame every thread in this project").
3. **Threads** — the project's conversations with a **New thread** button (creates a chat already bound
   to the project) and the standard rename/delete/select actions.
4. **Delete project** — opens the two-stage confirm (§9): keep/remove folder, keep/delete threads.

### 11.3 New-chat-in-project flow

- **New thread** (from the detail view or an expanded project row) sets `activeProjectID = project.id`
  then calls `newChat()`, which stamps the new conversation's `projectId`. The execution stream and
  context rail show a small **project chip** (ember, `Eyebrow`-styled) so the Principal always knows which
  project's context is live.
- The global **"＋ New conversation"** rail icon clears `activeProjectID` first → a loose chat.

---

## 12. Decomposition (ordered build steps)

| # | Step | Outcome |
|---|---|---|
| D1 | **Data model + migration** | `Project`/`ProjectMeta` in `GinexusCore`; add optional `projectId` to `Conversation`/`ConversationMeta` with `decodeIfPresent` + `schemaVersion` bump 1→2; back-compat verified. |
| D2 | **Persistence (`DiskProjectStore`)** | `projects/index.json` + `<id>.json`, serial-queue snapshot-verbatim store (sibling of `DiskConversationStore`); project CRUD wired into `AppModel`. |
| D3 | **Project folder + bookmarks** | Create/pick local folder under `~/GINEXUS-Projects/<slug>/`; security-scoped bookmark; iCloud refusal (Swift + Rust); `~`-form display path. |
| D4 | **File add/remove + ingest** | App-side add (NSOpenPanel/drag-drop) → SP-Docs `read_document` with new `project_id` param → chunks tagged `Origin::Untrusted` + `project_id`; remove evicts chunks. |
| D5 | **Custom-instructions injection** | Compose `[global] + [project instructions]` for project threads only; loose chats unchanged; editor in detail view. |
| D6 | **Project-scoped retrieval** | Optional `project_id` filter on memory `search` (keyword + embedding pre-rank); project docs first, global facts fallback. |
| D7 | **UI** | Projects section in the left rail (expandable to threads), project detail view (files / instructions / threads), new-chat-in-project flow, project chip — MackTrax tokens. |
| D8 | **Deletion safety** | Two-stage confirm: keep/remove folder, keep/delete threads, evict chunks. |

**v1 finish line for SP-Projects:** D1–D8 — *the §1 acceptance test passes: a "Taxes 2026" project with
added docs + instructions grounds every thread inside it, and a loose chat sees none of it.*

---

## 13. Acceptance Criteria

- **"I create a 'Taxes 2026' project, drop my docs in, set instructions, and every thread in it knows
  that context."** Concretely:
  - Creating the project makes a real local folder (never iCloud), shown in `~` form.
  - Added documents are extracted/chunked (SP-Docs) and tagged with the project's id + `Origin::Untrusted`.
  - Every thread created inside the project composes the project's custom instructions with the global
    prompt and retrieves the project's documents first.
  - A loose chat created afterward sees **no** project documents and uses only the global prompt.
  - Deleting the project is confirmed and never silently destroys the Principal's on-disk documents.

---

## 14. Open Flags

- **Re-homing threads** between projects (and moving a loose chat *into* a project) — deferred; v1 fixes
  `projectId` at creation (§2.4).
- **Folder watching** (auto-ingest when the Principal drops a file into the folder via Finder) — a
  follow-up; v1 ingests on explicit add through the app (keeps TCC attribution clean).
- **Per-project connected sources** (SP-Connect): scoping an MCP integration to a project (e.g. a Notion
  database that only "Taxes 2026" threads may query) — a natural extension once SP-Connect lands; not v1.
- **Retrieval fallback weighting** (how aggressively global facts rank below project chunks) — tune
  against real Principal projects; inherits SP3's sqlite-vec-vs-LanceDB call (master §8) for large
  projects.
