//! The Orchestrator: how the daemon starts it, and `hub` with no command, which attaches to it.

use std::path::Path;

use anyhow::{Context, Result};
use serde_json::json;

use crate::db::Agent;
use crate::{attach, proto, repo};

/// The first message of a resumed Orchestrator session.
const RESUMED: &str = "Your terminal was restarted. Run `hub worker list`, give the human a Summary, \
                       and start the listener if Workers are open.";

/// Arguments after `claude` for a repo's Orchestrator: a new session, or its saved one resumed.
/// A new session given a `request` starts on it, as if the human had typed it first.
pub fn orchestrator_args(
    hub: &Path,
    repo: &Path,
    worktree: Option<(&str, &str)>,
    session_id: &str,
    resume: bool,
    request: Option<&str>,
    extra: &[String],
) -> Result<Vec<String>> {
    let orchestrator =
        std::fs::read_to_string(hub.join("orchestrator.md"))?.replace("$AGENT_HUB", &hub.display().to_string());
    let preferences = std::fs::read_to_string(hub.join("memory").join("preferences.md")).unwrap_or_default();
    let mut prompt = format!(
        "{orchestrator}\n\n# Preferences\n\n{preferences}\n\nRepo for this Hub Session: {}",
        repo.display()
    );
    if let Some((cwd, branch)) = worktree {
        prompt += &format!(
            "\nYou work in your own worktree {cwd} on branch {branch}, apart from other Orchestrators in this repo. \
             Workers you start in place work there too, and new Worker worktrees branch from it."
        );
    }
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
        args.extend(first_request(request));
    }
    Ok(args)
}

/// Arguments after `claude` for a Normal session: plain Claude Code in the repo, new or resumed.
pub fn claude_args(agent: &Agent, resume: bool, request: Option<&str>, extra: &[String]) -> Vec<String> {
    let name = agent.name.clone().unwrap_or_else(|| {
        let repo = Path::new(&agent.repo);
        repo.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    });
    let mut args = vec!["-n".to_string(), format!("echo: {name}")];
    args.extend(extra.iter().cloned());
    if resume {
        args.extend(["--resume".into(), agent.session_id.clone()]);
    } else {
        args.extend(["--session-id".into(), agent.session_id.clone()]);
        args.extend(first_request(request));
    }
    args
}

/// A new session's first message, after `--` so a request starting with `-` is not an option.
fn first_request(request: Option<&str>) -> Vec<String> {
    request
        .map(|r| vec!["--".to_string(), r.to_string()])
        .unwrap_or_default()
}

/// Starts this repo's first Orchestrator in the Hub Daemon, or finds it running, then attaches to it.
pub fn run(extra: Vec<String>) -> Result<()> {
    let repo = repo::root(&std::env::current_dir()?)?;
    let repo = repo.display().to_string();
    let opened =
        proto::call("session.open", json!({ "repo": repo, "args": extra })).context("starting the Orchestrator")?;
    attach::run(json!({ "agent": opened["agent"] }), "the Orchestrator")
}
