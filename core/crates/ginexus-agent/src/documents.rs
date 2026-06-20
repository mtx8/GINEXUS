//! Document generation (Rust core, ZERO external crates): create real `.pdf` and `.docx` files
//! from a title + Markdown body. Exposed as the HITL-gated `write_document` agent tool, confined to
//! a documents directory.
//!
//! The model writes Markdown, so both renderers PARSE it (headings, bold/italic, bullets, numbered
//! lists, rules) and lay it out properly — never dumping `###`/`**` literally:
//! - PDF: hand-emitted PDF-1.4 set in Helvetica / Helvetica-Bold / -Oblique, with accurate
//!   proportional wrapping (Adobe AFM metrics → no clipping), inline bold/italic, headings, bullets,
//!   paragraph spacing, and pagination.
//! - DOCX: a hand-built OPC ZIP (stored entries + CRC-32) with real Word paragraphs — bold/sized
//!   headings, bold/italic runs, bulleted paragraphs, rules.
//! Both open in Preview / Pages / Word with no third-party dependency.

use crate::tools::{Tool, ToolResult};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

const PAGE_W: f64 = 612.0; // US Letter, points
const PAGE_H: f64 = 792.0;
const MARGIN: f64 = 72.0;
const USABLE: f64 = PAGE_W - 2.0 * MARGIN; // 468pt text column
const BODY_SIZE: f64 = 11.0;
const TITLE_SIZE: f64 = 20.0;
const BODY_LEADING: f64 = 15.5;

// ───────────────────────── Markdown model + parser ─────────────────────────

#[derive(Clone)]
struct Run {
    text: String,
    bold: bool,
    italic: bool,
}

enum Block {
    Heading(u8, Vec<Run>), // level 1..=3
    Para(Vec<Run>),
    Bullet(Vec<Run>),
    Numbered(String, Vec<Run>), // marker e.g. "1."
    Rule,
}

/// Parse inline `**bold**`, `__bold__`, `*italic*`, `_italic_`, `` `code` `` (markers stripped).
fn parse_inline(s: &str) -> Vec<Run> {
    let chars: Vec<char> = s.chars().collect();
    let mut runs: Vec<Run> = Vec::new();
    let mut buf = String::new();
    let mut bold = false;
    let mut ital = false;
    let flush = |runs: &mut Vec<Run>, buf: &mut String, b: bool, i: bool| {
        if !buf.is_empty() {
            runs.push(Run { text: std::mem::take(buf), bold: b, italic: i });
        }
    };
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let two = i + 1 < chars.len();
        if c == '`' {
            // strip code-span backticks, keep the literal text
            i += 1;
            continue;
        }
        if (c == '*' && two && chars[i + 1] == '*') || (c == '_' && two && chars[i + 1] == '_') {
            flush(&mut runs, &mut buf, bold, ital);
            bold = !bold;
            i += 2;
            continue;
        }
        if c == '*' || c == '_' {
            // a lone marker toggles italic (only when it borders a non-space, the common case)
            flush(&mut runs, &mut buf, bold, ital);
            ital = !ital;
            i += 1;
            continue;
        }
        buf.push(c);
        i += 1;
    }
    flush(&mut runs, &mut buf, bold, ital);
    if runs.is_empty() {
        runs.push(Run { text: String::new(), bold: false, italic: false });
    }
    runs
}

fn split_numbered(t: &str) -> Option<(String, &str)> {
    // "1. text" / "12) text"
    let bytes = t.as_bytes();
    let mut i = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i == 0 || i >= bytes.len() {
        return None;
    }
    let sep = bytes[i] as char;
    if (sep == '.' || sep == ')') && i + 1 < bytes.len() && bytes[i + 1] == b' ' {
        return Some((format!("{}.", &t[..i]), t[i + 2..].trim_start()));
    }
    None
}

