//! In-core PII / secret sanitizer (Rust). A faithful port of the operator's `ai-export-sanitizer`
//! reference (mtx8/ai-export-sanitizer) so GINEXUS scrubs personal-data exports BEFORE anything
//! enters memory — no Python in the runtime path, part of the audited Rust security surface.
//!
//! Replaces sensitive values with CONSISTENT placeholders (`[EMAIL_1]`, `[USERNAME_2]`, …) so the
//! same value maps to the same token everywhere. Order of passes mirrors the reference: paths →
//! wide-net (PEM key blocks, URLs) → custom terms → everything else, so narrow numeric rules don't
//! chew digits inside URLs/keys. Coverage is parity-tested against the reference's battery.

use fancy_regex::{Captures, Regex};
use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Plain,
    Path,
    Luhn,
}

struct Rule {
    category: &'static str,
    kind: Kind,
    re: Regex,
}

fn rx(p: &str) -> Regex {
    Regex::new(p).expect("static sanitizer pattern compiles")
}

fn rules() -> &'static [Rule] {
    static RULES: OnceLock<Vec<Rule>> = OnceLock::new();
    RULES.get_or_init(|| {
        vec![
            Rule { category: "UNIX_USER_PATH", kind: Kind::Path,
                   re: rx(r"(?P<prefix>/(?:Users|home)/)(?P<username>[A-Za-z0-9._-]+)(?P<suffix>(?:/|\b))") },
            Rule { category: "WINDOWS_USER_PATH", kind: Kind::Path,
                   re: rx(r#"(?i)(?P<prefix>[A-Za-z]:\\Users\\)(?P<username>[^\\\r\n\t"']+)(?P<suffix>\\?)"#) },
            Rule { category: "PEM_PRIVATE_KEY", kind: Kind::Plain,
                   re: rx(r"-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP |ENCRYPTED |)PRIVATE KEY( BLOCK)?-----[\s\S]+?-----END (?:RSA |DSA |EC |OPENSSH |PGP |ENCRYPTED |)PRIVATE KEY( BLOCK)?-----") },
            Rule { category: "URL", kind: Kind::Plain, re: rx(r#"\bhttps?://[^\s"'<>]+"#) },
            Rule { category: "EMAIL", kind: Kind::Plain,
                   re: rx(r"(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})(?![A-Za-z0-9_%+-])") },
            Rule { category: "JWT", kind: Kind::Plain,
                   re: rx(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b") },
            Rule { category: "API_KEY", kind: Kind::Plain, re: rx(r"\b(sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|sk-svcacct-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{20,}|sk_test_[A-Za-z0-9]{20,}|rk_live_[A-Za-z0-9]{20,}|pk_live_[A-Za-z0-9]{20,}|whsec_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|ghu_[A-Za-z0-9]{36}|ghs_[A-Za-z0-9]{36}|ghr_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20}|xox[baprs]-[A-Za-z0-9-]{10,}|xapp-[0-9]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z\-_]{35}|GOCSPX-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|npm_[A-Za-z0-9]{36}|hf_[A-Za-z0-9]{30,}|r8_[A-Za-z0-9]{30,}|shp(?:at|ss|ca|pa)_[A-Fa-f0-9]{32}|SK[0-9a-fA-F]{32}|AC[0-9a-fA-F]{32}|SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|[0-9]{9,10}:[A-Za-z0-9_-]{35})\b") },
            Rule { category: "CREDIT_CARD", kind: Kind::Luhn, re: rx(r"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)") },
            Rule { category: "SSN", kind: Kind::Plain, re: rx(r"\b\d{3}-\d{2}-\d{4}\b") },
            Rule { category: "IP_ADDRESS", kind: Kind::Plain,
                   re: rx(r"\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b") },
            Rule { category: "IPV6_ADDRESS", kind: Kind::Plain, re: rx(r"(?<![:.\w])(?:(?:[A-Fa-f0-9]{1,4}:){7}[A-Fa-f0-9]{1,4}|(?:[A-Fa-f0-9]{1,4}:){1,7}:|(?:[A-Fa-f0-9]{1,4}:){1,6}:[A-Fa-f0-9]{1,4}|(?:[A-Fa-f0-9]{1,4}:){1,5}(?::[A-Fa-f0-9]{1,4}){1,2}|(?:[A-Fa-f0-9]{1,4}:){1,4}(?::[A-Fa-f0-9]{1,4}){1,3}|(?:[A-Fa-f0-9]{1,4}:){1,3}(?::[A-Fa-f0-9]{1,4}){1,4}|(?:[A-Fa-f0-9]{1,4}:){1,2}(?::[A-Fa-f0-9]{1,4}){1,5}|[A-Fa-f0-9]{1,4}:(?::[A-Fa-f0-9]{1,4}){1,6}|:(?:(?::[A-Fa-f0-9]{1,4}){1,7}|:))(?![:.\w])") },
            Rule { category: "MAC_ADDRESS", kind: Kind::Plain, re: rx(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b") },
            Rule { category: "ETH_ADDRESS", kind: Kind::Plain, re: rx(r"\b0x[a-fA-F0-9]{40}\b") },
            Rule { category: "BTC_ADDRESS", kind: Kind::Plain,
                   re: rx(r"\b(?:bc1[a-z0-9]{25,62}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})\b") },
            Rule { category: "PHONE", kind: Kind::Plain,
                   re: rx(r"(?<!\w)(?:\+?\d{1,3}[\s.-])?(?:\(?\d{2,4}\)?[\s.-]){1,3}\d{3,4}(?!\w)") },
        ]
    })
}

/// Luhn check (credit cards) over the digits in `s`.
fn luhn_valid(s: &str) -> bool {
    let digits: Vec<u32> = s.chars().filter_map(|c| c.to_digit(10)).collect();
    if digits.len() < 13 || digits.len() > 19 {
        return false;
    }
    let mut sum = 0u32;
    for (i, &d) in digits.iter().rev().enumerate() {
        if i % 2 == 1 {
            let dd = d * 2;
            sum += if dd > 9 { dd - 9 } else { dd };
        } else {
            sum += d;
        }
    }
    sum % 10 == 0
}

#[derive(Default)]
struct State {
    mapping: HashMap<String, String>,
    counts: HashMap<String, usize>,
}

pub struct Sanitizer {
    state: RefCell<State>,
    custom: Vec<Regex>,
    redact_urls: bool,
}

impl Sanitizer {
    pub fn new() -> Self {
        Self { state: RefCell::new(State::default()), custom: Vec::new(), redact_urls: true }
    }

    /// Add custom terms (names/companies/codenames) to redact, longest-first (so a longer term
    /// wins over a substring), case-insensitive, whole-token.
    pub fn with_custom_terms(mut self, terms: &[String]) -> Self {
        let mut t: Vec<String> = terms.iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
        t.sort_by_key(|s| std::cmp::Reverse(s.len()));
        t.dedup();
        self.custom = t
            .iter()
            .map(|term| rx(&format!(r"(?i)(?<!\w){}(?!\w)", fancy_regex::escape(term))))
            .collect();
        self
    }

    fn placeholder(&self, category: &str, original: &str) -> String {
        let mut st = self.state.borrow_mut();
        let key = format!("{category}:{original}");
        if let Some(p) = st.mapping.get(&key) {
            return p.clone();
        }
        let n = {
            let c = st.counts.entry(category.to_string()).or_insert(0);
            *c += 1;
            *c
        };
        let p = format!("[{category}_{n}]");
        st.mapping.insert(key, p.clone());
        p
    }

    /// Replace every match for which `f` returns Some(replacement); matches where `f` returns None
    /// (e.g. a non-Luhn credit-card candidate) are left untouched. No-shell, linear scan.
    fn replace_all_with<F>(&self, re: &Regex, text: &str, mut f: F) -> String
    where
        F: FnMut(&Captures) -> Option<String>,
    {
        let mut out = String::with_capacity(text.len());
        let mut last = 0usize;
        for cap in re.captures_iter(text) {
            let cap = match cap {
                Ok(c) => c,
                Err(_) => break, // backtrack limit / error → stop replacing (leave remainder intact)
            };
            let m = match cap.get(0) {
                Some(m) => m,
                None => continue,
            };
            if let Some(rep) = f(&cap) {
                out.push_str(&text[last..m.start()]);
                out.push_str(&rep);
                last = m.end();
            }
        }
        out.push_str(&text[last..]);
        out
    }

    pub fn sanitize_text(&self, text: &str) -> String {
        let mut s = text.to_string();
        // Phase 1: paths (preserve prefix/suffix, redact the username segment).
        for r in rules().iter().filter(|r| r.kind == Kind::Path) {
            s = self.replace_all_with(&r.re, &s, |c| {
                let prefix = c.name("prefix").map(|m| m.as_str()).unwrap_or("");
                let user = c.name("username").map(|m| m.as_str()).unwrap_or("");
                let suffix = c.name("suffix").map(|m| m.as_str()).unwrap_or("");
                Some(format!("{prefix}{}{suffix}", self.placeholder("USERNAME", user)))
            });
        }
        // Phase 2: wide-net consumers (PEM blocks, URLs) before narrow numeric rules.
        for r in rules().iter().filter(|r| matches!(r.category, "PEM_PRIVATE_KEY" | "URL")) {
            if r.category == "URL" && !self.redact_urls {
                continue;
            }
            s = self.replace_all_with(&r.re, &s, |c| Some(self.placeholder(r.category, c.get(0).unwrap().as_str())));
        }
        // Phase 3: custom terms.
        for re in &self.custom {
            s = self.replace_all_with(re, &s, |c| Some(self.placeholder("CUSTOM_TERM", c.get(0).unwrap().as_str())));
        }
        // Phase 4: everything else, in rule order.
        for r in rules().iter() {
            if r.kind == Kind::Path || matches!(r.category, "PEM_PRIVATE_KEY" | "URL") {
                continue;
            }
            s = self.replace_all_with(&r.re, &s, |c| {
                let orig = c.get(0).unwrap().as_str();
                if r.kind == Kind::Luhn && !luhn_valid(orig) {
                    return None;
                }
                Some(self.placeholder(r.category, orig))
            });
        }
        s
    }

    fn normalize_key(key: &str) -> String {
        let mut out = String::new();
        let mut prev_us = false;
        for ch in key.to_ascii_lowercase().chars() {
            if ch.is_ascii_alphanumeric() {
                out.push(ch);
                prev_us = false;
            } else if !prev_us {
                out.push('_');
                prev_us = true;
            }
        }
        out.trim_matches('_').to_string()
    }

    fn is_sensitive_key(key: &str) -> bool {
        let n = Self::normalize_key(key);
        const KEYS: &[&str] = &[
            "name", "full_name", "fullname", "display_name", "first_name", "last_name", "real_name",
            "email", "email_address", "mail", "username", "user_name", "login", "account",
            "token", "api_key", "apikey", "secret", "password", "access_token", "refresh_token",
            "computer_name", "hostname", "phone", "phone_number", "ssn",
        ];
        KEYS.contains(&n.as_str())
            || ["email", "token", "secret", "password", "apikey", "api_key", "cookie"]
                .iter()
                .any(|t| n.contains(t))
    }

    fn category_from_key(key: &str) -> &'static str {
        let n = Self::normalize_key(key);
        if n.contains("email") || n == "mail" {
            "EMAIL"
        } else if ["token", "secret", "password", "key", "cookie"].iter().any(|t| n.contains(t)) {
            "SECRET_VALUE"
        } else if n.contains("phone") {
            "PHONE"
        } else if n.ends_with("_name") || n == "name" {
            "NAME"
        } else if ["user", "login", "account"].iter().any(|t| n.contains(t)) {
            "USERNAME"
        } else {
            "SENSITIVE_VALUE"
        }
    }

    /// Recursively sanitize a JSON value: sensitive keys → placeholder; role/type preserved;
    /// strings → text-sanitized; everything else recursed.
    pub fn sanitize_json(&self, v: Value) -> Value {
        match v {
            Value::Object(map) => {
                let mut out = serde_json::Map::new();
                for (k, val) in map {
                    let nk = Self::normalize_key(&k);
                    if Self::is_sensitive_key(&k) && (val.is_string() || val.is_number()) {
                        let vs = match &val {
                            Value::String(s) => s.clone(),
                            other => other.to_string(),
                        };
                        out.insert(k.clone(), Value::String(self.placeholder(Self::category_from_key(&k), &vs)));
                    } else if (nk == "role" || nk == "type") && val.is_string() {
                        out.insert(k, val);
                    } else {
                        out.insert(k, self.sanitize_json(val));
                    }
                }
                Value::Object(out)
            }
            Value::Array(a) => Value::Array(a.into_iter().map(|x| self.sanitize_json(x)).collect()),
            Value::String(s) => Value::String(self.sanitize_text(&s)),
            other => other,
        }
    }

    /// Sanitize a JSON document, preserving valid JSON.
    pub fn sanitize_json_text(&self, text: &str) -> Result<String, String> {
        let v: Value = serde_json::from_str(text).map_err(|e| format!("bad json: {e}"))?;
        serde_json::to_string(&self.sanitize_json(v)).map_err(|e| e.to_string())
    }
}

impl Default for Sanitizer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn redacts(text: &str) -> bool {
        Sanitizer::new().sanitize_text(text) != text
    }

    #[test]
    fn luhn() {
        assert!(luhn_valid("4242 4242 4242 4242")); // valid test card
        assert!(!luhn_valid("4242 4242 4242 4241"));
    }

    #[test]
    fn email_consistent_mapping() {
        let s = Sanitizer::new();
        let out = s.sanitize_text("mail john.doe@example.com and john.doe@example.com again");
        assert!(!out.contains("john.doe@example.com"));
        assert_eq!(out.matches("[EMAIL_1]").count(), 2);
    }

    #[test]
    fn redacts_secrets_and_pii_parity_battery() {
        // Same coverage the Python reference asserts.
        for t in [
            "key sk-ant-abcdefghijklmnopqrstuvwxyz0123",
            "ghp_0123456789abcdefghijklmnopqrstuvwxyz",
            "GOCSPX-aBcDeFgHiJkLmNoPqRsTuV",
            "123456789:AAEhBOweik6ad9r_ABCDEFGHIJKLMNOPQRS",  // telegram
            "jwt eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEFghiJKLmnoPQRstuv",
            "ssn 123-45-6789",
            "ip 192.168.1.42",
            "ipv6 2001:db8::8a2e:370:7334",
            "mac 00:1b:44:11:3a:b7",
            "card 4242 4242 4242 4242",
            "eth 0x52908400098527886E0F7030069857D2E4169EE7",
            "call +1 (415) 555-2671",
            "/Users/dreb/secret/file.txt",
        ] {
            assert!(redacts(t), "should redact: {t}");
        }
    }

    #[test]
    fn does_not_redact_lookalikes() {
        for t in ["meeting at 12:34:56 today", "use std::vector here", "plain id 12345678901234 ok"] {
            // (the long digit run isn't Luhn-valid → credit-card rule skips it)
            let out = Sanitizer::new().sanitize_text(t);
            assert!(!out.contains("IPV6") && !out.contains("CREDIT_CARD"), "{t} -> {out}");
        }
    }

    #[test]
    fn json_sensitive_keys_and_strings() {
        let s = Sanitizer::new();
        let input = r#"{"email":"a@b.com","role":"user","note":"reach me at c@d.com","nested":{"api_key":"sk-abcdefghijklmnopqrstuvwx"}}"#;
        let out = s.sanitize_json_text(input).unwrap();
        assert!(!out.contains("a@b.com") && !out.contains("c@d.com"));
        assert!(!out.contains("sk-abcdefghijklmnopqrstuvwx"));
        assert!(out.contains("\"role\":\"user\"")); // role preserved
    }

    #[test]
    fn custom_terms() {
        let s = Sanitizer::new().with_custom_terms(&["Project Falcon".to_string()]);
        let out = s.sanitize_text("we shipped Project Falcon today");
        assert!(!out.contains("Project Falcon"));
        assert!(out.contains("[CUSTOM_TERM_1]"));
    }
}
