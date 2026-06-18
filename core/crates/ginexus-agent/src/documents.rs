//! Document generation (Rust core, ZERO external crates): create real `.pdf` and `.docx` files
//! from a title + body text. Exposed as the HITL-gated `write_document` agent tool, confined to a
//! documents directory. PDF is emitted as raw PDF-1.4; DOCX as a hand-built OPC ZIP (stored entries
//! + CRC-32) — both open in Preview / Pages / Word without any third-party dependency.

use crate::tools::{Tool, ToolResult};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

const PAGE_W: i64 = 612; // US Letter, points
const PAGE_H: i64 = 792;
const MARGIN: i64 = 72;
const FONT_SIZE: i64 = 11;
const TITLE_SIZE: i64 = 18;
const LEADING: i64 = 15;
const WRAP_COLS: usize = 92; // Courier 11pt columns within the margins
const LINES_PER_PAGE: usize = 46;

// ───────────────────────── shared text wrapping ─────────────────────────

fn wrap(text: &str, cols: usize) -> Vec<String> {
    let mut out = Vec::new();
    for raw in text.split('\n') {
        let mut line = String::new();
        let mut len = 0usize;
        for word in raw.split(' ') {
            let wlen = word.chars().count();
            if wlen > cols {
                if len > 0 { out.push(std::mem::take(&mut line)); len = 0; }
                let chars: Vec<char> = word.chars().collect();
                let mut i = 0;
                while i < chars.len() {
                    let end = (i + cols).min(chars.len());
                    out.push(chars[i..end].iter().collect());
                    i = end;
                }
                continue;
            }
            if len == 0 { line = word.to_string(); len = wlen; }
            else if len + 1 + wlen <= cols { line.push(' '); line.push_str(word); len += 1 + wlen; }
            else { out.push(std::mem::take(&mut line)); line = word.to_string(); len = wlen; }
        }
        out.push(line);
    }
    out
}

// ───────────────────────── PDF ─────────────────────────

fn pdf_escape(s: &str) -> String {
    let mut o = String::new();
    for ch in s.chars() {
        match ch {
            '(' => o.push_str("\\("),
            ')' => o.push_str("\\)"),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) >= 32 && (c as u32) < 127 => o.push(c),
            _ => o.push(' '), // non-ASCII → space (Courier WinAnsi base)
        }
    }
    o
}

fn page_content(lines: &[String], title: Option<&str>) -> String {
    let mut s = String::from("BT\n");
    let mut y = PAGE_H - MARGIN;
    if let Some(t) = title {
        s.push_str(&format!("/F1 {} Tf\n{} {} Td\n({}) Tj\n", TITLE_SIZE, MARGIN, y, pdf_escape(t)));
        s.push_str(&format!("/F1 {} Tf\n0 -{} Td\n", FONT_SIZE, TITLE_SIZE + LEADING));
        y -= TITLE_SIZE + LEADING;
    } else {
        s.push_str(&format!("/F1 {} Tf\n{} {} Td\n", FONT_SIZE, MARGIN, y));
    }
    for (i, line) in lines.iter().enumerate() {
        if i > 0 { s.push_str(&format!("0 -{} Td\n", LEADING)); }
        s.push_str(&format!("({}) Tj\n", pdf_escape(line)));
    }
    s.push_str("ET");
    s
}