fn parse_blocks(body: &str) -> Vec<Block> {
    let mut blocks = Vec::new();
    for raw in body.split('\n') {
        let t = raw.trim();
        if t.is_empty() {
            continue; // blank lines become spacing between blocks
        }
        if t == "---" || t == "***" || t == "___" || t.chars().all(|c| c == '-') && t.len() >= 3 {
            blocks.push(Block::Rule);
            continue;
        }
        if let Some(rest) = t.strip_prefix("#### ").or_else(|| t.strip_prefix("### ")) {
            blocks.push(Block::Heading(3, parse_inline(rest)));
            continue;
        }
        if let Some(rest) = t.strip_prefix("## ") {
            blocks.push(Block::Heading(2, parse_inline(rest)));
            continue;
        }
        if let Some(rest) = t.strip_prefix("# ") {
            blocks.push(Block::Heading(1, parse_inline(rest)));
            continue;
        }
        if let Some(rest) = t
            .strip_prefix("- ")
            .or_else(|| t.strip_prefix("* "))
            .or_else(|| t.strip_prefix("+ "))
            .or_else(|| t.strip_prefix("\u{2022} "))
        {
            blocks.push(Block::Bullet(parse_inline(rest)));
            continue;
        }
        if let Some((marker, rest)) = split_numbered(t) {
            blocks.push(Block::Numbered(marker, parse_inline(rest)));
            continue;
        }
        blocks.push(Block::Para(parse_inline(t)));
    }
    blocks
}

// ───────────────────── Helvetica AFM widths (1/1000 em) ─────────────────────
// Indexed by (codepoint - 32) for ASCII 32..=126. Oblique == base; BoldOblique == Bold.

#[rustfmt::skip]
const HELV: [u16; 95] = [
    278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,
    556,556,278,278,584,584,584,556,1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,
    667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,333,556,556,500,556,556,278,556,
    556,222,222,500,222,833,556,556,556,556,333,500,278,556,500,722,500,500,500,334,260,334,584,
];
#[rustfmt::skip]
const HELVB: [u16; 95] = [
    278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,
    556,556,333,333,584,584,584,611,975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,
    667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,333,556,611,556,611,556,333,611,
    611,278,278,556,278,889,611,611,611,611,389,556,333,611,556,778,556,556,500,389,280,389,584,
];

fn char_w(c: char, bold: bool) -> f64 {
    let table = if bold { &HELVB } else { &HELV };
    let i = c as usize;
    let w = if (32..=126).contains(&i) { table[i - 32] } else { table['n' as usize - 32] };
    w as f64
}

fn text_w(s: &str, size: f64, bold: bool) -> f64 {
    s.chars().map(|c| char_w(c, bold)).sum::<f64>() * size / 1000.0
}

/// A word's emitted segment: a leading space between words, EXCEPT before closing punctuation
/// (so "platform" + "." reads "platform.", not "platform .").
fn seg_for(i: usize, text: &str) -> String {
    let attach = i == 0 || text.starts_with(|c: char| matches!(c, '.' | ',' | ')' | ':' | ';' | '!' | '?' | '%'));
    if attach {
        text.to_string()
    } else {
        format!(" {text}")
    }
}

fn font_id(bold: bool, ital: bool) -> &'static str {
    match (bold, ital) {
        (true, true) => "F4",
        (true, false) => "F2",
        (false, true) => "F3",
        (false, false) => "F1",
    }
}

// ───────────────────────── PDF ─────────────────────────

fn pdf_escape(s: &str) -> String {
    let mut o = String::new();
    for ch in s.chars() {
        match ch {
            '(' => o.push_str("\\("),
            ')' => o.push_str("\\)"),
            '\\' => o.push_str("\\\\"),
            // common Unicode punctuation → WinAnsi octal escapes (fonts use WinAnsiEncoding)
            '\u{2022}' => o.push_str("\\225"), // bullet •
            '\u{2013}' => o.push_str("\\226"), // en dash –
            '\u{2014}' => o.push_str("\\227"), // em dash —
            '\u{2018}' => o.push_str("\\221"), // '
            '\u{2019}' => o.push_str("\\222"), // '
            '\u{201C}' => o.push_str("\\223"), // "
            '\u{201D}' => o.push_str("\\224"), // "
            '\u{2026}' => o.push_str("\\205"), // …
            c if (c as u32) >= 32 && (c as u32) < 127 => o.push(c),
            _ => o.push(' '),
        }
    }
    o
}

/// A word carrying its style; the unit of wrapping.
struct Word {
    text: String,
    bold: bool,
    ital: bool,
}

/// Split styled runs into words; char-break any single word wider than `max` so nothing clips.
fn words_of(runs: &[Run], size: f64, max: f64) -> Vec<Word> {
    let mut out = Vec::new();
    for r in runs {
        for w in r.text.split_whitespace() {
            if text_w(w, size, r.bold) <= max {
                out.push(Word { text: w.to_string(), bold: r.bold, ital: r.italic });
            } else {
                // break the long token (e.g. a file path/URL) into fitting chunks
                let mut chunk = String::new();
                for c in w.chars() {
                    if text_w(&format!("{chunk}{c}"), size, r.bold) > max && !chunk.is_empty() {
                        out.push(Word { text: std::mem::take(&mut chunk), bold: r.bold, ital: r.italic });
                    }
                    chunk.push(c);
                }
                if !chunk.is_empty() {
                    out.push(Word { text: chunk, bold: r.bold, ital: r.italic });
                }
            }
        }
    }
    out
}

