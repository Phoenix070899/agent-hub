//! Reading a Worker's screen: what Claude Code's TUI is showing right now.

/// What a Worker's screen says about it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Look {
    /// Claude's "trust this folder?" dialog, shown once per new folder.
    TrustPrompt,
    /// A tool permission prompt ("Do you want to proceed?" with numbered choices).
    PermissionPrompt,
    /// A turn is running: the spinner line, e.g. `· Churning… (21s · ↓ 81 tokens)`.
    Working,
    /// Waiting at its input box.
    Idle,
}

pub fn look(screen: &str) -> Look {
    if screen.contains("Yes, I trust this folder") {
        return Look::TrustPrompt;
    }
    let lines: Vec<&str> = screen.lines().map(str::trim).collect();
    let asks = lines.iter().any(|line| line.starts_with("Do you want to"));
    let choices = lines.iter().any(|line| line.contains("1. Yes"));
    if asks && choices {
        return Look::PermissionPrompt;
    }
    if lines.iter().any(|line| is_spinner(line)) {
        return Look::Working;
    }
    Look::Idle
}

/// The spinner line: a glyph, a word ending in "…", then "(<digits>".
fn is_spinner(line: &str) -> bool {
    let Some(at) = line.find("… (") else {
        return false;
    };
    let after = &line[at + "… (".len()..];
    let glyph_word = line.split_whitespace().count() >= 2 && !line.starts_with('❯');
    glyph_word && after.chars().next().is_some_and(|c| c.is_ascii_digit())
}

/// The permission prompt's own lines: what is asked about, up to "Do you want to ...".
pub fn prompt_lines(screen: &str) -> String {
    let lines: Vec<&str> = screen.lines().map(str::trim).collect();
    let Some(ask) = lines.iter().rposition(|line| line.starts_with("Do you want to")) else {
        return String::new();
    };
    let start = lines[..ask]
        .iter()
        .rposition(|line| line.starts_with('─'))
        .map_or(0, |at| at + 1);
    lines[start..=ask]
        .iter()
        .filter(|line| !line.is_empty() && !line.starts_with('╌'))
        .copied()
        .collect::<Vec<_>>()
        .join("\n")
}

/// The last `count` non-blank lines, right-trimmed.
pub fn tail(screen: &str, count: usize) -> String {
    let lines: Vec<&str> = screen
        .lines()
        .map(str::trim_end)
        .filter(|line| !line.is_empty())
        .collect();
    lines[lines.len().saturating_sub(count)..].join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_trust_dialog() {
        let screen = " Quick safety check\n ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm";
        assert_eq!(look(screen), Look::TrustPrompt);
    }

    #[test]
    fn reads_a_permission_prompt() {
        let screen = "Bash command\n  rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n  2. No, and tell Claude";
        assert_eq!(look(screen), Look::PermissionPrompt);
    }

    #[test]
    fn reads_the_spinner_as_working() {
        let screen = "❯ Run it\n⏺ Sleeping 20 seconds · 17s\n· Churning… (21s · ↓ 81 tokens)\n────\n❯ \n────";
        assert_eq!(look(screen), Look::Working);
    }

    #[test]
    fn a_finished_turn_is_idle() {
        let screen = "⏺ DONE\n✻ Cogitated for 17s · done 5:29 PM\n────\n❯ \n────\n  Haiku 5.5";
        assert_eq!(look(screen), Look::Idle);
    }

    #[test]
    fn typed_ellipsis_in_the_prompt_is_not_a_spinner() {
        assert_eq!(look("❯ wait… (1 more thing)"), Look::Idle);
    }

    #[test]
    fn prompt_lines_are_the_box_above_the_question() {
        let screen = "⏺ Running…\n────────\n Bash command\n Remove junk\n╌╌╌╌\n rm -rf junk\n╌╌╌╌\n Do you want to proceed?\n ❯ 1. Yes";
        assert_eq!(
            prompt_lines(screen),
            "Bash command\nRemove junk\nrm -rf junk\nDo you want to proceed?"
        );
    }

    #[test]
    fn tail_keeps_the_last_non_blank_lines() {
        assert_eq!(tail("a\n\nb  \nc\n\n", 2), "b\nc");
    }
}