fn build_pdf(title: &str, body: &str) -> Vec<u8> {
    let wrapped = wrap(body, WRAP_COLS);
    let mut pages: Vec<Vec<String>> = wrapped.chunks(LINES_PER_PAGE).map(|c| c.to_vec()).collect();
    if pages.is_empty() { pages.push(Vec::new()); }
    let n_pages = pages.len();
    let n_objs = 3 + 2 * n_pages; // catalog, pages, font, then (page, content) per page

    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(b"%PDF-1.4\n");
    let mut offsets = vec![0usize; n_objs + 1];
    let mut write_obj = |out: &mut Vec<u8>, offsets: &mut Vec<usize>, num: usize, body: &str| {
        offsets[num] = out.len();
        out.extend_from_slice(format!("{} 0 obj\n{}\nendobj\n", num, body).as_bytes());
    };

    // 1 catalog, 2 pages, 3 font
    write_obj(&mut out, &mut offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>");
    let kids: Vec<String> = (0..n_pages).map(|p| format!("{} 0 R", 4 + 2 * p)).collect();
    let pages_obj = format!("<< /Type /Pages /Kids [{}] /Count {} >>", kids.join(" "), n_pages);
    write_obj(&mut out, &mut offsets, 2, &pages_obj);
    write_obj(&mut out, &mut offsets, 3, "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>");

    for (p, lines) in pages.iter().enumerate() {
        let page_num = 4 + 2 * p;
        let content_num = 5 + 2 * p;
        let page_obj = format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {} {}] /Resources << /Font << /F1 3 0 R >> >> /Contents {} 0 R >>",
            PAGE_W, PAGE_H, content_num
        );
        write_obj(&mut out, &mut offsets, page_num, &page_obj);
        let content = page_content(lines, if p == 0 && !title.is_empty() { Some(title) } else { None });
        let content_obj = format!("<< /Length {} >>\nstream\n{}\nendstream", content.len(), content);
        write_obj(&mut out, &mut offsets, content_num, &content_obj);
    }

    // xref
    let xref_off = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n", n_objs + 1).as_bytes());
    out.extend_from_slice(b"0000000000 65535 f \n");
    for num in 1..=n_objs {
        out.extend_from_slice(format!("{:010} 00000 n \n", offsets[num]).as_bytes());
    }
    out.extend_from_slice(
        format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{}\n%%EOF\n", n_objs + 1, xref_off).as_bytes(),
    );
    out
}

// ───────────────────────── DOCX (OPC ZIP, no deps) ─────────────────────────

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

/// Build a ZIP with STORED (uncompressed) entries — minimal but valid OPC package.
fn build_zip(entries: &[(&str, Vec<u8>)]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut central: Vec<u8> = Vec::new();
    let mut offsets: Vec<u32> = Vec::new();
    for (name, data) in entries {
        let crc = crc32(data);
        let off = out.len() as u32;
        offsets.push(off);
        let nb = name.as_bytes();
        // local file header
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed
        out.extend_from_slice(&0u16.to_le_bytes()); // flags
        out.extend_from_slice(&0u16.to_le_bytes()); // method 0 = stored
        out.extend_from_slice(&0u16.to_le_bytes()); // mod time
        out.extend_from_slice(&0x21u16.to_le_bytes()); // mod date (1980-01-01)
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(nb.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // extra len
        out.extend_from_slice(nb);
        out.extend_from_slice(data);
    }
    for (i, (name, data)) in entries.iter().enumerate() {
        let crc = crc32(data);
        let nb = name.as_bytes();
        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes()); // version made by
        central.extend_from_slice(&20u16.to_le_bytes()); // version needed
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // method stored
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0x21u16.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(nb.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // extra
        central.extend_from_slice(&0u16.to_le_bytes()); // comment
        central.extend_from_slice(&0u16.to_le_bytes()); // disk
        central.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
        central.extend_from_slice(&0u32.to_le_bytes()); // external attrs
        central.extend_from_slice(&offsets[i].to_le_bytes());
        central.extend_from_slice(nb);
    }
    let central_off = out.len() as u32;
    let central_size = central.len() as u32;
    out.extend_from_slice(&central);
    // end of central directory
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // disk
    out.extend_from_slice(&0u16.to_le_bytes()); // start disk
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_off.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment len
    out
}

fn build_docx(title: &str, body: &str) -> Vec<u8> {
    let content_types = br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#.to_vec();
    let rels = br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#.to_vec();

    let mut paras = String::new();
    if !title.is_empty() {
        paras.push_str(&format!(
            "<w:p><w:pPr><w:spacing w:after=\"160\"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val=\"40\"/></w:rPr><w:t xml:space=\"preserve\">{}</w:t></w:r></w:p>",
            xml_escape(title)
        ));
    }
    for para in body.split('\n') {
        paras.push_str(&format!(
            "<w:p><w:r><w:t xml:space=\"preserve\">{}</w:t></w:r></w:p>",
            xml_escape(para)
        ));
    }
    let document = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>{}<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>",
        paras
    ).into_bytes();

    build_zip(&[
        ("[Content_Types].xml", content_types),
        ("_rels/.rels", rels),
        ("word/document.xml", document),
    ])
}

// ───────────────────────── tool ─────────────────────────

/// Sanitize a user filename to a single safe component with the right extension.
fn safe_doc_path(base: &PathBuf, name: &str, ext: &str) -> Result<PathBuf, String> {
    let stem = name.trim().trim_end_matches(&format!(".{ext}")).trim_end_matches(".pdf").trim_end_matches(".docx");
    let cleaned: String = stem
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' || c == ' ' { c } else { '_' })
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() { return Err("empty document name".into()); }
    Ok(base.join(format!("{cleaned}.{ext}")))
}

