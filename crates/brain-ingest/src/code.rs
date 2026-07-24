//! Tree-sitter code parsing (Task 2.1): function/class/struct entities +
//! import-edge resolution for TS/TSX/JS, Python, Rust, and Go.
//!
//! ponytail: Swift (DESIGN.md's sixth v1 language) is deferred — every
//! ABI-14-compatible release of the `tree-sitter-swift` crate (matching the
//! `tree-sitter` 0.24 core used here) predates its current `LanguageFn`
//! binding shape, and the versions with that shape target ABI 15. Rather
//! than vendor a patched grammar for one language, `.swift` files are left
//! unrecognized here — they still get indexed as plain File nodes by the
//! walker, just no CodeEntity/Imports extraction. Revisit when upgrading
//! the tree-sitter core makes a compatible swift release available.
//!
//! Design notes:
//! - Entity extraction walks the syntax tree directly (`node.kind()` +
//!   `child_by_field_name("name")`) rather than the tree-sitter Query DSL —
//!   fewer moving parts, and field names are stable across these grammars.
//! - Import resolution is regex-based, not AST-based: string literal node
//!   shapes vary across grammar versions/language, but "which relative
//!   module string is imported" is simple and robust to grab with a regex.
//!   Only imports that resolve to a file we actually walked become edges
//!   (PLAN.md: "unresolved imports dropped, not guessed").

use crate::paths::{dotted_to_path, normalize_join, parent_dir, rel_posix};
use anyhow::Result;
use brain_core::{now_ts, Edge, EdgeKind, Node, NodeKind, Origin, Store};
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use tree_sitter::{Language, Node as TsNode, Parser, Tree};

#[derive(Debug, Default, Clone, Copy)]
pub struct CodeStats {
    pub entities: usize,
    pub edges: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Lang {
    Ts,
    Tsx,
    Js,
    Py,
    Rust,
    Go,
}

impl Lang {
    pub(crate) fn from_ext(rel: &str) -> Option<Lang> {
        let ext = rel.rsplit('.').next()?;
        Some(match ext {
            "ts" => Lang::Ts,
            "tsx" => Lang::Tsx,
            "js" | "jsx" | "mjs" | "cjs" => Lang::Js,
            "py" => Lang::Py,
            "rs" => Lang::Rust,
            "go" => Lang::Go,
            _ => return None,
        })
    }

    fn ts_language(self) -> Language {
        match self {
            Lang::Ts => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            Lang::Tsx => tree_sitter_typescript::LANGUAGE_TSX.into(),
            Lang::Js => tree_sitter_javascript::LANGUAGE.into(),
            Lang::Py => tree_sitter_python::LANGUAGE.into(),
            Lang::Rust => tree_sitter_rust::LANGUAGE.into(),
            Lang::Go => tree_sitter_go::LANGUAGE.into(),
        }
    }

    fn entity_kinds(self) -> &'static [&'static str] {
        match self {
            Lang::Ts | Lang::Tsx | Lang::Js => &["function_declaration", "class_declaration"],
            Lang::Py => &["function_definition", "class_definition"],
            Lang::Rust => &["function_item", "struct_item", "enum_item", "trait_item"],
            Lang::Go => &["function_declaration", "method_declaration"],
        }
    }

    fn is_ts_family(self) -> bool {
        matches!(self, Lang::Ts | Lang::Tsx | Lang::Js)
    }
}

fn parse_tree(lang: Lang, source: &str) -> Option<Tree> {
    let language = lang.ts_language();
    let mut parser = Parser::new();
    parser.set_language(&language).ok()?;
    parser.parse(source, None)
}

fn collect_names(node: TsNode, src: &[u8], kinds: &[&str], out: &mut Vec<String>) {
    if kinds.contains(&node.kind()) {
        if let Some(name_node) = node.child_by_field_name("name") {
            if let Ok(name) = name_node.utf8_text(src) {
                out.push(name.to_string());
            }
        }
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_names(child, src, kinds, out);
    }
}

static TS_EXPORT_CONST: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^\s*export\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)").unwrap());

fn entity_names(lang: Lang, tree: &Tree, source: &str) -> Vec<String> {
    let mut names = Vec::new();
    collect_names(
        tree.root_node(),
        source.as_bytes(),
        lang.entity_kinds(),
        &mut names,
    );
    if lang.is_ts_family() {
        for cap in TS_EXPORT_CONST.captures_iter(source) {
            let name = cap[1].to_string();
            if !names.contains(&name) {
                names.push(name);
            }
        }
    }
    names
}

// --- import resolution -----------------------------------------------------

static JS_IMPORT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?:from\s+|require\()\s*['"](\.[^'"]+)['"]"#).unwrap());
static PY_FROM_IMPORT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^\s*from\s+(\.+)([\w.]*)\s+import").unwrap());
static PY_IMPORT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^\s*import\s+([A-Za-z_]\w*(?:\.\w+)*)").unwrap());
static RUST_MOD: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;").unwrap());

