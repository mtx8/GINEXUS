# SP-Docs — Document Intelligence + In-Place Form Filling (Design)

**Status:** Draft v1 — awaiting Principal review
**Date:** 2026-06-21
**Owner:** Dreb (Principal) · authored via Conductor + codebase-seam mapping
**Brand:** GiNexus (the Okinawa AI startup, MackTrax family)
**Depends on:** master design (`2026-06-15-ginexus-master-design.md`), SP2 kernel (agent loop + app-bridge), SP3 memory
**Related:** `2026-06-21-sp-voice-*` (voice), `2026-06-21-sp-connect-*` (MCP integrations — feeds field data)

> This is a **sub-project spec** under the umbrella master design. It fixes the architecture, the
> locked decisions, and the decomposition for GINEXUS's document understanding + form-filling
> subsystem. It plugs into the **existing seams** verified on disk — it does not invent a parallel stack.

---

## 1. Overview & Goal

Give GINEXUS **full contextual understanding of the Principal's documents** and the ability to act on
them in place. Two concrete capabilities:

- **Flow A — Understand & rewrite.** Point GINEXUS at a local file or folder. It reads and understands
  the content, then **rewrites each section professionally** using the Principal's supplied text/intent,
  and returns a **per-section before/after diff** for approval before anything is written.
- **Flow B — Fill an existing form in place.** Give GINEXUS the path to a fillable PDF the Principal
  already uses (e.g. a recurring tax/intake form). It **fills the real file accurately, in place** —
  never regenerating a new PDF unless asked — after showing a `field → value` preview for approval.

**Acceptance test:** *"I gave GINEXUS the path to my fillable tax PDF and my data; it read the form's
fields, mapped my data correctly, showed me a preview, and — after I approved — wrote the values into
the real PDF in place, keeping a timestamped backup."*

**Positioning:** in-place, native, high-fidelity form-filling is a clean differentiator — neither
Odysseus (AGPL web workspace) nor Hermes (Nous) does native macOS AcroForm filling.

---

## 2. Confirmed Decisions (Principal, 2026-06-21)

1. **Form type = real fillable AcroForm PDFs, filled via native PDFKit.** High-fidelity field fill is
   the locked path. Flat/scanned PDFs (coordinate overlay + OCR) and XFA forms are **out of v1 scope**
   (§7 limitation).
2. **Rewrite handback = per-section review-diff; the Principal approves before any write.** Nothing is
   overwritten without explicit approval.
3. **Form-fill default = fill the existing file in place with an automatic timestamped backup.** A new
   copy is produced **only on request**.
4. **Document content is `untrusted-origin`.** All extracted text is data, never instructions (§7).

---

## 3. Existing Seams (verified on disk)

| Seam | Current state | Use in SP-Docs |
|---|---|---|
| `core/crates/ginexus-agent/src/documents.rs` | **Write-only** (`write_document` → PDF/DOCX from Markdown; HITL-gated) | Unchanged. New **read** path is a separate tool. |
| PDF handling | **None** for forms. Swift uses PDFKit **extract-only** (`PDFDocument.string`) in `AppModel.swift` for attachment text | Form read/fill added as **new app-bridge tools** (PDFKit, in the signed app). |
| `core/crates/ginexus-agent/src/tools.rs` | `Tool::new(name, desc, schema, irreversible, fn)` + `hard_gate`; registry in `main.rs` | Register `read_document` here. |
| `app/Sources/GinexusApp/AppToolHost.swift` | App-bridge over UDS (token-auth, newline JSON); already has `save_to_folder`, `pages_write` | Add `read_pdf_fields`, `fill_pdf_form` cases (TCC-correct, in the app). |
| `core/crates/ginexus-memory` | Memory store, keyword + optional embeddings, `Origin::Untrusted` tagging; no chunking/vector-store yet | Reuse for doc chunking/RAG; `sqlite-vec` upgrade is an enhancement. |
| `app/Sources/GinexusApp/AppModel.swift` | `NSOpenPanel` attach flow (UI-only) | Source the file/folder picker + security-scoped bookmark flow. |
| iCloud guard | Dual-blocked (Swift + Rust), SBPL deny on `Mobile Documents` (§7.6 master) | Enforced at the tool/file-op boundary for every SP-Docs path. |

