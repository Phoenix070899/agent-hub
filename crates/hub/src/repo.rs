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

/// A Worker's new worktree on branch `<type>/<task>`, from the HEAD of `from` (the checkout its
/// Orchestrator works in), outside the repo.
pub fn create_worktree(repo: &Path, branch: &str, from: &Path) -> Result<PathBuf> {
    parse_branch(branch)?;
    add_worktree(repo, branch, from, "HEAD")
}

/// Where a branch's worktree goes: `<worktrees>/<repo>/<branch, "/" as "-">`.
fn worktree_path(repo: &Path, branch: &str) -> PathBuf {
    let name = repo
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "repo".into());
    crate::paths::worktrees().join(name).join(branch.replace('/', "-"))
}

/// A new worktree on new branch `branch`, starting at `start` as `dir` resolves it.
fn add_worktree(repo: &Path, branch: &str, dir: &Path, start: &str) -> Result<PathBuf> {
    let path = worktree_path(repo, branch);
    if path.exists() {
        bail!("worktree {} already exists", path.display());
    }
    std::fs::create_dir_all(path.parent().unwrap())?;
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["worktree", "add", "-b", branch])
        .arg(&path)
        .arg(start)
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

/// An agent's new worktree on new branch `branch`, starting from branch or commit `base`.
pub fn new_branch_worktree(repo: &Path, branch: &str, base: &str) -> Result<PathBuf> {
    git(repo, &["check-ref-format", "--branch", branch])
        .with_context(|| format!("{branch:?} is not a branch name git takes"))?;
    add_worktree(repo, branch, repo, base)
}

/// A local branch and the checkout that has it, if one does.
#[derive(Debug, Clone, PartialEq)]
pub struct Branch {
    pub name: String,
    pub checkout: Option<PathBuf>,
}

/// The repo's checked-out branch (empty when detached) and its local branches, newest commit first.
pub fn branches(repo: &Path) -> Result<(String, Vec<Branch>)> {
    let current = git(repo, &["branch", "--show-current"])?.trim().to_string();
    let mut checkouts = std::collections::HashMap::new();
    let mut path = None;
    for line in git(repo, &["worktree", "list", "--porcelain"])?.lines() {
        if let Some(p) = line.strip_prefix("worktree ") {
            path = Some(PathBuf::from(p));
        } else if let Some(b) = line.strip_prefix("branch refs/heads/") {
            if let Some(p) = path.clone() {
                checkouts.insert(b.to_string(), p);
            }
        }
    }
    let names = git(
        repo,
        &[
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/heads",
        ],
    )?;
    let branches = names
        .lines()
        .filter(|n| !n.is_empty())
        .map(|name| Branch {
            name: name.to_string(),
            checkout: checkouts.get(name).cloned(),
        })
        .collect();
    Ok((current, branches))
}

/// A checkout of existing branch `branch` to work in: the one that already has it (the repo's
/// own included), else a new worktree.
pub fn checkout(repo: &Path, branch: &str) -> Result<PathBuf> {
    let (_, branches) = branches(repo)?;
    let found = branches
        .iter()
        .find(|b| b.name == branch)
        .with_context(|| format!("{repo} has no branch {branch}", repo = repo.display()))?;
    if let Some(path) = &found.checkout {
        return Ok(path.clone());
    }
    let path = worktree_path(repo, branch);
    if path.exists() {
        bail!("worktree {} already exists", path.display());
    }
    std::fs::create_dir_all(path.parent().unwrap())?;
    git(repo, &["worktree", "add", &path.display().to_string(), branch])?;
    Ok(path)
}

/// The most diff text a review carries; past it the rest is cut, and the review says so.
const DIFF_LIMIT: usize = 2_000_000;

/// What a Worker changed in `cwd`, as one unified diff: in a worktree, everything since it
/// branched from the repo's HEAD, commits and uncommitted work alike; in place, everything not
/// yet committed. New files count. Returns the diff and whether it was cut short.
pub fn diff(repo: &Path, cwd: &Path, worktree: bool) -> Result<(String, bool)> {
    let base = if worktree {
        let main = git(repo, &["rev-parse", "HEAD"])?;
        git(cwd, &["merge-base", "HEAD", main.trim()])?
    } else {
        git(cwd, &["rev-parse", "HEAD"])?
    };
    let mut out = git(cwd, &["diff", "--no-color", "--no-ext-diff", base.trim()])?;
    let untracked = git(cwd, &["ls-files", "--others", "--exclude-standard", "-z"])?;
    for file in untracked.split('\0').filter(|f| !f.is_empty()) {
        if out.len() > DIFF_LIMIT {
            break;
        }
        // Exit 1 means the files differ, which a new file always does.
        let output = Command::new("git")
            .arg("-C")
            .arg(cwd)
            .args([
                "diff",
                "--no-color",
                "--no-ext-diff",
                "--no-index",
                "--",
                "/dev/null",
                file,
            ])
            .output()
            .context("running git diff")?;
        out.push_str(&String::from_utf8_lossy(&output.stdout));
    }
    let cut = out.len() > DIFF_LIMIT;
    if cut {
        let mut end = DIFF_LIMIT;
        while !out.is_char_boundary(end) {
            end -= 1;
        }
        // Whole lines only.
        end = out[..end].rfind('\n').map_or(0, |n| n + 1);
        out.truncate(end);
    }
    Ok((out, cut))
}

/// Commits everything uncommitted in `dir`, new files included. Returns whether there was any.
pub fn commit_all(dir: &Path, message: &str) -> Result<bool> {
    if git(dir, &["status", "--porcelain"])?.trim().is_empty() {
        return Ok(false);
    }
    git(dir, &["add", "-A"])?;
    git(dir, &["commit", "-qm", message])?;
    Ok(true)
}

/// Merges `branch` into the repo's checked-out branch with a merge commit, and returns that
/// branch's name. A merge that stops on conflicts is undone, so the repo is left as it was.
pub fn merge(repo: &Path, branch: &str) -> Result<String> {
    let into = git(repo, &["rev-parse", "--abbrev-ref", "HEAD"])?.trim().to_string();
    if let Err(error) = git(repo, &["merge", "--no-ff", "--no-edit", branch]) {
        let _ = git(repo, &["merge", "--abort"]);
        bail!("{branch} does not merge cleanly into {into}, so nothing was merged. {error:#}");
    }
    Ok(into)
}

/// Removes a Worker's worktree folder, uncommitted work and all; its branch stays.
pub fn remove_worktree(repo: &Path, path: &Path) -> Result<()> {
    git(repo, &["worktree", "remove", "--force", &path.display().to_string()])?;
    Ok(())
}

/// Runs git in `dir` and returns what it printed; its error output when it fails.
fn git(dir: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .context("running git")?;
    if !output.status.success() {
        bail!(
            "git {} failed: {}",
            args[0],
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
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
