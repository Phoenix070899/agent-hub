//! `hub` with no command: start (or resume) the Orchestrator for the repo here.

use std::os::unix::process::CommandExt;
use std::process::Command;

use anyhow::{Context, Result};
use serde_json::json;

use crate::{paths, proto, repo};

pub fn run(extra: Vec<String>) -> Result<()> {
    let hub = paths::hub_dir();
    let repo = repo::root(&std::env::current_dir()?)?;
    proto::call("ping", json!({})).context("starting the Hub Daemon")?;

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
    let error = Command::new("claude")
        .current_dir(&repo)
        .env("AGENT_HUB", &hub)
        .arg("-n")
        .arg(format!("hub: {name}"))
        .arg("--plugin-dir")
        .arg(hub.join("mod"))
        .arg("--add-dir")
        .arg(&hub)
        .arg("--append-system-prompt")
        .arg(prompt)
        .args(extra)
        .exec();
    Err(error).context("starting claude")
}