---

## 4. Flow A — Understand & Rewrite

### 4.1 Read & contextualize
- **New Rust tool `read_document`** (read-only → **autonomous**). Input: a local path (file or folder)
  within the allowed workspace. Extracts text:
  - **PDF** → delegated to the Swift app-bridge (PDFKit `PDFDocument.string`) — keeps PDF parsing in
    the signed app and reuses the proven extractor.
  - **DOCX** → read the OPC zip (`word/document.xml`) — the inverse of the existing `write_document`
    DOCX emitter.
  - **MD / TXT / RTF** → read directly.
- **Chunk into the memory store, tagged `Origin::Untrusted`.** This is **both** the
  contextual-understanding / RAG layer **and** the prompt-injection defense mandated by §7.2/§7.5 of the
  master design: document text becomes data the agent reasons over, and **cannot authorize tool calls**.
- **Section segmentation:** split the extracted document into logical sections (headings, numbered
  parts, form sections, paragraph groups) with stable section IDs.

### 4.2 Rewrite & review
- For each section, the agent produces a **professional rewrite** using the Principal's supplied
  text/intent as the source-of-truth content.
- **New Swift review-diff sheet:** renders **before/after per section**. The Principal can **approve,
  edit, or reject each section** individually (and an "approve all"). **No write occurs until approval**
  — the write-back step is HITL-gated.
- **On approval:** write an **improved copy alongside the original** by default
  (`<name>-improved.<ext>`); **overwrite-with-automatic-backup** only if the Principal asks. Backups go
  to `~/Library/Application Support/GINEXUS/backups/<timestamp>/`.

### 4.3 Enhancement (not v1)
- Promote chunked retrieval to a real vector store (`sqlite-vec`) for large/long documents, resolving
  the SP3 sqlite-vec-vs-LanceDB decision; track source flat files + a rebuild script (git-diffable).

---

## 5. Flow B — Fill an AcroForm PDF in Place

### 5.1 New app-bridge tools (PDFKit, in the signed app — TCC-correct)
- **`read_pdf_fields`** (read-only → **autonomous**). Opens the PDF, enumerates AcroForm widget
  annotations, returns per field:
  `{ name, type (text|checkbox|radio|choice), current value, choices?, page, rect, nearby-label }`.
  The `nearby-label` is derived from the closest text on the page so the agent can map by human label,
  not just internal field name. This lets the agent **see** the form's true structure.
- **`fill_pdf_form`** (writes a file → **HITL-gated**). Input: `src` path + a `{ fieldName: value }`
  map + optional `output` (default = in place). Fills via PDFKit widget annotations
  (`.widgetStringValue` for text/choice, button state for checkbox/radio), then writes back. **Default
  behavior:** timestamped backup of the original → overwrite in place. New copy only if `output` set.

### 5.2 Field mapping (the accuracy layer)
The agent matches form fields to data by combining:
1. The Principal's supplied text for this fill.
2. The Principal's **profile facts in memory** (name, address, IDs the Principal has chosen to store).
3. **Connected MCP sources** (SP-Connect — e.g. pull a value from Notion).

It resolves each field using both the internal `name` and the `nearby-label`, then presents a
**`field → value` preview** in the approval sheet. **Writes only on approval.** The previewed values
are byte-identical to what is written (master §7.2 approval-token invariant).

### 5.3 Round-trip integrity
After a fill, `read_pdf_fields` on the output must return the written values — this is the core
acceptance + regression test (§8).

---

## 6. Path Safety & Workspace

