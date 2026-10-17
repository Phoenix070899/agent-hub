//! Git: which repo a command runs in, and Worker worktrees.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};

pub const BRANCH_TYPES: [&str; 9] = [
    "feat", "fix", "chore", "refactor", "docs", "test", "perf", "ci", "build",
];

/// The repo's main checkout: a Hub Session's identity, the same from any of its worktrees.
pub fn root(start: &Path) -> Result<PathBuf> {
    let output = Command::new("git")
        .arg("-C")
        .arg(start)
        .args(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        .output()
        .context("running git")?;
    if !output.status.success() {
        bail!("{} is not inside a git repository", start.display());
    }
    let common = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    let root = common.parent().context("git common dir has no parent")?;
    Ok(root.canonicalize().unwrap_or_else(|_| root.to_path_buf()))
}

/// Parses `<type>/<task>`, e.g. `feat/magic-link-login`.
pub fn parse_branch(branch: &str) -> Result<(&str, &str)> {
    let (kind, task) = branch.split_once('/').unwrap_or((branch, ""));
    if !BRANCH_TYPES.contains(&kind) || task.is_empty() || task.contains('/') {
        bail!(
            "use new:<type>/<task>, type one of {} (e.g. new:feat/magic-link-login)",
            BRANCH_TYPES.join(", ")
        );
    }
    Ok((kind, task))
}

/// A new worktree on branch `<type>/<task>` from the repo's current HEAD, outside the repo.
pub fn create_worktree(repo: &Path, branch: &str) -> Result<PathBuf> {
    let (kind, task) = parse_branch(branch)?;
    let name = repo
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "repo".into());
    let path = crate::paths::worktrees().join(name).join(format!("{kind}-{task}"));
    if path.exists() {
        bail!("worktree {} already exists", path.display());
    }
    std::fs::create_dir_all(path.parent().unwrap())?;
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["worktree", "add", "-b", branch])
        .arg(&path)
        .arg("HEAD")
        .output()
        .context("running git worktree add")?;
    if !output.status.success() {
        bail!(
            "git worktree add failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_must_be_type_slash_task() {
        assert_eq!(parse_branch("feat/login").unwrap(), ("feat", "login"));
        assert!(parse_branch("feature/login").is_err());
        assert!(parse_branch("feat/").is_err());
        assert!(parse_branch("feat/a/b").is_err());
        assert!(parse_branch("login").is_err());
    }
}
