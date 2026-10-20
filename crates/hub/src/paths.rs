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

/// The Hub Daemon's own files. `HUB_STATE` overrides `~/.agent-hub`; set but empty counts as
/// unset, as the app reads it, rather than as the current directory.
pub fn state_dir() -> PathBuf {
    state_dir_from(std::env::var_os("HUB_STATE"))
}

fn state_dir_from(hub_state: Option<std::ffi::OsString>) -> PathBuf {
    match hub_state.filter(|dir| !dir.is_empty()) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_hub_state_means_the_default() {
        let default = home().join(".agent-hub");
        assert_eq!(state_dir_from(None), default);
        assert_eq!(state_dir_from(Some("".into())), default);
        assert_eq!(state_dir_from(Some("/tmp/hub".into())), PathBuf::from("/tmp/hub"));
    }
}
