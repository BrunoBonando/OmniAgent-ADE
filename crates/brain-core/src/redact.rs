use once_cell::sync::Lazy;
use regex::Regex;

static KV_SECRET: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)(api[_-]?key|token|secret|password|bearer)\s*[=:]\s*\S+").unwrap()
});
static AWS_KEY: Lazy<Regex> = Lazy::new(|| Regex::new(r"AKIA[0-9A-Z]{16}").unwrap());
static OPENAI_ANTHROPIC_KEY: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"sk-[A-Za-z0-9\-_]{20,}").unwrap());

/// Redacts common secret shapes before content is persisted to transcripts or memory.
pub fn redact(input: &str) -> String {
    let step1 = KV_SECRET.replace_all(input, |caps: &regex::Captures| {
        format!("{}=[redacted]", &caps[1])
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
}