fn resolve_module(base: &str, exts: &[&str], known: &HashSet<String>) -> Option<String> {
    for ext in exts {
        let candidate = format!("{base}.{ext}");
        if known.contains(&candidate) {
            return Some(candidate);
        }
    }
    for ext in exts {
        let candidate = format!("{base}/index.{ext}");
        if known.contains(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn resolve_ts_imports(rel: &str, source: &str, known: &HashSet<String>) -> Vec<String> {
    let dir = parent_dir(rel);
    let exts = ["ts", "tsx", "js", "jsx"];
    JS_IMPORT
        .captures_iter(source)
        .filter_map(|cap| {
            let base = normalize_join(&dir, &cap[1]);
            resolve_module(&base, &exts, known)
        })
        .collect()
}

fn resolve_python_candidate(base: &str, known: &HashSet<String>) -> Option<String> {
    let py = format!("{base}.py");
    if known.contains(&py) {
        return Some(py);
    }
    let init = format!("{base}/__init__.py");
    if known.contains(&init) {
        return Some(init);
    }
    None
}

fn resolve_python_imports(rel: &str, source: &str, known: &HashSet<String>) -> Vec<String> {
    let dir = parent_dir(rel);
    let mut out = Vec::new();

    for cap in PY_FROM_IMPORT.captures_iter(source) {
        let dots = cap[1].len();
        let module_path = &cap[2];
        let mut base_parts: Vec<&str> = if dir.is_empty() {
            Vec::new()
        } else {
            dir.split('/').collect()
        };
        for _ in 1..dots {
            base_parts.pop();
        }
        let mut candidate_dir = base_parts.join("/");
        if !module_path.is_empty() {
            let sub = dotted_to_path(module_path);
            candidate_dir = if candidate_dir.is_empty() {
                sub
            } else {
                format!("{candidate_dir}/{sub}")
            };
        }
        if let Some(found) = resolve_python_candidate(&candidate_dir, known) {
            out.push(found);
        }
    }

    for cap in PY_IMPORT.captures_iter(source) {
        let as_path = dotted_to_path(&cap[1]);
        let same_dir_candidate = if dir.is_empty() {
            as_path.clone()
        } else {
            format!("{dir}/{as_path}")
        };
        if let Some(found) = resolve_python_candidate(&same_dir_candidate, known)
            .or_else(|| resolve_python_candidate(&as_path, known))
        {
            out.push(found);
        }
    }

    out
}

fn resolve_rust_imports(rel: &str, source: &str, known: &HashSet<String>) -> Vec<String> {
    let dir = parent_dir(rel);
    let stem = Path::new(rel)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();
    // `mod.rs`/`lib.rs`/`main.rs` declare submodules in their own directory;
    // any other `foo.rs` declares them in a sibling `foo/` directory.
    let mod_dir = if matches!(stem.as_str(), "mod" | "lib" | "main") {
        dir
    } else if dir.is_empty() {
        stem
    } else {
        format!("{dir}/{stem}")
    };

    RUST_MOD
        .captures_iter(source)
        .filter_map(|cap| {
            let name = &cap[1];
            let base = if mod_dir.is_empty() {
                name.to_string()
            } else {
                format!("{mod_dir}/{name}")
            };
            resolve_module(&base, &["rs"], known).or_else(|| {
                let modrs = format!("{base}/mod.rs");
                known.contains(&modrs).then_some(modrs)
            })
        })
        .collect()
}

fn resolve_imports(lang: Lang, rel: &str, source: &str, known: &HashSet<String>) -> Vec<String> {
    match lang {
        Lang::Ts | Lang::Tsx | Lang::Js => resolve_ts_imports(rel, source, known),
        Lang::Py => resolve_python_imports(rel, source, known),
        Lang::Rust => resolve_rust_imports(rel, source, known),
        // ponytail: Go import paths are module-relative (need go.mod's module
        // line to resolve, e.g. "example.com/mod/pkg/sub" -> "pkg/sub"), which
        // doesn't map to a within-project relative path the way TS/Py/Rust do
        // — left unresolved rather than guessed. Go files still get File +
        // CodeEntity nodes either way.
        Lang::Go => Vec::new(),
    }
}

// --- orchestration -----------------------------------------------------

/// Extracts CodeEntity nodes (+ Contains edges from their file) and Imports
/// edges for every recognized source file in `files`. `files` are absolute
/// paths already filtered by `walk::walk_files`.
pub fn extract(store: &Store, root: &Path, project: &str, files: &[PathBuf]) -> Result<CodeStats> {
    let known: HashSet<String> = files.iter().filter_map(|f| rel_posix(root, f)).collect();
    let mut stats = CodeStats::default();

    for file in files {
        let Some(rel) = rel_posix(root, file) else {
            continue;
        };
        let Some(lang) = Lang::from_ext(&rel) else {
            continue;
        };
        let Ok(source) = std::fs::read_to_string(file) else {
            continue;
        };
        let file_id = format!("{project}:{rel}");

        if let Some(tree) = parse_tree(lang, &source) {
            for name in entity_names(lang, &tree, &source) {
                let entity_id = format!("{file_id}#{name}");
                store.upsert_node(&Node {
                    id: entity_id.clone(),
                    kind: NodeKind::CodeEntity,
                    project: project.to_string(),
                    label: name,
                    path: Some(rel.clone()),
                    summary: None,
                    origin: Origin::Extracted,
                    updated: now_ts(),
                })?;
                store.upsert_edge(&Edge {
                    src: file_id.clone(),
                    dst: entity_id,
                    kind: EdgeKind::Contains,
                    weight: 1.0,
                })?;
                stats.entities += 1;
                stats.edges += 1;
            }
        }

        for target_rel in resolve_imports(lang, &rel, &source, &known) {
            let dst_id = format!("{project}:{target_rel}");
            store.upsert_edge(&Edge {
                src: file_id.clone(),
                dst: dst_id,
                kind: EdgeKind::Imports,
                weight: 1.0,
            })?;
            stats.edges += 1;
        }
    }

    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_typescript_function_and_class_names() {
        let source = "export function login(u: string) {}\nclass Widget {}\n";
        let tree = parse_tree(Lang::Ts, source).unwrap();
        let names = entity_names(Lang::Ts, &tree, source);
        assert!(names.contains(&"login".to_string()), "{names:?}");
        assert!(names.contains(&"Widget".to_string()), "{names:?}");
    }

    #[test]
    fn extracts_exported_const_names() {
        let source = "export const MAX_RETRIES = 3;\n";
        let tree = parse_tree(Lang::Ts, source).unwrap();
        let names = entity_names(Lang::Ts, &tree, source);
        assert!(names.contains(&"MAX_RETRIES".to_string()), "{names:?}");
    }

    #[test]
    fn extracts_python_function_names() {
        let source = "def parse_config(path):\n    return {}\n";
        let tree = parse_tree(Lang::Py, source).unwrap();
        let names = entity_names(Lang::Py, &tree, source);
        assert_eq!(names, vec!["parse_config".to_string()]);
    }

    #[test]
    fn extracts_rust_function_and_struct_names() {
        let source = "pub fn now_ts() -> i64 { 0 }\nstruct Store;\n";
        let tree = parse_tree(Lang::Rust, source).unwrap();
        let names = entity_names(Lang::Rust, &tree, source);
        assert!(names.contains(&"now_ts".to_string()), "{names:?}");
        assert!(names.contains(&"Store".to_string()), "{names:?}");
    }

    #[test]
    fn extracts_go_function_names() {
        let source = "package main\n\nfunc Fetch(url string) string {\n\treturn url\n}\n";
        let tree = parse_tree(Lang::Go, source).unwrap();
        let names = entity_names(Lang::Go, &tree, source);
        assert!(names.contains(&"Fetch".to_string()), "{names:?}");
    }

    #[test]
    fn resolves_relative_ts_import_within_known_files() {
        let mut known = HashSet::new();
        known.insert("src/auth.ts".to_string());
        known.insert("src/util.ts".to_string());
        let source = "import { hashPassword } from './util';\n";
        let resolved = resolve_ts_imports("src/auth.ts", source, &known);
        assert_eq!(resolved, vec!["src/util.ts".to_string()]);
    }

    #[test]
    fn drops_unresolved_ts_import_instead_of_guessing() {
        let known: HashSet<String> = HashSet::new();
        let source = "import { x } from './does-not-exist';\n";
        let resolved = resolve_ts_imports("src/auth.ts", source, &known);
        assert!(resolved.is_empty());
    }

    #[test]
    fn resolves_bare_python_import_to_top_level_module() {
        let mut known = HashSet::new();
        known.insert("main.py".to_string());
        known.insert("helpers.py".to_string());
        let source = "import helpers\n";
        let resolved = resolve_python_imports("main.py", source, &known);
        assert_eq!(resolved, vec!["helpers.py".to_string()]);
    }

    #[test]
    fn resolves_relative_python_from_import() {
        let mut known = HashSet::new();
        known.insert("pkg/main.py".to_string());
        known.insert("pkg/helpers.py".to_string());
        let source = "from .helpers import parse_config\n";
        let resolved = resolve_python_imports("pkg/main.py", source, &known);
        assert_eq!(resolved, vec!["pkg/helpers.py".to_string()]);
    }

    #[test]
    fn resolves_rust_mod_declaration_to_sibling_file() {
        let mut known = HashSet::new();
        known.insert("src/lib.rs".to_string());
        known.insert("src/store.rs".to_string());
        let source = "pub mod store;\n";
        let resolved = resolve_rust_imports("src/lib.rs", source, &known);
        assert_eq!(resolved, vec!["src/store.rs".to_string()]);
    }
}