- **iCloud refused in BOTH Swift and Rust** with a clear, explicit message (not a silent failure):
  any path under `~/Library/Mobile Documents/` (or `com~apple~CloudDocs`) is rejected at the
  tool/file-op boundary — the agent can compute paths the startup check never sees (master §7.6).
- **Configurable local "Documents workspace" root**, default `~/GINEXUS-Docs`, on genuinely local disk.
- **Security-scoped bookmarks** for user-picked files/folders, so access persists across launches
  without re-prompting.
- **No `..` traversal**; resolved real paths must stay within an allowed root or an explicitly-bookmarked
  location.

---

## 7. Security, HITL & Limitations

- **Autonomy:** `read_document` and `read_pdf_fields` are **read-only → autonomous**.
  `fill_pdf_form` and the rewrite **write-back** are **irreversible → biometric HITL** (master §7.2/§7.3).
- **Backups are automatic** before any overwrite; never destructive without a recoverable copy.
- **Untrusted-origin:** all extracted document text is tagged untrusted and cannot authorize tools.
- **Limitation — XFA forms.** PDFKit fills **AcroForm** fields but **not XFA-only** forms
  (LiveCycle / some government forms). SP-Docs **detects XFA** (presence of an XFA entry with no usable
  AcroForm fields) and **informs the Principal** rather than mis-filling. Flat/scanned PDFs
  (coordinate-overlay + OCR) are likewise out of v1 scope and reported, not guessed.

---

## 8. Testing

1. **Form round-trip:** `read_pdf_fields` → `fill_pdf_form` → `read_pdf_fields` returns the written
   values for text, checkbox, radio, and choice fields.
2. **In-place + backup:** in-place fill leaves a valid timestamped backup; original recoverable.
3. **Rewrite-diff correctness:** section segmentation is stable; the review-diff shows accurate
   before/after; no write occurs before approval; approved output matches the previewed text.
4. **iCloud refusal:** a path under `~/Library/Mobile Documents/` is rejected with the clear message in
   both Swift and Rust.
5. **XFA detection:** an XFA-only PDF is detected and reported, not filled.
6. **Untrusted-origin:** ingested document text cannot authorize a tool call.

---

## 9. Decomposition (ordered build steps)

| # | Step | Outcome |
|---|---|---|
| D1 | **`read_pdf_fields` app-bridge tool** | PDFKit field enumeration with nearby-label; autonomous; returns structured fields. |
| D2 | **`fill_pdf_form` app-bridge tool** | PDFKit widget fill + timestamped backup + in-place default; HITL-gated; XFA detection. |
| D3 | **`read_document` Rust tool** | Text extraction (PDF via bridge, DOCX via OPC, md/txt direct); path-safety + iCloud refusal. |
| D4 | **Chunk → memory (`Origin::Untrusted`)** | Document chunking into the memory store; retrieval for contextual understanding. |
| D5 | **Section segmentation + rewrite** | Stable section IDs; per-section professional rewrite using supplied text. |
| D6 | **Review-diff sheet (Swift)** | Before/after per section; approve/edit/reject; HITL write-back (improved copy default). |
| D7 | **Field-mapping + fill preview (Swift)** | Map fields ↔ supplied data / memory profile / SP-Connect sources; `field → value` approval; on-approve fill. |
| D8 | **Workspace + bookmarks + settings** | `~/GINEXUS-Docs` root, security-scoped bookmarks, picker flow. |
| D9 | **(Enhancement) sqlite-vec** | Vector store for large docs; rebuild script; source flat files tracked. |

**v1 finish line for SP-Docs:** D1–D8 — *the acceptance test in §1 passes for a real AcroForm form
and a multi-section document rewrite.*

---

## 10. Open Flags

- DOCX read fidelity (OPC-zip parsing) for complex documents — start with paragraph/heading text;
  tables/styles are a follow-up.
- `nearby-label` heuristic quality across varied form layouts — tune against real Principal forms.
- sqlite-vec vs LanceDB final call inherited from SP3 (§8 master) — D9 should not pre-empt it.
