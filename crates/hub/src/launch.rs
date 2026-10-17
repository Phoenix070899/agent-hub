//! The Orchestrator: how the daemon starts it, and `hub` with no command, which attaches to it.

use std::path::Path;

use anyhow::{Context, Result};
use serde_json::json;

use crate::{attach, proto, repo};

/// The first message of a resumed Orchestrator session.
const RESUMED: &str = "Your terminal was restarted. Run `hub worker list`, give the human a Summary, \
                       and start the listener if Workers are open.";

/// Arguments after `claude` for a repo's Orchestrator: a new session, or its saved one resumed.
pub fn orchestrator_args(
    hub: &Path,
    repo: &Path,
    session_id: &str,
    resume: bool,
    extra: &[String],
) -> Result<Vec<String>> {
    let orchestrator =
        std::fs::read_to_string(hub.join("orchestrator.md"))?.replace("$AGENT_HUB", &hub.display().to_string());
    let preferences = std::fs::read_to_string(hub.join("memory").join("preferences.md")).unwrap_or_default();
    let prompt = format!(
        "{orchestrator}\n\n# Preferences\n\n{preferences}\n\nRepo for this Hub Session: {}",
        repo.display()
    );
    let name = repo
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut args = vec![
        "-n".to_string(),
        format!("hub: {name}"),
        "--plugin-dir".into(),
        hub.join("mod").display().to_string(),
        "--add-dir".into(),
        hub.display().to_string(),
        "--append-system-prompt".into(),
        prompt,
    ];
    args.extend(extra.iter().cloned());
    if resume {
        args.extend(["--resume".into(), session_id.into(), "--".into(), RESUMED.into()]);
    } else {
        args.extend(["--session-id".into(), session_id.into()]);
    }
    Ok(args)
}

/// Starts this repo's Orchestrator in the Hub Daemon, or finds it running, then attaches to it.
pub fn run(extra: Vec<String>) -> Result<()> {
    let repo = repo::root(&std::env::current_dir()?)?;
    let repo = repo.display().to_string();
    proto::call("session.open", json!({ "repo": repo, "args": extra })).context("starting the Orchestrator")?;
    attach::run(json!({ "orchestrator": repo }), "the Orchestrator")
}
