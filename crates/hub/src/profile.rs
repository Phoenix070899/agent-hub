//! Agent Profiles: `profiles/<name>.md`, frontmatter plus the role text.

use std::path::Path;

use anyhow::{bail, Context, Result};

#[derive(Debug, Clone)]
pub struct Profile {
    pub name: String,
    pub model: String,
    pub effort: Option<String>,
    pub tools: Vec<String>,
    pub skills: Vec<String>,
    pub context: Vec<String>,
    pub role: String,
    pub description: String,
    /// It edits files, so its tries of a Task differ and are worth comparing.
    pub writes: bool,
}

pub fn load(hub: &Path, name: &str) -> Result<Profile> {
    let path = hub.join("profiles").join(format!("{name}.md"));
    if !path.exists() {
        let mut known: Vec<String> = std::fs::read_dir(hub.join("profiles"))?
            .flatten()
            .filter_map(|entry| entry.path().file_stem().map(|stem| stem.to_string_lossy().into_owned()))
            .collect();
        known.sort();
        bail!("unknown profile {name:?}; known: {}", known.join(", "));
    }
    parse(
        name,
        &std::fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?,
    )
}

fn parse(name: &str, text: &str) -> Result<Profile> {
    let mut parts = text.splitn(3, "---");
    let (_, front, body) = match (parts.next(), parts.next(), parts.next()) {
        (Some(a), Some(b), Some(c)) => (a, b, c),
        _ => bail!("profile {name}: missing --- frontmatter"),
    };
    let field = |key: &str| {
        front.lines().find_map(|line| {
            let (k, v) = line.split_once(':')?;
            (k.trim() == key).then(|| v.trim().to_string())
        })
    };
    let list = |key: &str| -> Vec<String> {
        field(key)
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(String::from)
            .collect()
    };
    let cli = field("cli").unwrap_or_default();
    if cli != "claude" {
        bail!("profile {name}: cli {cli:?} is not supported yet (only claude)");
    }
    Ok(Profile {
        name: field("name").unwrap_or_else(|| name.to_string()),
        model: field("model").with_context(|| format!("profile {name}: no model"))?,
        effort: field("effort").filter(|v| !v.is_empty()),
        tools: list("tools"),
        skills: list("skills"),
        context: list("context"),
        role: body.trim().to_string(),
        description: field("description").unwrap_or_default(),
        writes: field("writes").as_deref() == Some("true"),
    })
}

/// Every profile that loads, by name.
pub fn all(hub: &Path) -> Result<Vec<Profile>> {
    let mut names: Vec<String> = std::fs::read_dir(hub.join("profiles"))?
        .flatten()
        .filter(|entry| entry.path().extension().is_some_and(|e| e == "md"))
        .filter_map(|entry| entry.path().file_stem().map(|stem| stem.to_string_lossy().into_owned()))
        .collect();
    names.sort();
    Ok(names.iter().filter_map(|name| load(hub, name).ok()).collect())
}

/// Worker Contract, Preferences, then the profile's role, skills, and context.
pub fn system_prompt(hub: &Path, profile: &Profile) -> Result<String> {
    let mut parts = vec![
        std::fs::read_to_string(hub.join("worker-contract.md"))?,
        format!(
            "# Preferences\n\nApply these standing instructions from the human.\n\n{}",
            std::fs::read_to_string(hub.join("memory").join("preferences.md")).unwrap_or_default()
        ),
        format!("# Your role: {}\n\n{}", profile.name, profile.role),
    ];
    if !profile.skills.is_empty() {
        parts.push(format!(
            "Use these skills when they fit the Task: {}.",
            profile.skills.join(", ")
        ));
    }
    if !profile.context.is_empty() {
        parts.push(format!(
            "Before starting, read whichever of these files exist (paths relative to your working directory unless absolute): {}.",
            profile.context.join(", ")
        ));
    }
    Ok(parts.join("\n\n"))
}

/// The first message of a resumed Worker session.
const RESUMED: &str = "Your terminal was restarted. Continue your Task from where you left off: \
                       check what is already done before repeating anything, then finish with hub done.";

/// How a Worker's Claude session begins: a new session on its Task, or a resumed one.
pub enum Launch<'a> {
    New { spec: &'a str },
    Resume,
}

/// Arguments after `claude` for a Worker session.
pub fn claude_args(
    hub: &Path,
    profile: &Profile,
    title: &str,
    session_id: &str,
    launch: Launch,
) -> Result<Vec<String>> {
    let mut args: Vec<String> = vec![
        "--model".into(),
        profile.model.clone(),
        "--permission-mode".into(),
        "auto".into(),
        "--settings".into(),
        hub.join("settings").join("worker.json").display().to_string(),
        "--disallowedTools".into(),
        "AskUserQuestion".into(),
        "--add-dir".into(),
        hub.display().to_string(),
        "-n".into(),
        format!("{}: {title}", profile.name),
    ];
    if let Some(effort) = &profile.effort {
        args.extend(["--effort".into(), effort.clone()]);
    }
    if !profile.tools.is_empty() {
        args.extend(["--tools".into(), profile.tools.join(",")]);
    }
    args.extend(["--append-system-prompt".into(), system_prompt(hub, profile)?]);
    match launch {
        Launch::New { spec } => args.extend(["--session-id".into(), session_id.into(), "--".into(), spec.into()]),
        Launch::Resume => args.extend(["--resume".into(), session_id.into(), "--".into(), RESUMED.into()]),
    }
    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NARUTO: &str = "---\nname: naruto\ndescription: writes code\ncli: claude\nmodel: claude-sonnet-5-5\neffort: high\ntools: Bash, Read, Edit\nskills:\ncontext: AGENTS.md, CLAUDE.md\nwrites: true\n---\n\nYou implement.\n";

    #[test]
    fn parses_frontmatter_and_role() {
        let profile = parse("naruto", NARUTO).unwrap();
        assert_eq!(profile.model, "claude-sonnet-5-5");
        assert_eq!(profile.effort.as_deref(), Some("high"));
        assert_eq!(profile.tools, ["Bash", "Read", "Edit"]);
        assert!(profile.skills.is_empty());
        assert_eq!(profile.context, ["AGENTS.md", "CLAUDE.md"]);
        assert_eq!(profile.role, "You implement.");
    }

    #[test]
    fn refuses_other_clis() {
        let text = NARUTO.replace("cli: claude", "cli: codex");
        assert!(parse("naruto", &text)
            .unwrap_err()
            .to_string()
            .contains("not supported"));
    }

    #[test]
    fn real_profiles_load() {
        let hub = crate::paths::hub_dir();
        for name in ["hinata", "naruto", "jiraiya", "sasuke", "ino", "bash"] {
            load(&hub, name).unwrap_or_else(|e| panic!("{name}: {e}"));
        }
    }
}
