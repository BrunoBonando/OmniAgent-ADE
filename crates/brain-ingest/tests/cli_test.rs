//! Task 2.3 integration test: exercises the real `brain` binary end-to-end
//! (not the library directly), isolated to a tempdir data dir so it never
//! touches the real `~/Library/Application Support/OmniAgent-ADE`.

use assert_cmd::Command;
use predicates::prelude::*;
use std::path::PathBuf;
use tempfile::tempdir;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap() // crates/
        .parent()
        .unwrap() // repo root
        .to_path_buf()
}

#[test]
fn ingest_then_search_finds_parse_config() {
    let data_dir = tempdir().unwrap();
    let fixtures_dir = repo_root().join("fixtures");

    Command::cargo_bin("brain")
        .unwrap()
        .env("OMNIAGENT_ADE_DATA_DIR", data_dir.path())
        .arg("ingest")
        .arg(&fixtures_dir)
        .assert()
        .success()
        .stdout(predicate::str::contains("sample-project"));

    Command::cargo_bin("brain")
        .unwrap()
        .env("OMNIAGENT_ADE_DATA_DIR", data_dir.path())
        .arg("search")
        .arg("parse_config")
        .assert()
        .success()
        .stdout(predicate::str::contains("parse_config"));
}

#[test]
fn stats_reports_the_ingested_project() {
    let data_dir = tempdir().unwrap();
    let fixtures_dir = repo_root().join("fixtures");

    Command::cargo_bin("brain")
        .unwrap()
        .env("OMNIAGENT_ADE_DATA_DIR", data_dir.path())
        .arg("ingest")
        .arg(&fixtures_dir)
        .assert()
        .success();

    Command::cargo_bin("brain")
        .unwrap()
        .env("OMNIAGENT_ADE_DATA_DIR", data_dir.path())
        .arg("stats")
        .assert()
        .success()
        .stdout(predicate::str::contains("projects: 1"))
        .stdout(predicate::str::contains("sample-project"));
}

#[test]
fn search_with_no_matches_does_not_error() {
    let data_dir = tempdir().unwrap();
    Command::cargo_bin("brain")
        .unwrap()
        .env("OMNIAGENT_ADE_DATA_DIR", data_dir.path())
        .arg("search")
        .arg("nothing-will-ever-match-this-xyz")
        .assert()
        .success()
        .stdout(predicate::str::contains("no matches"));
}