/// `write_document` — create a real PDF or Word document. Irreversible (writes a file → HITL-gated).
pub fn write_document_tool(docs_dir: PathBuf) -> Tool {
    let base = Arc::new(docs_dir);
    Tool::new(
        "write_document",
        "Create a real document file (PDF or Word .docx) from a title and body text, saved to the \
         user's local Documents area on this Mac. Use for ANY story, article, report, letter, note, \
         essay, or document the user wants written or exported — including 'a story in a PDF', 'a \
         report as a docx', etc. This tool ALONE fulfills a document/PDF request; do NOT also call \
         image_generate unless the user explicitly asked for a picture too. Returns the file path. \
         Args: filename, format ('pdf' or 'docx'), title, content.",
        json!({"type": "object", "properties": {
            "filename": {"type": "string", "description": "base name, no extension"},
            "format": {"type": "string", "enum": ["pdf", "docx"], "description": "pdf or docx"},
            "title": {"type": "string"},
            "content": {"type": "string", "description": "document body; use blank lines between paragraphs"}
        }, "required": ["filename", "format", "content"]}),
        true, // irreversible → HITL-gated
        Arc::new(move |args: Value| {
            let filename = args.get("filename").and_then(|v| v.as_str()).unwrap_or("").trim();
            let format = args.get("format").and_then(|v| v.as_str()).unwrap_or("pdf").trim().to_lowercase();
            let title = args.get("title").and_then(|v| v.as_str()).unwrap_or("");
            let content = args.get("content").and_then(|v| v.as_str()).unwrap_or("");
            let ext = match format.as_str() {
                "pdf" => "pdf",
                "docx" | "word" | "doc" => "docx",
                other => return ToolResult::err(format!("unsupported format '{other}' (use pdf or docx)")),
            };
            let path = match safe_doc_path(&base, filename, ext) {
                Ok(p) => p,
                Err(e) => return ToolResult::err(e),
            };
            let _ = std::fs::create_dir_all(base.as_ref());
            let bytes = if ext == "pdf" { build_pdf(title, content) } else { build_docx(title, content) };
            match std::fs::write(&path, &bytes) {
                Ok(_) => ToolResult::ok(format!("Created {} ({} bytes) at {}", ext.to_uppercase(), bytes.len(), path.display())),
                Err(e) => ToolResult::err(format!("write failed: {e}")),
            }
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static CTR: AtomicU64 = AtomicU64::new(0);
    fn tmp() -> PathBuf {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let d = std::env::temp_dir().join(format!("ginexus-docs-{}-{}-{}", std::process::id(), n, CTR.fetch_add(1, Ordering::Relaxed)));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn pdf_has_valid_header_and_eof() {
        let bytes = build_pdf("Test Report", "Hello world.\n\nA second paragraph with enough text to exercise wrapping ".repeat(20).as_str());
        assert!(bytes.starts_with(b"%PDF-1.4"));
        assert!(bytes.windows(5).any(|w| w == b"%%EOF"));
        assert!(bytes.windows(4).any(|w| w == b"xref"));
    }

    #[test]
    fn docx_is_a_zip_with_parts() {
        let bytes = build_docx("Letter", "Dear team,\n\nThis is the body.\n\nRegards.");
        assert_eq!(&bytes[..4], &[0x50, 0x4b, 0x03, 0x04]); // PK\x03\x04
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("[Content_Types].xml"));
        assert!(s.contains("word/document.xml"));
    }

    #[test]
    fn tool_writes_both_formats_and_is_hitl() {
        let dir = tmp();
        let t = write_document_tool(dir.clone());
        assert!(t.irreversible);
        let r = t.run(json!({"filename": "report", "format": "pdf", "title": "Q3", "content": "Body."}));
        assert!(r.ok, "{}", r.output);
        assert!(dir.join("report.pdf").exists());
        let r2 = t.run(json!({"filename": "letter", "format": "docx", "content": "Hi."}));
        assert!(r2.ok, "{}", r2.output);
        assert!(dir.join("letter.docx").exists());
    }

    #[test]
    fn rejects_traversal_and_bad_format() {
        let dir = tmp();
        let t = write_document_tool(dir.clone());
        assert!(t.run(json!({"filename": "../evil", "format": "pdf", "content": "x"})).ok); // sanitized, not escaped
        assert!(!dir.parent().unwrap().join("evil.pdf").exists());
        assert!(!t.run(json!({"filename": "x", "format": "exe", "content": "x"})).ok);
    }
}
