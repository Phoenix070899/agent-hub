//! Where Agent Hub keeps its files.

use std::path::PathBuf;

/// The agent-hub repo (profiles, Worker Contract, prompts). `AGENT_HUB` overrides the build location.
pub fn hub_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("AGENT_HUB") {
        return PathBuf::from(dir);
    }
    let built = PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."));
    built.canonicalize().unwrap_or(built)
}

/// The Hub Daemon's own files. `HUB_STATE` overrides `~/.agent-hub`.
pub fn state_dir() -> PathBuf {
    match std::env::var_os("HUB_STATE") {
        Some(dir) => PathBuf::from(dir),
        None => home().join(".agent-hub"),
    }
}

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").expect("HOME is set"))
}

pub fn socket() -> PathBuf {
    state_dir().join("hubd.sock")
}

pub fn database() -> PathBuf {
    state_dir().join("hub.db")
}

pub fn log() -> PathBuf {
    state_dir().join("hubd.log")
}

pub fn worktrees() -> PathBuf {
    state_dir().join("worktrees")
}

/// Claude Code's transcript for a session, once its first turn has started.
pub fn transcript_exists(session_id: &str) -> bool {
    let Ok(projects) = std::fs::read_dir(home().join(".claude").join("projects")) else {
        return false;
    };
    let file = format!("{session_id}.jsonl");
    projects.flatten().any(|project| project.path().join(&file).exists())
}