/// Greedy line-wrap styled words to fit `width`.
fn wrap_words(words: Vec<Word>, size: f64, width: f64) -> Vec<Vec<Word>> {
    let space = text_w(" ", size, false);
    let mut lines: Vec<Vec<Word>> = Vec::new();
    let mut cur: Vec<Word> = Vec::new();
    let mut cur_w = 0.0;
    for w in words {
        let ww = text_w(&w.text, size, w.bold);
        let add = if cur.is_empty() { ww } else { space + ww };
        if !cur.is_empty() && cur_w + add > width {
            lines.push(std::mem::take(&mut cur));
            cur_w = ww;
            cur.push(w);
        } else {
            cur_w += add;
            cur.push(w);
        }
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    if lines.is_empty() {
        lines.push(Vec::new());
    }
    lines
}

/// Lays out blocks into one or more page content streams (paginating per line).
struct Pdf {
    pages: Vec<String>,
    cur: String,
    y: f64,
}
impl Pdf {
    fn new() -> Self {
        Pdf { pages: Vec::new(), cur: String::from("BT\n"), y: PAGE_H - MARGIN }
    }
    fn new_page(&mut self) {
        self.cur.push_str("ET");
        self.pages.push(std::mem::take(&mut self.cur));
        self.cur = String::from("BT\n");
        self.y = PAGE_H - MARGIN;
    }
    fn space(&mut self, dy: f64) {
        if self.y < PAGE_H - MARGIN {
            self.y -= dy; // no leading gap at the very top of a page
        }
    }
    /// Emit one wrapped line of styled words at the current cursor; paginate first if needed.
    fn line(&mut self, words: &[Word], size: f64, leading: f64, indent: f64) {
        if self.y - leading < MARGIN {
            self.new_page();
        }
        self.cur.push_str(&format!("1 0 0 1 {:.1} {:.1} Tm\n", MARGIN + indent, self.y));
        for (i, w) in words.iter().enumerate() {
            self.cur.push_str(&format!(
                "/{} {:.0} Tf ({}) Tj\n",
                font_id(w.bold, w.ital), size, pdf_escape(&seg_for(i, &w.text))
            ));
        }
        self.y -= leading;
    }
    /// A wrapped paragraph-like block (optionally bold) with a hanging marker (bullets/numbers).
    fn block(&mut self, runs: &[Run], size: f64, leading: f64, force_bold: bool, marker: Option<&str>) {
        let body_indent = if marker.is_some() { 18.0 } else { 0.0 };
        let styled: Vec<Run> = if force_bold {
            runs.iter().map(|r| Run { text: r.text.clone(), bold: true, italic: r.italic }).collect()
        } else {
            runs.to_vec()
        };
        let words = words_of(&styled, size, USABLE - body_indent);
        let lines = wrap_words(words, size, USABLE - body_indent);
        for (li, line) in lines.iter().enumerate() {
            if li == 0 {
                if let Some(m) = marker {
                    // marker sits in the hanging indent, then the first line of text
                    if self.y - leading < MARGIN {
                        self.new_page();
                    }
                    self.cur.push_str(&format!("1 0 0 1 {:.1} {:.1} Tm\n", MARGIN, self.y));
                    self.cur.push_str(&format!("/F1 {:.0} Tf ({}) Tj\n", size, pdf_escape(m)));
                    // first text line at the body indent, same baseline
                    self.cur.push_str(&format!("1 0 0 1 {:.1} {:.1} Tm\n", MARGIN + body_indent, self.y));
                    for (i, w) in line.iter().enumerate() {
                        self.cur.push_str(&format!(
                            "/{} {:.0} Tf ({}) Tj\n",
                            font_id(w.bold, w.ital), size, pdf_escape(&seg_for(i, &w.text))
                        ));
                    }
                    self.y -= leading;
                    continue;
                }
            }
            self.line(line, size, leading, body_indent);
        }
    }
    fn finish(mut self) -> Vec<String> {
        self.cur.push_str("ET");
        self.pages.push(self.cur);
        self.pages
    }
}

fn build_pdf(title: &str, body: &str) -> Vec<u8> {
    let mut pdf = Pdf::new();
    if !title.is_empty() {
        pdf.block(&[Run { text: title.to_string(), bold: true, italic: false }], TITLE_SIZE, TITLE_SIZE + 6.0, true, None);
        pdf.space(10.0);
    }
    for b in parse_blocks(body) {
        match b {
            Block::Heading(level, runs) => {
                let size = match level {
                    1 => 16.0,
                    2 => 14.0,
                    _ => 12.5,
                };
                pdf.space(12.0);
                pdf.block(&runs, size, size + 4.0, true, None);
                pdf.space(3.0);
            }
            Block::Para(runs) => {
                pdf.block(&runs, BODY_SIZE, BODY_LEADING, false, None);
                pdf.space(7.0);
            }
            Block::Bullet(runs) => {
                pdf.block(&runs, BODY_SIZE, BODY_LEADING, false, Some("\u{2022}"));
                pdf.space(3.0);
            }
            Block::Numbered(marker, runs) => {
                pdf.block(&runs, BODY_SIZE, BODY_LEADING, false, Some(&marker));
                pdf.space(3.0);
            }
            Block::Rule => pdf.space(14.0),
        }
    }
    let pages = pdf.finish();
    let n_pages = pages.len();
    // objects: 1 catalog, 2 pages, 3..=6 fonts (F1..F4), then (page,content) per page
    let font_base = 3;
    let first_page_obj = font_base + 4; // 7
    let n_objs = first_page_obj - 1 + 2 * n_pages;

    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(b"%PDF-1.4\n");
    let mut offsets = vec![0usize; n_objs + 1];
    let write_obj = |out: &mut Vec<u8>, offsets: &mut Vec<usize>, num: usize, body: &str| {
        offsets[num] = out.len();
        out.extend_from_slice(format!("{} 0 obj\n{}\nendobj\n", num, body).as_bytes());
    };

    write_obj(&mut out, &mut offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>");
    let kids: Vec<String> = (0..n_pages).map(|p| format!("{} 0 R", first_page_obj + 2 * p)).collect();
    write_obj(&mut out, &mut offsets, 2, &format!("<< /Type /Pages /Kids [{}] /Count {} >>", kids.join(" "), n_pages));
    for (idx, base) in ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"].iter().enumerate() {
        write_obj(
            &mut out,
            &mut offsets,
            font_base + idx,
            &format!("<< /Type /Font /Subtype /Type1 /BaseFont /{base} /Encoding /WinAnsiEncoding >>"),
        );
    }
    let font_res = "/Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R >>";
    for (p, content) in pages.iter().enumerate() {
        let page_num = first_page_obj + 2 * p;
        let content_num = page_num + 1;
        write_obj(
            &mut out,
            &mut offsets,
            page_num,
            &format!(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {:.0} {:.0}] /Resources << {} >> /Contents {} 0 R >>",
                PAGE_W, PAGE_H, font_res, content_num
            ),
        );
        write_obj(
            &mut out,
            &mut offsets,
            content_num,
            &format!("<< /Length {} >>\nstream\n{}\nendstream", content.len(), content),
        );
    }

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
        offsets.push(out.len() as u32);
        let nb = name.as_bytes();
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // stored
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0x21u16.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(nb.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(nb);
        out.extend_from_slice(data);
    }
    for (i, (name, data)) in entries.iter().enumerate() {
        let crc = crc32(data);
        let nb = name.as_bytes();
        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0x21u16.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(nb.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u32.to_le_bytes());
        central.extend_from_slice(&offsets[i].to_le_bytes());
        central.extend_from_slice(nb);
    }
    let central_off = out.len() as u32;
    let central_size = central.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_off.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

/// Word runs (`<w:r>`) for a set of styled inline runs; `force_bold` for headings, `sz` half-points.
fn docx_runs(runs: &[Run], force_bold: bool, sz: u32) -> String {
    let mut s = String::new();
    for r in runs {
        let mut rpr = String::new();
        if force_bold || r.bold {
            rpr.push_str("<w:b/>");
        }
        if r.italic {
            rpr.push_str("<w:i/>");
        }
        rpr.push_str(&format!("<w:sz w:val=\"{sz}\"/><w:szCs w:val=\"{sz}\"/>"));
        s.push_str(&format!(
            "<w:r><w:rPr>{}</w:rPr><w:t xml:space=\"preserve\">{}</w:t></w:r>",
            rpr,
            xml_escape(&r.text)
        ));
    }
    s
}

fn build_docx(title: &str, body: &str) -> Vec<u8> {
    let content_types = br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#.to_vec();
    let rels = br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#.to_vec();

    let mut paras = String::new();
    if !title.is_empty() {
        paras.push_str(&format!(
            "<w:p><w:pPr><w:spacing w:after=\"200\"/></w:pPr>{}</w:p>",
            docx_runs(&[Run { text: title.to_string(), bold: true, italic: false }], true, 40)
        ));
    }
    for b in parse_blocks(body) {
        match b {
            Block::Heading(level, runs) => {
                let sz = match level {
                    1 => 32,
                    2 => 28,
                    _ => 24,
                };
                paras.push_str(&format!(
                    "<w:p><w:pPr><w:spacing w:before=\"240\" w:after=\"80\"/><w:keepNext/></w:pPr>{}</w:p>",
                    docx_runs(&runs, true, sz)
                ));
            }
            Block::Para(runs) => {
                paras.push_str(&format!(
                    "<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr>{}</w:p>",
                    docx_runs(&runs, false, 22)
                ));
            }
            Block::Bullet(runs) => {
                let bullet = docx_runs(&[Run { text: "\u{2022}  ".to_string(), bold: false, italic: false }], false, 22);
                paras.push_str(&format!(
                    "<w:p><w:pPr><w:spacing w:after=\"60\"/><w:ind w:left=\"360\" w:hanging=\"180\"/></w:pPr>{}{}</w:p>",
                    bullet,
                    docx_runs(&runs, false, 22)
                ));
            }
            Block::Numbered(marker, runs) => {
                let m = docx_runs(&[Run { text: format!("{marker}  "), bold: false, italic: false }], false, 22);
                paras.push_str(&format!(
                    "<w:p><w:pPr><w:spacing w:after=\"60\"/><w:ind w:left=\"360\" w:hanging=\"180\"/></w:pPr>{}{}</w:p>",
                    m,
                    docx_runs(&runs, false, 22)
                ));
            }
            Block::Rule => {
                paras.push_str("<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BBBBBB\"/></w:pBdr></w:pPr></w:p>");
            }
        }
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
    if cleaned.is_empty() {
        return Err("empty document name".into());
    }
    Ok(base.join(format!("{cleaned}.{ext}")))
}

/// `write_document` — create a real PDF or Word document. Irreversible (writes a file → HITL-gated).
/// `app_host` (when the signed app is present) lets `location` place the file into a user folder.
pub fn write_document_tool(docs_dir: PathBuf, app_host: Option<(String, String)>) -> Tool {
    let base = Arc::new(docs_dir);
    let host = Arc::new(app_host);
    let loc_note = if host.is_some() {
        " To put it in a user folder, set `location` to downloads, desktop, or documents (default = \
         GINEXUS's internal folder); it is placed there for the user automatically."
    } else {
        ""
    };
    let desc = format!(
        "Create a real document file (PDF or Word .docx) from a title and body. Use for ANY story, \
         article, report, letter, note, essay, or document the user wants written or exported — \
         including 'a story in a PDF', 'a report as a docx', etc. This tool ALONE fulfills a \
         document/PDF request; do NOT also call image_generate unless the user explicitly asked for a \
         picture too. The `content` is rendered as Markdown (# / ## / ### headings, **bold**, \
         *italic*, `-` bullets, `1.` numbered lists, blank lines between paragraphs) for a clean, \
         properly formatted document.{loc_note} Returns the saved path."
    );
    Tool::new(
        "write_document",
        &desc,
        json!({"type": "object", "properties": {
            "filename": {"type": "string", "description": "base name, no extension"},
            "format": {"type": "string", "enum": ["pdf", "docx"], "description": "pdf or docx"},
            "title": {"type": "string"},
            "content": {"type": "string", "description": "Markdown body: ## headings, **bold**, - bullets, blank lines between paragraphs"},
            "location": {"type": "string", "enum": ["downloads", "desktop", "documents"], "description": "save into this user folder (omit to keep it in GINEXUS's internal folder)"}
        }, "required": ["filename", "format", "content"]}),
        true, // irreversible → HITL-gated
        Arc::new(move |args: Value| {
            let filename = args.get("filename").and_then(|v| v.as_str()).unwrap_or("").trim();
            let format = args.get("format").and_then(|v| v.as_str()).unwrap_or("pdf").trim().to_lowercase();
            let title = args.get("title").and_then(|v| v.as_str()).unwrap_or("");
            let content = args.get("content").and_then(|v| v.as_str()).unwrap_or("");
            let location = args.get("location").and_then(|v| v.as_str()).map(|s| s.trim().to_lowercase());
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
            if let Err(e) = std::fs::write(&path, &bytes) {
                return ToolResult::err(format!("write failed: {e}"));
            }
            // Place into the requested user folder via the signed app (TCC-correct), deterministically.
            if let (Some(loc), Some((sock, tok))) = (location.as_deref(), host.as_ref()) {
                if matches!(loc, "downloads" | "desktop" | "documents") {
                    let fname = path.file_name().and_then(|f| f.to_str()).unwrap_or("document");
                    let req = json!({"src": path.display().to_string(), "location": loc, "filename": fname});
                    return match crate::app_tools::call_app_host(sock, tok, "save_to_folder", &req) {
                        Ok(out) => ToolResult::ok(format!("Created {} ({} bytes). {}", ext.to_uppercase(), bytes.len(), out)),
                        Err(e) => ToolResult::ok(format!(
                            "Created {} ({} bytes) at {} (couldn't place it in {}: {})",
                            ext.to_uppercase(), bytes.len(), crate::abbreviate_home(&path.display().to_string()), loc, e
                        )),
                    };
                }
            }
            // Report the internal path with ~ (never the username/absolute home).
            ToolResult::ok(format!(
                "Created {} ({} bytes) at {}",
                ext.to_uppercase(), bytes.len(), crate::abbreviate_home(&path.display().to_string())
            ))
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
    fn pdf_renders_markdown_not_literally() {
        // headings/bold markers must NOT survive into the content stream as literal `###`/`**`.
        let bytes = build_pdf("Doc", "## Section One\n\nSome **bold** and *italic* text.\n\n- a bullet\n- another");
        let s = String::from_utf8_lossy(&bytes);
        assert!(!s.contains("## Section"), "heading marker leaked");
        assert!(!s.contains("**bold**"), "bold marker leaked");
        // words are emitted as separate Tj segments, so check the tokens are present
        assert!(s.contains("(Section)"), "heading text missing");
        assert!(s.contains("( One)") || s.contains("(One)"), "heading text missing");
        assert!(s.contains("/F2"), "bold font not used (headings/bold runs)");
    }

    #[test]
    fn docx_is_a_zip_with_parts() {
        let bytes = build_docx("Letter", "## Greeting\n\nDear team,\n\n- point one\n- point two\n\nRegards.");
        assert_eq!(&bytes[..4], &[0x50, 0x4b, 0x03, 0x04]); // PK\x03\x04
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("[Content_Types].xml"));
        assert!(s.contains("word/document.xml"));
        assert!(!s.contains("## Greeting"), "heading marker leaked into docx");
    }

    #[test]
    fn long_token_does_not_overflow() {
        // a path far wider than the column must be char-broken into fitting words (no clipping).
        let long = "/Users/someone/Library/Application/Support/GINEXUS/documents/".repeat(3);
        let words = words_of(&[Run { text: long, bold: false, italic: false }], BODY_SIZE, USABLE);
        for w in &words {
            assert!(text_w(&w.text, BODY_SIZE, w.bold) <= USABLE + 0.5, "token exceeds column: {}", w.text);
        }
    }

    #[test]
    fn tool_writes_both_formats_and_is_hitl() {
        let dir = tmp();
        let t = write_document_tool(dir.clone(), None);
        assert!(t.irreversible);
        let r = t.run(json!({"filename": "report", "format": "pdf", "title": "Q3", "content": "## Intro\n\nBody **text**."}));
        assert!(r.ok, "{}", r.output);
        assert!(dir.join("report.pdf").exists());
        let r2 = t.run(json!({"filename": "letter", "format": "docx", "content": "Hi."}));
        assert!(r2.ok, "{}", r2.output);
        assert!(dir.join("letter.docx").exists());
    }

    #[test]
    fn rejects_traversal_and_bad_format() {
        let dir = tmp();
        let t = write_document_tool(dir.clone(), None);
        assert!(t.run(json!({"filename": "../evil", "format": "pdf", "content": "x"})).ok); // sanitized, not escaped
        assert!(!dir.parent().unwrap().join("evil.pdf").exists());
        assert!(!t.run(json!({"filename": "x", "format": "exe", "content": "x"})).ok);
    }
}
