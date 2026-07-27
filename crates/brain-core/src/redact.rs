use once_cell::sync::Lazy;
use regex::Regex;

// Two shapes share this pattern:
//   - `keyword [=:] value`  (api_key=..., token: ..., password=...) — the
//     original shape. Extended here to tolerate a stray quote between the
//     keyword and the separator (`"password": "..."`, a JSON key's closing
//     quote sits right before the colon) and to capture a quoted value as
//     just its quoted span rather than greedily eating trailing JSON syntax
//     via `\S+`.
//   - `bearer value` (HTTP `Authorization: Bearer <token>`) — "bearer" has
//     no `=`/`:` before its value at all, just whitespace, so it gets its
//     own branch with an optional (not mandatory) separator. This branch is
//     intentionally *not* extended to the other keywords: making the
//     separator optional for "token"/"secret"/"password"/"api_key" too
//     would redact ordinary prose like "this token expires soon" — bearer
//     is a fixed HTTP scheme keyword, not a common English word used with a
//     following unrelated word as often, so this trade-off is scoped to it.
static KV_SECRET: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r#"(?i)(?:(api[_-]?key|token|secret|password)\s*['"]?\s*[:=]\s*|\b(bearer)\b\s*(?:[:=]\s*)?)("[^"]*"|'[^']*'|\S+)"#,
    )
    .unwrap()
});
static AWS_KEY: Lazy<Regex> = Lazy::new(|| Regex::new(r"AKIA[0-9A-Z]{16}").unwrap());
static OPENAI_ANTHROPIC_KEY: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"sk-[A-Za-z0-9\-_]{20,}").unwrap());

/// Redacts common secret shapes before content is persisted to transcripts or memory.
pub fn redact(input: &str) -> String {
    let step1 = KV_SECRET.replace_all(input, |caps: &regex::Captures| {
        // Exactly one of group 1 (non-bearer keyword) / group 2 ("bearer")
        // participates, depending on which alternation branch matched.
        let kw = caps
            .get(1)
            .or_else(|| caps.get(2))
            .map(|m| m.as_str())
            .unwrap_or("secret");
        format!("{kw}=[redacted]")
    });
    let step2 = AWS_KEY.replace_all(&step1, "[redacted]");
    OPENAI_ANTHROPIC_KEY
        .replace_all(&step2, "[redacted]")
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_key_value_secrets() {
        let input = "API_KEY=abc123 and password: hunter2hunter2";
        let out = redact(input);
        assert!(!out.contains("abc123"), "{out}");
        assert!(!out.contains("hunter2hunter2"), "{out}");
        assert!(out.contains("[redacted]"));
    }

    #[test]
    fn redacts_aws_and_anthropic_key_shapes() {
        let input = "key AKIAABCDEFGHIJKLMNOP and sk-ant-api03-abcdefghijklmnopqrstuvwx";
        let out = redact(input);
        assert!(!out.contains("AKIAABCDEFGHIJKLMNOP"));
        assert!(!out.contains("sk-ant-api03-abcdefghijklmnopqrstuvwx"));
    }

    #[test]
    fn leaves_ordinary_text_untouched() {
        let input = "fn parse_config(path: &str) -> Result<Config> { }";
        assert_eq!(redact(input), input);
    }

    #[test]
    fn redacts_bearer_token_separated_by_space_not_colon_or_equals() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abcdefghijklmnop";
        let out = redact(input);
        assert!(
            !out.contains("eyJhbGciOiJIUzI1NiJ9.abcdefghijklmnop"),
            "{out}"
        );
        assert!(out.contains("[redacted]"), "{out}");
    }

    #[test]
    fn redacts_bearer_token_with_no_space_before_bearer() {
        // No space between the "Authorization:" separator and "Bearer" —
        // only the mandatory space between "Bearer" and the token itself.
        let input = "Authorization:Bearer eyJhbGciOiJIUzI1NiJ9.qrstuvwxyz123456";
        let out = redact(input);
        assert!(
            !out.contains("eyJhbGciOiJIUzI1NiJ9.qrstuvwxyz123456"),
            "{out}"
        );
        assert!(out.contains("[redacted]"), "{out}");
    }

    #[test]
    fn redacts_json_double_quoted_password_value() {
        // A closing quote sits between the keyword and the colon, which the
        // original regex's `keyword\s*[=:]` did not tolerate.
        let input = r#"{"password": "hunter2hunter2verysecret"}"#;
        let out = redact(input);
        assert!(!out.contains("hunter2hunter2verysecret"), "{out}");
        assert!(out.contains("[redacted]"), "{out}");
    }

    #[test]
    fn redacts_single_quoted_password_value() {
        let input = "'password': 'hunter2hunter2verysecret'";
        let out = redact(input);
        assert!(!out.contains("hunter2hunter2verysecret"), "{out}");
        assert!(out.contains("[redacted]"), "{out}");
    }

    #[test]
    fn does_not_overmatch_prose_mentioning_secret_keywords_without_a_value() {
        // "token"/"secret"/"password" with no `[=:]` attached (and no
        // JSON-style quote-then-colon shape either) must be left alone —
        // the fix must not turn these into a value-less match.
        let input = "This token expires in 30 days. The secret sauce recipe is family-only. \
             Choose a strong password for your account.";
        assert_eq!(redact(input), input);
    }
}
