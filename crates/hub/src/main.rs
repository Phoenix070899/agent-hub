//! `hub`: the Agent Hub CLI. With no command it starts the Orchestrator for the repo here.

mod attach;
mod daemon;
mod db;
mod launch;
mod paths;
mod profile;
mod proto;
mod pty;
mod push;
mod remote;
mod repo;
mod screen;

use std::io::Read;
use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use serde_json::{json, Value};

#[derive(Parser)]
#[command(
    name = "hub",
    about = "Agent Hub. Run `hub` with no command in a repo to start its Orchestrator.",
    after_help = "Orchestrator: hub worker start|list|read|send|key|close|resume, hub wait, hub reply, hub inbox, hub status\n\
                  Worker:       hub ask, hub send, hub done\n\
                  Human:        hub attach <w12|a3> [--follow], hub open <w>"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the Hub Daemon in the foreground (any other command starts it when needed).
    Daemon,
    /// Stop the Hub Daemon.
    Shutdown {
        /// Also kill live Workers.
        #[arg(long)]
        force: bool,
    },
    /// Repos the daemon knows, each with its agents (Orchestrators and Normal sessions).
    Sessions,
    /// Dashboard rows for this repo's Workers.
    Status {
        #[arg(long)]
        json: bool,
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// Manage Workers (Orchestrator).
    #[command(subcommand)]
    Worker(WorkerCommand),
    /// Block until Workers send messages, print them, and mark them delivered (Orchestrator).
    Wait {
        /// Seconds to wait before returning empty.
        #[arg(long, default_value_t = 3600)]
        timeout: u64,
        #[arg(long)]
        json: bool,
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// Answer a Worker's question (Orchestrator).
    Reply {
        /// Message id, e.g. 12 or #12.
        message: String,
        /// The answer; "-" reads it from stdin.
        text: String,
    },
    /// Unanswered questions in this repo (Orchestrator).
    Inbox {
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// Ask the Orchestrator and wait for the answer (Worker).
    Ask {
        /// The question; "-" reads it from stdin.
        question: Option<String>,
        /// Keep waiting on an earlier question instead of asking a new one.
        #[arg(long, value_name = "ID")]
        wait: Option<String>,
        /// Seconds to wait before giving up for now.
        #[arg(long, default_value_t = 540)]
        timeout: u64,
    },
    /// Tell the Orchestrator something without waiting (Worker).
    Send {
        #[arg(long = "type", value_enum)]
        kind: SendKind,
        /// The message; "-" reads it from stdin.
        text: String,
    },
    /// Send the Final Report, exactly once (Worker).
    Done {
        #[arg(long, value_enum)]
        state: DoneState,
        /// The Final Report; "-" reads it from stdin.
        report: String,
    },
    /// Claude Code Notification hook for Workers (reads the hook JSON on stdin).
    Notify,
    /// Make this terminal a Worker's (w12) or an agent's (a3) terminal; Ctrl-] detaches.
    Attach {
        target: String,
        /// Stay and attach again whenever it restarts, until it is closed (Echo's multiplexer
        /// panes run this).
        #[arg(long)]
        follow: bool,
        /// One of Echo's terminal panes: Ctrl-] does not detach, and the screen stays when the
        /// terminal ends.
        #[arg(long, hide = true, conflicts_with = "follow")]
        echo: bool,
    },
    /// Open the Worker's terminal in a new Ghostty window.
    Open { worker: String },
    /// Echo Remote, the phone web app over Tailscale: turn it on or off, make a new pairing link
    /// (unpairing every phone), or show how it stands.
    Remote {
        #[arg(value_enum, default_value_t = RemoteAction::Status)]
        action: RemoteAction,
        /// The local port to serve on (with `on`).
        #[arg(long)]
        port: Option<u16>,
    },
    /// Echo's multiplexer panes: runs the line in `HUB_MUX` (from the daemon's `mux.command`) in
    /// a login shell, in place of this process.
    #[command(hide = true)]
    Mux,
}

#[derive(Subcommand)]
enum WorkerCommand {
    /// Start a Worker from an Agent Profile on one Task.
    Start {
        profile: String,
        #[arg(long, conflicts_with = "spec_file")]
        spec: Option<String>,
        #[arg(long)]
        spec_file: Option<PathBuf>,
        /// current, new:<type>/<task>, or path:<abs worktree path>.
        #[arg(long, default_value = "current")]
        worktree: String,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long)]
        json: bool,
    },
    /// Workers not yet closed.
    List {
        #[arg(long)]
        json: bool,
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// Print a Worker's screen.
    Read {
        worker: String,
        /// Only the last N non-blank lines.
        #[arg(long, default_value_t = 0)]
        lines: u64,
    },
    /// Type text into a Worker's terminal, then Enter.
    Send {
        worker: String,
        text: String,
        #[arg(long)]
        no_enter: bool,
    },
    /// Press keys in a Worker's terminal: enter, esc, up, down, left, right, tab, space, ctrl-c, or one character.
    Key {
        worker: String,
        #[arg(required = true)]
        keys: Vec<String>,
    },
    /// Stop a Worker's terminal (its worktree stays).
    Close { worker: String },
    /// Restart a lost or exited Worker on its Claude session.
    Resume { worker: String },
}

#[derive(Clone, Copy, ValueEnum)]
enum RemoteAction {
    On,
    Off,
    Pair,
    Status,
}

#[derive(Clone, Copy, ValueEnum)]
enum SendKind {
    Escalation,
    Status,
}

#[derive(Clone, Copy, ValueEnum)]
enum DoneState {
    Done,
    Blocked,
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let launches = args.first().is_none_or(|first| {
        first.starts_with('-') && !["-h", "--help", "-V", "--version"].contains(&first.as_str())
            || launch::agent_id(first).is_some()
    });
    let result = if launches {
        launch::run(args).map(|_| ExitCode::SUCCESS)
    } else {
        run(Cli::parse())
    };
    match result {
        Ok(code) => code,
        Err(error) => {
            eprintln!("hub: {error:#}");
            ExitCode::FAILURE
        }
    }
}

/// `w12`, `12`, or `#12`.
fn parse_id(text: &str) -> Result<i64> {
    text.trim_start_matches(['w', '#'])
        .parse()
        .with_context(|| format!("{text:?} is not an id like w12"))
}

fn text_arg(text: &str) -> Result<String> {
    if text == "-" {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        Ok(buf)
    } else {
        Ok(text.to_string())
    }
}

/// The Orchestrator this `hub` runs in (`HUB_AGENT`, set by the daemon), if any.
fn agent_env() -> Option<i64> {
    std::env::var("HUB_AGENT").ok().and_then(|id| id.parse().ok())
}

fn repo_arg(repo: Option<PathBuf>) -> Result<String> {
    let start = match repo {
        Some(path) => path,
        None => std::env::current_dir()?,
    };
    Ok(repo::root(&start)?.display().to_string())
}

/// This Worker's id, from the environment the daemon started it with.
fn this_worker() -> Result<i64> {
    match std::env::var("HUB_WORKER") {
        Ok(id) => parse_id(&id),
        Err(_) => bail!("not inside a Worker (HUB_WORKER is unset)"),
    }
}

fn print_json(value: &Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

fn print_remote(status: &Value) {
    let on = status["enabled"].as_bool() == Some(true);
    println!("Echo Remote is {}.", if on { "on" } else { "off" });
    if let Some(error) = status["error"].as_str() {
        println!("Problem: {error}");
    }
    match status["tailscale"].as_str() {
        Some("missing") => {
            println!("Tailscale: not installed. Get it on this Mac and the phone: https://tailscale.com/download")
        }
        Some("ready") | Some("test") => {}
        Some(other) => println!("Tailscale: {other}"),
        None => {}
    }
    if on {
        match status["url"].as_str() {
            Some(url) => println!("Phone address: {url}"),
            None => println!("On this Mac only: {}", status["local"].as_str().unwrap_or("")),
        }
        if let Some(link) = status["pairLink"].as_str() {
            println!("Pair a phone by opening this link on it (keep it private): {link}");
        }
        println!("Phones with notifications: {}", status["phones"]);
    }
}

fn run(cli: Cli) -> Result<ExitCode> {
    match cli.command {
        Command::Daemon => daemon::run()?,
        Command::Sessions => {
            let result = proto::call("sessions.list", json!({}))?;
            for session in result["sessions"].as_array().into_iter().flatten() {
                println!("{}", session["repo"].as_str().unwrap_or(""));
                for agent in session["agents"].as_array().into_iter().flatten() {
                    let live = if agent["live"].as_bool() == Some(true) {
                        "live"
                    } else {
                        "stopped"
                    };
                    let kind = match agent["kind"].as_str() {
                        Some("claude") => "Normal",
                        Some("terminal") => "Terminal",
                        _ => "Orchestrator",
                    };
                    println!(
                        "  a{:<4} {live:<8} {kind:<13} {}",
                        agent["id"],
                        agent["name"].as_str().unwrap_or("(unnamed)")
                    );
                }
            }
        }
        Command::Shutdown { force } => {
            proto::call("shutdown", json!({ "force": force }))?;
        }
        Command::Remote { action, port } => {
            let status = match action {
                RemoteAction::On => proto::call("remote.enable", json!({ "port": port }))?,
                RemoteAction::Off => proto::call("remote.disable", json!({}))?,
                RemoteAction::Pair => proto::call("remote.pair", json!({}))?,
                RemoteAction::Status => proto::call("remote.status", json!({}))?,
            };
            print_remote(&status);
        }
        Command::Status { json, repo } => {
            let result = proto::call("status", json!({ "repo": repo_arg(repo)? }))?;
            if json {
                println!("{}", serde_json::to_string(&result["workers"])?);
            } else {
                for row in result["workers"].as_array().into_iter().flatten() {
                    println!(
                        "{:<5} {:<8} {:<10} {}",
                        row["id"].as_str().unwrap_or(""),
                        row["profile"].as_str().unwrap_or(""),
                        row["state"].as_str().unwrap_or(""),
                        row["title"].as_str().unwrap_or("")
                    );
                }
            }
        }
        Command::Worker(command) => return worker(command),
        Command::Wait { timeout, json, repo } => {
            let result = proto::call(
                "wait",
                json!({ "repo": repo_arg(repo)?, "agent": agent_env(), "timeout_ms": timeout * 1000 }),
            )?;
            if json {
                return print_json(&result).map(|_| ExitCode::SUCCESS);
            }
            let messages = result["messages"].as_array().cloned().unwrap_or_default();
            if messages.is_empty() {
                println!("No messages in {timeout}s. Run the backstop, then wait again.");
            }
            for message in messages {
                print_message(&message);
            }
        }
        Command::Reply { message, text } => {
            proto::call("reply", json!({ "id": parse_id(&message)?, "body": text_arg(&text)? }))?;
        }
        Command::Inbox { repo } => {
            let result = proto::call("inbox", json!({ "repo": repo_arg(repo)? }))?;
            let open = result["open_questions"].as_array().cloned().unwrap_or_default();
            if open.is_empty() {
                println!("No unanswered questions.");
            }
            for question in open {
                println!(
                    "#{} from w{}:\n{}\n",
                    question["id"],
                    question["worker_id"],
                    question["body"].as_str().unwrap_or("")
                );
            }
        }
        Command::Ask {
            question,
            wait,
            timeout,
        } => {
            let worker = this_worker()?;
            let mut params = json!({ "worker": worker, "timeout_ms": timeout * 1000 });
            match (wait, question) {
                (Some(id), _) => params["question"] = json!(parse_id(&id)?),
                (None, Some(text)) => params["body"] = json!(text_arg(&text)?),
                (None, None) => bail!("give a question, or --wait <id>"),
            }
            let result = proto::call("ask", params)?;
            let id = &result["question"];
            match result["answer"].as_str() {
                Some(answer) => println!("{answer}"),
                None => {
                    println!("No answer to question #{id} yet. Keep waiting: hub ask --wait {id}");
                    return Ok(ExitCode::from(3));
                }
            }
        }
        Command::Send { kind, text } => {
            let kind = match kind {
                SendKind::Escalation => "escalation",
                SendKind::Status => "status",
            };
            proto::call(
                "send",
                json!({ "worker": this_worker()?, "kind": kind, "body": text_arg(&text)? }),
            )?;
        }
        Command::Done { state, report } => {
            let state = match state {
                DoneState::Done => "done",
                DoneState::Blocked => "blocked",
            };
            proto::call(
                "done",
                json!({ "worker": this_worker()?, "state": state, "body": text_arg(&report)? }),
            )?;
            println!("Final Report sent. Stop here and stay idle.");
        }
        Command::Notify => notify(),
        Command::Attach { target, follow, echo } => {
            let parsed = attach::Target::parse(&target)?;
            if echo {
                attach::echo(parsed);
            } else if follow {
                attach::follow(parsed)?;
            } else {
                attach::run(parsed.params(), &target)?;
            }
        }
        Command::Open { worker } => open(parse_id(&worker)?)?,
        Command::Mux => {
            use std::os::unix::process::CommandExt;
            let line = std::env::var("HUB_MUX").context("HUB_MUX names the multiplexer command to run")?;
            let mut shell = std::process::Command::new(daemon::user_shell());
            shell.args(["-l", "-c", &line]);
            // What the agent that started Echo set must not reach the human's shells.
            for key in daemon::inherited_agent_vars() {
                shell.env_remove(key);
            }
            shell.env_remove("HUB_MUX");
            return Err(shell.exec()).context("starting the multiplexer");
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn print_message(m: &Value) {
    let id = &m["id"];
    let worker = m["worker"].as_str().unwrap_or("");
    let next = match m["kind"].as_str().unwrap_or("") {
        "question" => format!("Answer: hub reply {id} \"<answer>\""),
        "done" => format!("Settled. Validate the report, then: hub worker close {worker}"),
        "blocker" => format!(
            "Show the human the exact prompt. On their yes: hub worker key {worker} enter. On no: hub worker key {worker} esc, then hub worker send {worker} \"<what to do instead>\""
        ),
        "exited" => format!("No Final Report. Check: hub worker read {worker}; then start the Task again or report it"),
        "lost" => format!("Resume: hub worker resume {worker}"),
        "human" => "The human acted in the Hub App. Reflect it; do not redo it".to_string(),
        _ => String::new(),
    };
    let kind = match m["kind"].as_str().unwrap_or("") {
        "done" => format!("done ({})", m["state"].as_str().unwrap_or("")),
        other => other.to_string(),
    };
    println!(
        "#{id} {kind} from {worker} ({}: {})\n{}",
        m["profile"].as_str().unwrap_or(""),
        m["title"].as_str().unwrap_or(""),
        m["body"].as_str().unwrap_or("").trim_end()
    );
    if !next.is_empty() {
        println!("-> {next}");
    }
    println!("---");
}

fn worker(command: WorkerCommand) -> Result<ExitCode> {
    match command {
        WorkerCommand::Start {
            profile,
            spec,
            spec_file,
            worktree,
            title,
            repo,
            json,
        } => {
            let spec = match (spec, spec_file) {
                (Some(spec), _) => spec,
                (None, Some(file)) => {
                    std::fs::read_to_string(&file).with_context(|| format!("reading {}", file.display()))?
                }
                (None, None) => bail!("give --spec or --spec-file"),
            };
            let result = proto::call(
                "worker.start",
                json!({ "repo": repo_arg(repo)?, "profile": profile, "spec": spec, "worktree": worktree, "title": title,
                        "agent": agent_env() }),
            )?;
            if json {
                print_json(&result)?;
            } else {
                println!(
                    "Started {} ({profile}: {}) in {}{}",
                    result["id"].as_str().unwrap_or(""),
                    result["title"].as_str().unwrap_or(""),
                    result["cwd"].as_str().unwrap_or(""),
                    result["branch"]
                        .as_str()
                        .map(|b| format!(" on {b}"))
                        .unwrap_or_default()
                );
            }
        }
        WorkerCommand::List { json, repo } => {
            let result = proto::call("worker.list", json!({ "repo": repo_arg(repo)?, "agent": agent_env() }))?;
            if json {
                return print_json(&result).map(|_| ExitCode::SUCCESS);
            }
            let workers = result["workers"].as_array().cloned().unwrap_or_default();
            if workers.is_empty() {
                println!("No open Workers.");
            }
            for w in workers {
                let mut notes = Vec::new();
                if let Some(blocker) = w["blocker"].as_str() {
                    notes.push(format!("blocked: {blocker}"));
                }
                for q in w["open_questions"].as_array().into_iter().flatten() {
                    notes.push(format!("question #{q}"));
                }
                if !w["live"].as_bool().unwrap_or(false) {
                    notes.push("terminal closed".into());
                }
                println!(
                    "{:<5} {:<8} {:<8} {:>5}s quiet  {}  {}{}",
                    w["id"].as_str().unwrap_or(""),
                    w["profile"].as_str().unwrap_or(""),
                    w["state"].as_str().unwrap_or(""),
                    w["quiet_seconds"],
                    w["branch"].as_str().unwrap_or("in place"),
                    w["title"].as_str().unwrap_or(""),
                    if notes.is_empty() {
                        String::new()
                    } else {
                        format!("  [{}]", notes.join(", "))
                    }
                );
            }
        }
        WorkerCommand::Read { worker, lines } => {
            let result = proto::call("worker.read", json!({ "id": parse_id(&worker)?, "lines": lines }))?;
            println!("{}", result["screen"].as_str().unwrap_or("").trim_end());
        }
        WorkerCommand::Send { worker, text, no_enter } => {
            proto::call(
                "worker.send",
                json!({ "id": parse_id(&worker)?, "text": text, "enter": !no_enter }),
            )?;
        }
        WorkerCommand::Key { worker, keys } => {
            for key in &keys {
                daemon::key_bytes(key)?;
            }
            proto::call("worker.key", json!({ "id": parse_id(&worker)?, "keys": keys }))?;
        }
        WorkerCommand::Close { worker } => {
            proto::call("worker.close", json!({ "id": parse_id(&worker)? }))?;
        }
        WorkerCommand::Resume { worker } => {
            let result = proto::call("worker.resume", json!({ "id": parse_id(&worker)? }))?;
            println!("Resumed {}", result["id"].as_str().unwrap_or(""));
        }
    }
    Ok(ExitCode::SUCCESS)
}

/// The Notification hook must never break the Worker: it reports what it can and exits 0.
fn notify() {
    let report = || -> Result<()> {
        let Ok(worker) = this_worker() else { return Ok(()) };
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input)?;
        let event: Value = serde_json::from_str(&input).unwrap_or_default();
        let kind = event["notification_type"].as_str().unwrap_or("notification");
        let message = event["message"].as_str().or(event["title"].as_str()).unwrap_or("");
        proto::call("notify", json!({ "worker": worker, "kind": kind, "message": message }))?;
        Ok(())
    };
    if let Err(error) = report() {
        eprintln!("hub notify: {error:#}");
    }
}

/// A new Ghostty window attached to the Worker.
fn open(id: i64) -> Result<()> {
    let exe = std::env::current_exe()?;
    let mut command = format!("{} attach {id}", exe.display());
    if let Ok(state) = std::env::var("HUB_STATE") {
        command = format!("/usr/bin/env HUB_STATE={state} {command}");
    }
    let script = format!(
        "tell application \"Ghostty\"\n\
           set cfg to new surface configuration\n\
           set command of cfg to \"{}\"\n\
           new window with configuration cfg\n\
           activate\n\
         end tell",
        command.replace('\\', "\\\\").replace('"', "\\\"")
    );
    let status = std::process::Command::new("osascript").arg("-e").arg(script).status()?;
    if !status.success() {
        bail!("osascript could not open a Ghostty window");
    }
    Ok(())
}
