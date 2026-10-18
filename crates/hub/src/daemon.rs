//! The Hub Daemon: owns every Worker's terminal, worktree, and messages.
//! It never writes into the Orchestrator's terminal; the Orchestrator reads with `hub wait`.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use rusqlite::Connection;
use serde_json::{json, Value};

use crate::db::{self, kind, state, Worker};
use crate::launch;
use crate::paths;
use crate::profile::{self, Launch};
use crate::proto;
use crate::pty::{Live, Spawn};
use crate::repo;
use crate::screen::{self, Look};

/// How long a turn may take to start before `worker.start` gives up on it.
const START_TIMEOUT: Duration = Duration::from_secs(90);
/// An unchanged idle screen this long, with no Final Report, is a blocker.
const IDLE_BLOCKER: Duration = Duration::from_secs(60);
/// Settled Workers stay on the Dashboard this long.
const KEEP_SETTLED_SECONDS: i64 = 10 * 60;
/// Echo's Done list keeps a Final Report this long, unless the human dismisses it first.
const KEEP_REPORTS_SECONDS: i64 = 7 * 24 * 60 * 60;
const SCREEN_LINES: usize = 25;

pub struct Hub {
    db: Mutex<Connection>,
    live: Mutex<HashMap<i64, Arc<Live>>>,
    /// Each live agent's terminal (Orchestrators and Normal sessions), by agent id.
    agents: Mutex<HashMap<i64, Arc<Live>>>,
    /// When each Normal session's waiting permission prompt was first seen, by agent id.
    agent_prompts: Mutex<HashMap<i64, i64>>,
    /// The human's own shells in the Hub App's split panes: id to (repo, terminal). No watching,
    /// no messages; they live until they exit or are closed.
    shells: Mutex<HashMap<i64, (String, Arc<Live>)>>,
    /// The multiplexer shell showing each agent or Worker (`a3`, `w21`), by shell id.
    muxes: Mutex<HashMap<String, i64>>,
    tick: Mutex<u64>,
    changed: Condvar,
    usage: Mutex<Usage>,
    hub_dir: PathBuf,
    /// Tests only: run this program with the spec instead of `claude`.
    test_agent: Option<String>,
}

/// How often account usage is re-read while someone watches the events stream.
const USAGE_EVERY: Duration = Duration::from_secs(5 * 60);
/// After a failed read, the next try comes this much sooner than USAGE_EVERY.
const USAGE_RETRY: Duration = Duration::from_secs(60);
/// `claude -p /usage` now and then prints a cost summary instead of the plan limits; it is tried
/// this many times per refresh.
const USAGE_ATTEMPTS: usize = 3;

/// The Claude account's plan limits, as `claude -p /usage` prints them.
#[derive(Default)]
struct Usage {
    limits: Vec<Value>,
    updated_at: Option<i64>,
    error: Option<String>,
    refreshing: bool,
    refreshed: Option<Instant>,
}

impl Usage {
    fn view(&self) -> Value {
        json!({ "limits": self.limits, "updatedAt": self.updated_at, "error": self.error, "refreshing": self.refreshing })
    }
}

/// Runs `<claude> -p /usage` outside any agent session and parses its limits; gives up after a minute.
fn run_usage(program: &str) -> Result<Vec<Value>> {
    let mut command = std::process::Command::new(program);
    command
        .args(["-p", "/usage"])
        .current_dir(paths::state_dir())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    for key in inherited_agent_vars() {
        command.env_remove(key);
    }
    let mut child = command
        .spawn()
        .with_context(|| format!("running {program} -p /usage"))?;
    let deadline = Instant::now() + Duration::from_secs(60);
    while child.try_wait()?.is_none() {
        if Instant::now() >= deadline {
            let _ = child.kill();
            bail!("`claude -p /usage` took over a minute");
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let mut text = String::new();
    child.stdout.take().context("no output")?.read_to_string(&mut text)?;
    Ok(parse_usage(&text))
}

/// The limit lines of `/usage`, e.g. "Current week (all models): 9% used · resets Oct 23 at 11pm (Asia/Saigon)".
fn parse_usage(text: &str) -> Vec<Value> {
    text.lines()
        .filter_map(|line| {
            let rest = line.trim().strip_prefix("Current ")?;
            let (name, rest) = rest.split_once(": ")?;
            let (percent, rest) = rest.split_once("% used")?;
            let percent: i64 = percent.trim().parse().ok()?;
            let resets = rest
                .split_once("resets ")
                .map(|(_, at)| at.split(" (").next().unwrap_or(at).trim().to_string());
            let name = match name {
                "session" => "Session".to_string(),
                "week (all models)" => "Week".to_string(),
                other => {
                    let mut name = other.to_string();
                    name[..1].make_ascii_uppercase();
                    name
                }
            };
            Some(json!({ "name": name, "percent": percent, "resets": resets }))
        })
        .collect()
}

pub fn run() -> Result<()> {
    std::fs::create_dir_all(paths::state_dir())?;
    // One daemon per state folder: two `hub` commands at once may both start one, and the second
    // must not take the socket from the first. The lock lives as long as this process.
    let lock = std::fs::File::create(paths::state_dir().join("hubd.lock"))?;
    if unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&lock), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        bail!("a Hub Daemon is already running for {}", paths::state_dir().display());
    }
    std::mem::forget(lock);
    let socket = paths::socket();
    if UnixStream::connect(&socket).is_ok() {
        bail!("a Hub Daemon is already running on {}", socket.display());
    }
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).with_context(|| format!("binding {}", socket.display()))?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;

    let conn = db::open(&paths::database())?;
    let hub = Arc::new(Hub {
        db: Mutex::new(conn),
        live: Mutex::new(HashMap::new()),
        agents: Mutex::new(HashMap::new()),
        agent_prompts: Mutex::new(HashMap::new()),
        shells: Mutex::new(HashMap::new()),
        muxes: Mutex::new(HashMap::new()),
        tick: Mutex::new(0),
        changed: Condvar::new(),
        usage: Mutex::new(Usage::default()),
        hub_dir: paths::hub_dir(),
        test_agent: std::env::var("HUB_TEST_AGENT").ok(),
    });
    hub.recover()?;
    eprintln!("hubd {}: listening on {}", std::process::id(), socket.display());

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let hub = Arc::clone(&hub);
        std::thread::spawn(move || {
            if let Err(error) = hub.handle(stream) {
                eprintln!("hubd: {error:#}");
            }
        });
    }
    Ok(())
}

/// Whether the client on the other end of `stream` has gone away.
fn peer_gone(stream: &UnixStream) -> bool {
    let mut byte = [0u8; 1];
    let n = unsafe {
        libc::recv(
            std::os::fd::AsRawFd::as_raw_fd(stream),
            byte.as_mut_ptr().cast(),
            1,
            libc::MSG_PEEK | libc::MSG_DONTWAIT,
        )
    };
    n == 0 || (n < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::WouldBlock)
}

fn param<'a>(params: &'a Value, key: &str) -> Result<&'a Value> {
    match params.get(key) {
        Some(value) if !value.is_null() => Ok(value),
        _ => bail!("missing parameter {key}"),
    }
}

fn str_param<'a>(params: &'a Value, key: &str) -> Result<&'a str> {
    param(params, key)?
        .as_str()
        .with_context(|| format!("parameter {key} must be a string"))
}

fn id_param(params: &Value, key: &str) -> Result<i64> {
    param(params, key)?
        .as_i64()
        .with_context(|| format!("parameter {key} must be a number"))
}

fn timeout_param(params: &Value, default: Duration) -> Duration {
    params
        .get("timeout_ms")
        .and_then(Value::as_u64)
        .map(Duration::from_millis)
        .unwrap_or(default)
}

/// The first line of the spec, without a Markdown heading or a "Task:" label.
pub fn title_from_spec(spec: &str) -> String {
    let first = spec
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("Task");
    let title = first.trim_start_matches('#').trim().trim_start_matches("Task:").trim();
    title.chars().take(60).collect()
}

impl Hub {
    fn db(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.db.lock().unwrap()
    }

    fn notify(&self) {
        *self.tick.lock().unwrap() += 1;
        self.changed.notify_all();
    }

    /// Re-runs `check` after every change until it yields, `timeout` passes, or `gone` says stop.
    fn wait_until<T>(
        &self,
        timeout: Duration,
        gone: impl Fn() -> bool,
        mut check: impl FnMut() -> Result<Option<T>>,
    ) -> Result<Option<T>> {
        let deadline = Instant::now() + timeout;
        loop {
            let seen = *self.tick.lock().unwrap();
            if let Some(value) = check()? {
                return Ok(Some(value));
            }
            let now = Instant::now();
            if now >= deadline || gone() {
                return Ok(None);
            }
            let guard = self.tick.lock().unwrap();
            if *guard == seen {
                // Wake at least every second to notice a client that hung up.
                let _ = self
                    .changed
                    .wait_timeout(guard, (deadline - now).min(Duration::from_secs(1)));
            }
        }
    }

    fn live(&self, id: i64) -> Result<Arc<Live>> {
        match self.live.lock().unwrap().get(&id) {
            Some(live) => Ok(Arc::clone(live)),
            None => bail!("w{id} has no live terminal"),
        }
    }

    /// The terminal a request names: `{"id": n}` for a Worker, `{"agent": n}` for an Orchestrator
    /// or Normal session, `{"orchestrator": repo}` for the repo's first Orchestrator, `{"shell": n}`
    /// for a shell.
    fn terminal(&self, p: &Value) -> Result<Arc<Live>> {
        if let Some(id) = p.get("shell").and_then(Value::as_i64) {
            return match self.shells.lock().unwrap().get(&id) {
                Some((_, live)) => Ok(Arc::clone(live)),
                None => bail!("shell {id} is not open"),
            };
        }
        if let Some(id) = p.get("agent").and_then(Value::as_i64) {
            return self.agent_live(id);
        }
        match p.get("orchestrator").and_then(Value::as_str) {
            Some(repo) => {
                let first = db::first_orchestrator(&self.db(), repo)?;
                match first {
                    Some(agent) => self.agent_live(agent.id),
                    None => bail!("no Orchestrator for {repo}"),
                }
            }
            None => self.live(id_param(p, "id")?),
        }
    }

    fn agent_live(&self, id: i64) -> Result<Arc<Live>> {
        match self.agents.lock().unwrap().get(&id) {
            Some(live) => Ok(Arc::clone(live)),
            None => bail!("agent {id} has no live terminal"),
        }
    }

    fn agent_is_live(&self, id: i64) -> bool {
        self.agents.lock().unwrap().contains_key(&id)
    }

    /// `session.open`, as `hub` and older clients call it: starts the repo's first Orchestrator, or
    /// a new one when the repo has none.
    fn open_session(self: &Arc<Self>, p: &Value) -> Result<Value> {
        let repo = repo::root(Path::new(str_param(p, "repo")?))?.display().to_string();
        let first = db::first_orchestrator(&self.db(), &repo)?;
        let mut params = p.clone();
        params["repo"] = json!(repo);
        params["kind"] = json!(db::agent_kind::ORCHESTRATOR);
        if let Some(agent) = first {
            params["agent"] = json!(agent.id);
        }
        self.open_agent(&params)
    }

    /// Starts an agent: an existing one by `agent` id (resuming its Claude session), or a new
    /// `kind` (orchestrator or claude) in `repo` with an optional `name` and `model`.
    fn open_agent(self: &Arc<Self>, p: &Value) -> Result<Value> {
        let picked = |key: &str| {
            p.get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(String::from)
        };
        let id = match p.get("agent").and_then(Value::as_i64) {
            Some(id) => id,
            None => {
                let repo = repo::root(Path::new(str_param(p, "repo")?))?.display().to_string();
                let kind = p
                    .get("kind")
                    .and_then(Value::as_str)
                    .unwrap_or(db::agent_kind::ORCHESTRATOR);
                let id = db::insert_agent(
                    &self.db(),
                    &repo,
                    kind,
                    picked("name").as_deref(),
                    picked("model").as_deref(),
                )?;
                self.notify();
                id
            }
        };
        // A model picked now is kept, so a later start or `hub` resumes with it.
        if let Some(model) = picked("model") {
            db::set_agent_model(&self.db(), id, &model)?;
        }
        if let Some(name) = picked("name") {
            db::set_agent_name(&self.db(), id, &name)?;
        }
        let agent = db::agent(&self.db(), id)?;
        let view = |started: bool, resumed: bool| {
            json!({ "repo": agent.repo, "agent": agent.id, "kind": agent.kind, "started": started,
                    "resumed": resumed, "model": agent.model, "name": agent.name })
        };
        if self.agent_is_live(id) {
            return Ok(view(false, false));
        }
        let mut extra: Vec<String> = p
            .get("args")
            .and_then(Value::as_array)
            .map(|args| args.iter().filter_map(|a| a.as_str().map(String::from)).collect())
            .unwrap_or_default();
        if let Some(model) = &agent.model {
            if !extra.iter().any(|arg| arg == "--model") {
                extra.extend(["--model".to_string(), model.clone()]);
            }
        }
        let repo = PathBuf::from(&agent.repo);
        let resume = paths::transcript_exists(&agent.session_id);
        // What the human asked for up front, like an issue to work on; a resumed session has its own.
        let request = picked("request").filter(|_| !resume);
        let orchestrator = agent.kind == db::agent_kind::ORCHESTRATOR;
        let (program, args) = match &self.test_agent {
            Some(test) => {
                // Tests name a Normal session after the fake agent script it should run.
                let script = match orchestrator {
                    true => "orchestrator".to_string(),
                    false => agent.name.clone().unwrap_or_else(|| "claude".into()),
                };
                (test.clone(), std::iter::once(script).chain(request).collect())
            }
            None if orchestrator => (
                "claude".to_string(),
                launch::orchestrator_args(
                    &self.hub_dir,
                    &repo,
                    &agent.session_id,
                    resume,
                    request.as_deref(),
                    &extra,
                )?,
            ),
            None => (
                "claude".to_string(),
                launch::claude_args(&agent, resume, request.as_deref(), &extra),
            ),
        };
        let spawn = Spawn {
            program,
            args,
            cwd: repo,
            env: self.agent_env(None, Some(agent.id))?,
            env_remove: inherited_agent_vars(),
        };
        let hub: Weak<Hub> = Arc::downgrade(self);
        let live = Live::spawn(agent.id, spawn, move |id| {
            if let Some(hub) = hub.upgrade() {
                hub.agents.lock().unwrap().remove(&id);
                hub.agent_prompts.lock().unwrap().remove(&id);
                hub.notify();
            }
        })?;
        self.agents.lock().unwrap().insert(agent.id, Arc::clone(&live));
        if !orchestrator {
            let hub = Arc::clone(self);
            std::thread::spawn(move || hub.watch_agent(live));
        }
        self.notify();
        Ok(view(true, resume))
    }

    /// Stops an agent's terminal; it stays on the repo's list, ready to resume.
    fn stop_agent(&self, id: i64) {
        if let Some(live) = self.agents.lock().unwrap().get(&id) {
            live.kill();
        }
    }

    /// Every repo with agents, each with its agents. `live` and `model` describe the repo's first
    /// Orchestrator, as older clients read them.
    fn list_sessions(&self) -> Result<Value> {
        let agents = db::agents(&self.db(), None)?;
        let mut repos: Vec<String> = agents.iter().map(|a| a.repo.clone()).collect();
        repos.sort();
        repos.dedup();
        let out: Vec<Value> = repos
            .iter()
            .map(|repo| {
                let mine: Vec<&db::Agent> = agents.iter().filter(|a| &a.repo == repo).collect();
                let first = mine.iter().find(|a| a.kind == db::agent_kind::ORCHESTRATOR);
                json!({
                    "repo": repo,
                    "session_id": first.map(|a| a.session_id.clone()),
                    "live": mine.iter().any(|a| self.agent_is_live(a.id)),
                    "model": first.and_then(|a| a.model.clone()),
                    "agents": mine.iter().map(|a| self.agent_view(a)).collect::<Vec<_>>(),
                })
            })
            .collect();
        Ok(json!({ "sessions": out }))
    }

    fn agent_view(&self, agent: &db::Agent) -> Value {
        json!({
            "id": agent.id,
            "kind": agent.kind,
            "name": agent.name,
            "model": agent.model,
            "live": self.agent_is_live(agent.id),
        })
    }

    /// Names an unnamed agent after the first line the human types into it.
    fn name_from_input(&self, agent: i64, line: &str) -> Result<bool> {
        let Some(name) = name_from_request(line) else {
            return Ok(false);
        };
        let db = self.db();
        if db::agent(&db, agent)?.name.is_some() {
            return Ok(true);
        }
        db::set_agent_name(&db, agent, &name)?;
        drop(db);
        self.notify();
        Ok(true)
    }

    /// A login shell in the repo, the human's own: their `$SHELL` (`HUB_SHELL` overrides it).
    fn open_shell(self: &Arc<Self>, p: &Value) -> Result<Value> {
        let repo = repo::root(Path::new(str_param(p, "repo")?))?;
        let key = repo.display().to_string();
        let id = self.spawn_shell(&key, repo, vec!["-l".into()])?;
        Ok(json!({ "shell": id }))
    }

    /// Starts the human's shell with `args` in `cwd`, listed under `repo`; it lives until it exits.
    fn spawn_shell(self: &Arc<Self>, repo: &str, cwd: PathBuf, args: Vec<String>) -> Result<i64> {
        let id = db::new_shell(&self.db(), repo)?;
        let env = vec![
            ("TERM".to_string(), "xterm-256color".to_string()),
            ("COLORTERM".into(), "truecolor".into()),
        ];
        let spawn = Spawn {
            program: user_shell(),
            args,
            cwd,
            env,
            env_remove: inherited_agent_vars(),
        };
        let hub: Weak<Hub> = Arc::downgrade(self);
        let live = Live::spawn(id, spawn, move |id| {
            if let Some(hub) = hub.upgrade() {
                hub.shells.lock().unwrap().remove(&id);
                hub.muxes.lock().unwrap().retain(|_, shell| *shell != id);
                hub.notify();
            }
        })?;
        self.shells.lock().unwrap().insert(id, (repo.to_string(), live));
        self.notify();
        Ok(id)
    }

    /// The human's multiplexer around one agent's or Worker's terminal: `command` (e.g.
    /// `tmux new-session -A -s {session} -c {dir} {command}`) runs in a login shell, with
    /// `{session}` a stable name for the target, `{dir}` where it works, and `{command}` a
    /// `hub attach --follow` that shows the target in the multiplexer's first pane. One shell per
    /// target: asking again returns the same one while it lives.
    fn open_mux(self: &Arc<Self>, p: &Value) -> Result<Value> {
        let template = str_param(p, "command")?;
        let (label, repo, dir) = if let Some(id) = p.get("agent").and_then(Value::as_i64) {
            let agent = db::agent(&self.db(), id)?;
            (format!("a{id}"), agent.repo.clone(), agent.repo)
        } else {
            let id = id_param(p, "id")?;
            let worker = db::worker(&self.db(), id)?;
            (format!("w{id}"), worker.repo, worker.cwd)
        };
        if let Some(&shell) = self.muxes.lock().unwrap().get(&label) {
            if self.shells.lock().unwrap().contains_key(&shell) {
                return Ok(json!({ "shell": shell }));
            }
        }
        let name = Path::new(&repo)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let session = mux_session(&name, &label);
        let mut attach = vec![
            std::env::current_exe()?.display().to_string(),
            "attach".into(),
            "--follow".into(),
            label.clone(),
        ];
        // The multiplexer's server may have been started elsewhere, so this daemon is named.
        attach.splice(
            0..0,
            ["env".to_string(), format!("HUB_STATE={}", paths::state_dir().display())],
        );
        let attach = attach
            .iter()
            .map(|word| shell_quote(word))
            .collect::<Vec<_>>()
            .join(" ");
        let command = template
            .replace("{session}", &shell_quote(&session))
            .replace("{dir}", &shell_quote(&dir))
            .replace("{command}", &shell_quote(&attach));
        let shell = self.spawn_shell(&repo, PathBuf::from(&dir), vec!["-l".into(), "-c".into(), command])?;
        self.muxes.lock().unwrap().insert(label, shell);
        Ok(json!({ "shell": shell, "session": session }))
    }

    fn recover(&self) -> Result<()> {
        let db = self.db();
        for worker in db::mark_lost(&db)? {
            let body = format!(
                "The Hub Daemon restarted while w{} was live; its terminal is gone. Resume it: hub worker resume w{}",
                worker.id, worker.id
            );
            db::insert_message(&db, &worker, kind::LOST, &body)?;
        }
        Ok(())
    }

    fn handle(self: &Arc<Self>, stream: UnixStream) -> Result<()> {
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Ok(());
        }
        let request: proto::Request = serde_json::from_str(&line).context("bad request line")?;
        if request.method == "attach" {
            return self.attach(&request.params, reader, stream);
        }
        if request.method == "events" {
            return self.events(&request.params, stream);
        }
        let response = match self.dispatch(&request.method, &request.params, &stream) {
            Ok(result) => proto::ok(result),
            Err(error) => proto::err(&error),
        };
        let mut out = stream;
        proto::write_line(&mut out, &response)
    }

    fn dispatch(self: &Arc<Self>, method: &str, p: &Value, stream: &UnixStream) -> Result<Value> {
        match method {
            "ping" => Ok(json!({ "pid": std::process::id() })),
            "worker.start" => self.start_worker(p),
            "worker.list" => self.list_workers(str_param(p, "repo")?, p.get("agent").and_then(Value::as_i64)),
            "status" => self.status(str_param(p, "repo")?),
            "worker.read" => {
                let live = self.live(id_param(p, "id")?)?;
                let lines = p.get("lines").and_then(Value::as_u64).unwrap_or(0) as usize;
                let screen = live.screen();
                Ok(json!({ "screen": if lines > 0 { screen::tail(&screen, lines) } else { screen } }))
            }
            "worker.send" => {
                let live = self.live(id_param(p, "id")?)?;
                live.write(str_param(p, "text")?.as_bytes())?;
                if p.get("enter").and_then(Value::as_bool).unwrap_or(true) {
                    // Typed text and its Enter in one write reads as a paste with a newline.
                    std::thread::sleep(Duration::from_millis(150));
                    live.write(b"\r")?;
                }
                Ok(json!({}))
            }
            "worker.key" => {
                let live = self.live(id_param(p, "id")?)?;
                for key in param(p, "keys")?.as_array().context("keys must be a list")? {
                    live.write(&key_bytes(key.as_str().unwrap_or_default())?)?;
                    std::thread::sleep(Duration::from_millis(100));
                }
                Ok(json!({}))
            }
            "terminal.resize" => {
                let live = self.terminal(p)?;
                live.resize(id_param(p, "rows")? as u16, id_param(p, "cols")? as u16)?;
                Ok(json!({}))
            }
            "session.open" => self.open_session(p),
            "session.close" => {
                let repo = repo::root(Path::new(str_param(p, "repo")?))?.display().to_string();
                for agent in db::agents(&self.db(), Some(&repo))? {
                    self.stop_agent(agent.id);
                }
                Ok(json!({}))
            }
            "agent.open" => self.open_agent(p),
            "agent.close" => {
                self.stop_agent(id_param(p, "agent")?);
                Ok(json!({}))
            }
            "agent.forget" => {
                let id = id_param(p, "agent")?;
                self.stop_agent(id);
                db::close_agent(&self.db(), id)?;
                self.notify();
                Ok(json!({}))
            }
            "agent.rename" => {
                let name = str_param(p, "name")?.trim();
                if name.is_empty() {
                    bail!("a name cannot be empty");
                }
                db::set_agent_name(&self.db(), id_param(p, "agent")?, name)?;
                self.notify();
                Ok(json!({}))
            }
            "sessions.list" => self.list_sessions(),
            "shell.open" => self.open_shell(p),
            "mux.open" => self.open_mux(p),
            "shell.close" => {
                if let Some((_, live)) = self.shells.lock().unwrap().get(&id_param(p, "shell")?) {
                    live.kill();
                }
                Ok(json!({}))
            }
            "usage.refresh" => {
                self.refresh_usage();
                Ok(json!({}))
            }
            "usage" => Ok(self.usage.lock().unwrap().view()),
            "decide" => self.decide(p),
            "worker.close" => self.close_worker(id_param(p, "id")?),
            "worker.dismiss" => {
                db::mark_dismissed(&self.db(), id_param(p, "id")?)?;
                self.notify();
                Ok(json!({}))
            }
            "worker.resume" => self.resume_worker(id_param(p, "id")?),
            "send" => {
                let worker = db::worker(&self.db(), id_param(p, "worker")?)?;
                let message_kind = str_param(p, "kind")?;
                if ![kind::ESCALATION, kind::STATUS].contains(&message_kind) {
                    bail!("send --type must be escalation or status (use hub ask, hub done for the rest)");
                }
                let id = db::insert_message(&self.db(), &worker, message_kind, str_param(p, "body")?)?;
                self.notify();
                Ok(json!({ "message": id }))
            }
            "ask" => self.ask(p, stream),
            "done" => {
                let id = id_param(p, "worker")?;
                let final_state = str_param(p, "state")?;
                if ![state::DONE, state::BLOCKED].contains(&final_state) {
                    bail!("done --state must be done or blocked");
                }
                let body = str_param(p, "body")?;
                let db = self.db();
                let worker = db::worker(&db, id)?;
                if !state::is_live(&worker.state) {
                    bail!("w{id} already settled as {}", worker.state);
                }
                db::settle(&db, id, final_state, body)?;
                db::insert_message(&db, &worker, kind::DONE, body)?;
                drop(db);
                self.notify();
                Ok(json!({}))
            }
            "notify" => {
                let live = self.live(id_param(p, "worker")?)?;
                self.report_blocker(&live, str_param(p, "kind")?, p["message"].as_str().unwrap_or(""))?;
                Ok(json!({}))
            }
            "wait" => self.wait(
                str_param(p, "repo")?,
                p.get("agent").and_then(Value::as_i64),
                timeout_param(p, Duration::from_secs(3600)),
                stream,
            ),
            "reply" => {
                let id = id_param(p, "id")?;
                let body = str_param(p, "body")?;
                let db = self.db();
                db::answer(&db, id, body)?;
                if p.get("by_human").and_then(Value::as_bool).unwrap_or(false) {
                    let question = db::message(&db, id)?;
                    let worker = db::worker(&db, question.worker_id)?;
                    let note = format!(
                        "The human answered question #{id} from w{} in the Hub App:\n{body}",
                        worker.id
                    );
                    db::insert_message(&db, &worker, kind::HUMAN, &note)?;
                }
                drop(db);
                self.notify();
                Ok(json!({}))
            }
            "inbox" => {
                let repo = str_param(p, "repo")?;
                let db = self.db();
                let mut open = Vec::new();
                for worker in db::workers(&db, repo)? {
                    open.extend(db::open_questions(&db, worker.id)?);
                }
                Ok(json!({ "open_questions": open }))
            }
            "shutdown" => {
                let live = self.live.lock().unwrap().len() + self.agents.lock().unwrap().len();
                if live > 0 && !p.get("force").and_then(Value::as_bool).unwrap_or(false) {
                    bail!("{live} terminal(s) still live (Workers or Orchestrators); close them first or pass --force");
                }
                let killed: Vec<Arc<Live>> = self.live.lock().unwrap().values().cloned().collect();
                for live in &killed {
                    live.closing.store(true, std::sync::atomic::Ordering::SeqCst);
                    live.kill();
                }
                // Record the closes now: the process exits before every exit callback runs.
                let db = self.db();
                for live in &killed {
                    let worker = db::worker(&db, live.id)?;
                    if state::is_live(&worker.state) {
                        db::settle(&db, live.id, state::EXITED, "stopped by hub shutdown --force")?;
                    }
                    db::mark_closed(&db, live.id)?;
                }
                drop(db);
                for live in self.agents.lock().unwrap().values() {
                    live.kill();
                }
                for (_, live) in self.shells.lock().unwrap().values() {
                    live.kill();
                }
                let _ = std::fs::remove_file(paths::socket());
                std::thread::spawn(|| {
                    std::thread::sleep(Duration::from_millis(200));
                    std::process::exit(0);
                });
                Ok(json!({}))
            }
            other => bail!("unknown method {other}"),
        }
    }

    fn spawn_for(&self, worker: &Worker, launch: Launch) -> Result<Spawn> {
        let (program, args) = match &self.test_agent {
            Some(agent) => {
                let spec = match launch {
                    Launch::New { spec } => spec.to_string(),
                    Launch::Resume => "resume".to_string(),
                };
                (agent.clone(), vec![spec])
            }
            None => {
                let profile = profile::load(&self.hub_dir, &worker.profile)?;
                let args = profile::claude_args(&self.hub_dir, &profile, &worker.title, &worker.session_id, launch)?;
                ("claude".to_string(), args)
            }
        };
        Ok(Spawn {
            program,
            args,
            cwd: PathBuf::from(&worker.cwd),
            env: self.agent_env(Some(worker.id), None)?,
            env_remove: inherited_agent_vars(),
        })
    }

    /// Environment for an agent terminal. This `hub` comes first on PATH, so the agent's `hub`
    /// commands and its Notification hook reach this daemon.
    fn agent_env(&self, worker: Option<i64>, agent: Option<i64>) -> Result<Vec<(String, String)>> {
        let exe_dir = std::env::current_exe()?
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let path = format!("{}:{}", exe_dir.display(), std::env::var("PATH").unwrap_or_default());
        let mut env = vec![
            ("PATH".to_string(), path),
            ("AGENT_HUB".into(), self.hub_dir.display().to_string()),
            ("HUB_STATE".into(), paths::state_dir().display().to_string()),
            ("TERM".into(), "xterm-256color".into()),
            ("COLORTERM".into(), "truecolor".into()),
        ];
        if let Some(id) = worker {
            env.push(("HUB_WORKER".into(), id.to_string()));
        }
        // An Orchestrator's `hub worker start` and `hub wait` name it, so Workers and their
        // messages stay with the Orchestrator that started them.
        if let Some(id) = agent {
            env.push(("HUB_AGENT".into(), id.to_string()));
        }
        Ok(env)
    }

    fn launch(self: &Arc<Self>, worker: &Worker, launch: Launch) -> Result<()> {
        let spawn = self.spawn_for(worker, launch)?;
        let hub: Weak<Hub> = Arc::downgrade(self);
        let live = Live::spawn(worker.id, spawn, move |id| {
            if let Some(hub) = hub.upgrade() {
                if let Err(error) = hub.on_exit(id) {
                    eprintln!("hubd: w{id} exit: {error:#}");
                }
            }
        })?;
        self.live.lock().unwrap().insert(worker.id, Arc::clone(&live));
        let hub = Arc::clone(self);
        std::thread::spawn(move || hub.watch(live));
        Ok(())
    }

    fn start_worker(self: &Arc<Self>, p: &Value) -> Result<Value> {
        let repo_root = PathBuf::from(str_param(p, "repo")?);
        let profile_name = str_param(p, "profile")?;
        profile::load(&self.hub_dir, profile_name)?;
        let spec = str_param(p, "spec")?;
        let title = match p.get("title").and_then(Value::as_str) {
            Some(title) if !title.trim().is_empty() => title.to_string(),
            _ => title_from_spec(spec),
        };
        let choice = p.get("worktree").and_then(Value::as_str).unwrap_or("current");
        let (cwd, branch) = if choice == "current" {
            (repo_root.clone(), None)
        } else if let Some(branch) = choice.strip_prefix("new:") {
            (repo::create_worktree(&repo_root, branch)?, Some(branch.to_string()))
        } else if let Some(path) = choice.strip_prefix("path:") {
            let path = PathBuf::from(path);
            if repo::root(&path)? != repo_root {
                bail!("{} is not a worktree of {}", path.display(), repo_root.display());
            }
            (path, None)
        } else {
            bail!("--worktree must be current, new:<type>/<task>, or path:<abs path>");
        };

        // The Orchestrator starting it (`HUB_AGENT` via `hub worker start`), else the repo's first.
        let agent = match p.get("agent").and_then(Value::as_i64) {
            Some(agent) => Some(agent),
            None => db::first_orchestrator(&self.db(), &repo_root.display().to_string())?.map(|a| a.id),
        };
        let session_id = uuid::Uuid::new_v4().to_string();
        let id = db::insert_worker(
            &self.db(),
            &db::NewWorker {
                repo: &repo_root.display().to_string(),
                profile: profile_name,
                title: &title,
                spec,
                cwd: &cwd.display().to_string(),
                branch: branch.as_deref(),
                session_id: &session_id,
                agent,
            },
        )?;
        let worker = db::worker(&self.db(), id)?;
        if let Err(error) = self.launch(&worker, Launch::New { spec }) {
            db::settle(&self.db(), id, state::EXITED, &format!("could not start: {error:#}"))?;
            return Err(error);
        }
        self.notify();

        let started = self.wait_until(
            START_TIMEOUT,
            || false,
            || {
                let now = db::worker(&self.db(), id)?;
                Ok((now.state != state::STARTING).then_some(now.state))
            },
        )?;
        let view =
            json!({ "id": format!("w{id}"), "cwd": cwd, "branch": branch, "session_id": session_id, "title": title });
        match started.as_deref() {
            Some(state::EXITED) => {
                let screen = self.live(id).map(|l| l.screen()).unwrap_or_default();
                bail!("w{id} exited before starting its turn:\n{}", screen::tail(&screen, SCREEN_LINES))
            }
            Some(_) => Ok(view),
            None => bail!("w{id} never started its turn; read it with `hub worker read w{id}`, stop it with `hub worker close w{id}`"),
        }
    }

    fn resume_worker(self: &Arc<Self>, id: i64) -> Result<Value> {
        if self.live(id).is_ok() {
            bail!("w{id} is already live");
        }
        let worker = db::worker(&self.db(), id)?;
        if worker.state != state::LOST && worker.state != state::EXITED {
            bail!("w{id} is {}; only lost or exited Workers resume", worker.state);
        }
        db::set_state(&self.db(), id, state::STARTING)?;
        let worker = db::worker(&self.db(), id)?;
        self.launch(&worker, Launch::Resume)?;
        self.notify();
        Ok(json!({ "id": format!("w{id}") }))
    }

    fn close_worker(&self, id: i64) -> Result<Value> {
        match self.live(id) {
            Ok(live) => {
                live.closing.store(true, std::sync::atomic::Ordering::SeqCst);
                live.kill();
            }
            Err(_) => {
                db::mark_closed(&self.db(), id)?;
                self.notify();
            }
        }
        Ok(json!({}))
    }

    fn on_exit(&self, id: i64) -> Result<()> {
        let Some(live) = self.live.lock().unwrap().remove(&id) else {
            return Ok(());
        };
        let closing = live.closing.load(std::sync::atomic::Ordering::SeqCst);
        let db = self.db();
        let worker = db::worker(&db, id)?;
        if state::is_live(&worker.state) {
            let tail = screen::tail(&live.screen(), SCREEN_LINES);
            db::settle(&db, id, state::EXITED, "exited without a Final Report")?;
            if !closing {
                let body = format!("w{id} exited without a Final Report.\n\nLast screen:\n{tail}");
                db::insert_message(&db, &worker, kind::EXITED, &body)?;
            }
        }
        if closing {
            db::mark_closed(&db, id)?;
        }
        drop(db);
        self.notify();
        Ok(())
    }

    /// Reports a blocker once per stretch: cleared when the screen shows the Worker working again.
    /// Lock order everywhere: the database before a Worker's blocker, never the reverse.
    fn report_blocker(&self, live: &Live, blocker_kind: &str, message: &str) -> Result<()> {
        let worker = db::worker(&self.db(), live.id)?;
        if !state::is_live(&worker.state) {
            return Ok(()); // idle after the Final Report is the expected end state
        }
        {
            let mut current = live.blocker.lock().unwrap();
            if current.is_some() {
                return Ok(());
            }
            *current = Some(blocker_kind.to_string());
        }
        let body = format!(
            "Blocked: {blocker_kind}\n{message}\n\nWorker screen (last {SCREEN_LINES} lines):\n{}",
            screen::tail(&live.screen(), SCREEN_LINES)
        );
        db::insert_message(&self.db(), &worker, kind::BLOCKER, &body)?;
        self.notify();
        Ok(())
    }

    /// Reads the Worker's screen every second: answers the trust dialog, notices the turn
    /// starting, and reports permission prompts and unexplained idling.
    fn watch(self: Arc<Self>, live: Arc<Live>) {
        let mut last_screen = String::new();
        let mut changed_at = Instant::now();
        let mut trusted_at: Option<Instant> = None;
        while live.is_alive() {
            std::thread::sleep(Duration::from_secs(1));
            let screen = live.screen();
            if screen != last_screen {
                last_screen = screen.clone();
                changed_at = Instant::now();
            }
            let look = screen::look(&screen);
            let Ok(worker) = db::worker(&self.db(), live.id) else {
                break;
            };
            let result = (|| -> Result<()> {
                match look {
                    Look::TrustPrompt => {
                        // The human approved this Task, so trusting its folder is part of starting it.
                        if trusted_at.is_none_or(|at| at.elapsed() > Duration::from_secs(5)) {
                            trusted_at = Some(Instant::now());
                            live.write(b"\x1b[B")?;
                            std::thread::sleep(Duration::from_millis(300));
                            live.write(b"\r")?;
                        }
                    }
                    Look::PermissionPrompt => {
                        self.report_blocker(&live, "permission_prompt", "A permission prompt is waiting on screen.")?
                    }
                    Look::Working => {
                        if live.blocker.lock().unwrap().take().is_some() {
                            self.notify();
                        }
                    }
                    Look::Idle => {
                        // An answered or cancelled prompt ends that blocker; idling after it is a new one.
                        let mut blocker = live.blocker.lock().unwrap();
                        if blocker.as_deref() == Some("permission_prompt") {
                            blocker.take();
                            changed_at = Instant::now();
                            drop(blocker);
                            self.notify();
                        }
                    }
                }
                // A permission prompt also means a turn is under way.
                let started = matches!(look, Look::Working | Look::PermissionPrompt)
                    || paths::transcript_exists(&worker.session_id);
                if worker.state == state::STARTING && started {
                    db::set_state(&self.db(), live.id, state::RUNNING)?;
                    self.notify();
                }
                let idle = look == Look::Idle && changed_at.elapsed() >= IDLE_BLOCKER && live.age() >= IDLE_BLOCKER;
                if worker.state == state::RUNNING && idle && db::open_questions(&self.db(), live.id)?.is_empty() {
                    self.report_blocker(&live, "idle_prompt", "Idle at its input box with no Final Report.")?;
                }
                Ok(())
            })();
            if let Err(error) = result {
                eprintln!("hubd: watching w{}: {error:#}", live.id);
            }
        }
    }

    fn ask(&self, p: &Value, stream: &UnixStream) -> Result<Value> {
        let worker_id = id_param(p, "worker")?;
        let question = match p.get("question").and_then(Value::as_i64) {
            Some(id) => {
                let question = db::message(&self.db(), id)?;
                if question.worker_id != worker_id || question.kind != kind::QUESTION {
                    bail!("#{id} is not a question from w{worker_id}");
                }
                id
            }
            None => {
                let worker = db::worker(&self.db(), worker_id)?;
                let id = db::insert_message(&self.db(), &worker, kind::QUESTION, str_param(p, "body")?)?;
                self.notify();
                id
            }
        };
        let answer = self.wait_until(
            timeout_param(p, Duration::from_secs(540)),
            || peer_gone(stream),
            || Ok(db::message(&self.db(), question)?.answer),
        )?;
        Ok(json!({ "question": question, "answer": answer }))
    }

    fn wait(&self, repo: &str, agent: Option<i64>, timeout: Duration, stream: &UnixStream) -> Result<Value> {
        let messages = self.wait_until(
            timeout,
            || peer_gone(stream),
            || {
                if peer_gone(stream) {
                    return Ok(None); // never hand messages to a listener that hung up
                }
                let taken = db::take_undelivered(&self.db(), repo, agent)?;
                Ok((!taken.is_empty()).then_some(taken))
            },
        )?;
        let db = self.db();
        let mut out = Vec::new();
        for message in messages.unwrap_or_default() {
            let worker = db::worker(&db, message.worker_id)?;
            out.push(json!({
                "id": message.id,
                "kind": message.kind,
                "worker": format!("w{}", worker.id),
                "profile": worker.profile,
                "title": worker.title,
                "state": worker.state,
                "branch": worker.branch,
                "body": message.body,
            }));
        }
        Ok(json!({ "messages": out }))
    }

    fn view(&self, db: &Connection, worker: &Worker) -> Result<Value> {
        let open: Vec<i64> = db::open_questions(db, worker.id)?.iter().map(|m| m.id).collect();
        let blocker = self
            .live(worker.id)
            .ok()
            .and_then(|live| live.blocker.lock().unwrap().clone());
        Ok(json!({
            "id": format!("w{}", worker.id),
            "profile": worker.profile,
            "title": worker.title,
            "state": worker.state,
            "live": self.live(worker.id).is_ok(),
            "open_questions": open,
            "blocker": blocker,
            "cwd": worker.cwd,
            "branch": worker.branch,
            "session_id": worker.session_id,
            "final_report": worker.final_report,
            "quiet_seconds": db::now() - worker.last_message_at.unwrap_or(worker.created_at),
        }))
    }

    /// The repo's open Workers; with an `agent`, only the ones that Orchestrator started.
    fn list_workers(&self, repo: &str, agent: Option<i64>) -> Result<Value> {
        let db = self.db();
        let mut out = Vec::new();
        for worker in db::workers(&db, repo)? {
            if worker.closed_at.is_none() && agent.is_none_or(|agent| worker.agent_id == Some(agent)) {
                out.push(self.view(&db, &worker)?);
            }
        }
        Ok(json!({ "workers": out }))
    }

    /// The Dashboard rows: live Workers, and settled ones for a while after.
    fn status(&self, repo: &str) -> Result<Value> {
        Ok(json!({ "workers": self.rows(repo, false)? }))
    }

    /// One row per recent Worker, ordered needs you, running, failed, done. `state` is the
    /// Dashboard state; `phase` is the Worker's lifecycle state. For Echo (`for_echo`), settled
    /// Workers stay until dismissed or a week old, so a Final Report waits to be read; the
    /// Orchestrator's `hub status` drops them after ten minutes.
    fn rows(&self, repo: &str, for_echo: bool) -> Result<Vec<Value>> {
        let db = self.db();
        let now = db::now();
        let mut rows = Vec::new();
        for worker in db::workers(&db, repo)? {
            let recent = match worker.settled_at {
                None => true,
                Some(at) if for_echo => worker.dismissed_at.is_none() && now - at < KEEP_REPORTS_SECONDS,
                Some(at) => now - at < KEEP_SETTLED_SECONDS,
            };
            if !recent {
                continue;
            }
            let live = self.live(worker.id).ok();
            let blocker = live.as_ref().and_then(|live| live.blocker.lock().unwrap().clone());
            let open: Vec<i64> = db::open_questions(&db, worker.id)?.iter().map(|m| m.id).collect();
            let profile = profile::load(&self.hub_dir, &worker.profile).ok();
            // The Worker's latest `hub send --type status`, first line only: the ledger's progress line.
            let progress = db::last_message(&db, worker.id, kind::STATUS)?
                .and_then(|m| m.body.lines().map(str::trim).find(|l| !l.is_empty()).map(String::from));
            let row_state = match worker.state.as_str() {
                state::DONE => "done",
                state::BLOCKED | state::LOST => "needs you",
                state::EXITED => "failed",
                _ if blocker.is_some() || !open.is_empty() => "needs you",
                _ => "running",
            };
            rows.push(json!({
                "id": format!("w{}", worker.id),
                "profile": worker.profile,
                "title": worker.title,
                "state": row_state,
                "phase": worker.state,
                "quietSeconds": (now - worker.last_message_at.unwrap_or(worker.created_at)).max(0),
                "place": place(Path::new(repo), Path::new(&worker.cwd)),
                "branch": worker.branch,
                "live": live.is_some(),
                "blocker": blocker,
                "openQuestions": open,
                "finalReport": worker.final_report,
                "agent": worker.agent_id,
                "model": profile.as_ref().map(|p| p.model.clone()),
                "effort": profile.as_ref().and_then(|p| p.effort.clone()),
                "progress": progress,
                "settledAt": worker.settled_at,
            }));
        }
        let order = |row: &Value| match row["state"].as_str() {
            Some("needs you") => 0,
            Some("running") => 1,
            Some("failed") => 2,
            _ => 3,
        };
        rows.sort_by_key(|row| (order(row), row["quietSeconds"].as_i64().unwrap_or(0)));
        Ok(rows)
    }

    /// What needs the human now: open questions and waiting permission prompts, oldest first.
    fn needs(&self, repo: &str) -> Result<Vec<Value>> {
        let db = self.db();
        let mut needs = Vec::new();
        for worker in db::workers(&db, repo)? {
            for question in db::open_questions(&db, worker.id)? {
                needs.push(json!({
                    "kind": "question",
                    "message": question.id,
                    "agent": worker.agent_id,
                    "worker": format!("w{}", worker.id),
                    "profile": worker.profile,
                    "title": worker.title,
                    "body": question.body,
                    "at": question.created_at,
                }));
            }
            let Ok(live) = self.live(worker.id) else { continue };
            let blocker = live.blocker.lock().unwrap().clone();
            if let (Some(blocker), Some(message)) = (blocker, db::last_message(&db, worker.id, kind::BLOCKER)?) {
                // The prompt's own lines, so the Hub App can show the exact command, not the whole screen.
                let prompt = match blocker.as_str() {
                    "permission_prompt" => screen::prompt_lines(&live.screen()),
                    _ => String::new(),
                };
                needs.push(json!({
                    "kind": blocker,
                    "message": message.id,
                    "agent": worker.agent_id,
                    "worker": format!("w{}", worker.id),
                    "profile": worker.profile,
                    "title": worker.title,
                    "body": message.body,
                    "prompt": prompt,
                    "at": message.created_at,
                }));
            }
        }
        drop(db);
        // A Normal session's own permission prompt: there is no Orchestrator to tell, only the human.
        for agent in db::agents(&self.db(), Some(repo))? {
            let Some(at) = self.agent_prompts.lock().unwrap().get(&agent.id).copied() else {
                continue;
            };
            let Ok(live) = self.agent_live(agent.id) else { continue };
            needs.push(json!({
                "kind": "permission_prompt",
                "message": 0,
                "agent": agent.id,
                "worker": null,
                "profile": "claude",
                "title": agent.name.clone().unwrap_or_else(|| "Claude Code".into()),
                "body": "A permission prompt is waiting on screen.",
                "prompt": screen::prompt_lines(&live.screen()),
                "at": at,
            }));
        }
        needs.sort_by_key(|need| need["at"].as_i64().unwrap_or(0));
        Ok(needs)
    }

    /// The repo's open shells, oldest first.
    fn shells_of(&self, repo: &str) -> Vec<i64> {
        let mut ids: Vec<i64> = self
            .shells
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, (of, _))| of == repo)
            .map(|(id, _)| *id)
            .collect();
        ids.sort();
        ids
    }

    /// Everything the app draws for one repo: its agents, their Workers, and what needs the human.
    fn snapshot(&self, repo: &str) -> Result<Value> {
        // Read before the json! below: its other parts take the database lock themselves.
        let agents = db::agents(&self.db(), Some(repo))?;
        let first = agents.iter().find(|a| a.kind == db::agent_kind::ORCHESTRATOR);
        Ok(json!({
            "repo": repo,
            "orchestrator": {
                "live": first.is_some_and(|a| self.agent_is_live(a.id)),
                "model": first.and_then(|a| a.model.clone()),
            },
            "agents": agents.iter().map(|a| self.agent_view(a)).collect::<Vec<_>>(),
            "shells": self.shells_of(repo),
            "workers": self.rows(repo, true)?,
            "needs": self.needs(repo)?,
            "usage": self.usage.lock().unwrap().view(),
        }))
    }

    fn refresh_usage(self: &Arc<Self>) {
        {
            let mut usage = self.usage.lock().unwrap();
            if usage.refreshing {
                return;
            }
            usage.refreshing = true;
            usage.refreshed = Some(Instant::now());
        }
        let program = self.test_agent.clone().unwrap_or_else(|| "claude".into());
        let hub = Arc::clone(self);
        std::thread::spawn(move || {
            let mut result = Ok(Vec::new());
            for attempt in 0..USAGE_ATTEMPTS {
                if attempt > 0 {
                    std::thread::sleep(Duration::from_secs(3));
                }
                result = run_usage(&program);
                if result.as_ref().is_ok_and(|limits| !limits.is_empty()) {
                    break;
                }
            }
            let mut usage = hub.usage.lock().unwrap();
            usage.refreshing = false;
            match result {
                Ok(limits) if !limits.is_empty() => {
                    usage.limits = limits;
                    usage.updated_at = Some(db::now());
                    usage.error = None;
                }
                // Keep the last good limits on screen; try again sooner than usual.
                failed => {
                    usage.error = Some(match failed {
                        Err(error) => format!("{error:#}"),
                        Ok(_) => "`claude -p /usage` printed no plan limits".into(),
                    });
                    usage.refreshed = Instant::now().checked_sub(USAGE_EVERY - USAGE_RETRY);
                }
            }
            drop(usage);
            hub.notify();
        });
    }

    /// Streams a snapshot line now, after every change, and every 5 seconds, until the client leaves.
    fn events(self: &Arc<Self>, p: &Value, mut stream: UnixStream) -> Result<()> {
        let repo = match str_param(p, "repo").and_then(|repo| repo::root(Path::new(repo))) {
            Ok(repo) => repo.display().to_string(),
            Err(error) => return proto::write_line(&mut stream, &proto::err(&error)),
        };
        proto::write_line(&mut stream, &proto::ok(json!({ "repo": repo })))?;
        loop {
            let stale = self
                .usage
                .lock()
                .unwrap()
                .refreshed
                .is_none_or(|at| at.elapsed() >= USAGE_EVERY);
            if stale {
                self.refresh_usage();
            }
            let seen = *self.tick.lock().unwrap();
            if proto::write_line(&mut stream, &self.snapshot(&repo)?).is_err() {
                return Ok(());
            }
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let guard = self.tick.lock().unwrap();
                let now = Instant::now();
                if *guard != seen || now >= deadline {
                    break;
                }
                let _ = self.changed.wait_timeout(guard, deadline - now);
            }
            if peer_gone(&stream) {
                return Ok(());
            }
        }
    }

    /// The human's answer to a waiting permission prompt, from the Hub App: press the key on the
    /// Worker, then tell the Orchestrator, so it never has to be typed to.
    fn decide(&self, p: &Value) -> Result<Value> {
        let approve = param(p, "approve")?
            .as_bool()
            .context("approve must be true or false")?;
        if let Some(agent) = p.get("agent").and_then(Value::as_i64) {
            return self.decide_agent(agent, approve, p.get("note").and_then(Value::as_str));
        }
        let id = id_param(p, "worker")?;
        let live = self.live(id)?;
        let screen = live.screen();
        if screen::look(&screen) != Look::PermissionPrompt {
            bail!("no permission prompt is waiting on w{id}");
        }
        let prompt = screen::prompt_lines(&screen);
        if approve {
            live.write(b"\r")?;
        } else {
            live.write(b"\x1b")?;
            std::thread::sleep(Duration::from_millis(500));
            let note = p
                .get("note")
                .and_then(Value::as_str)
                .filter(|note| !note.trim().is_empty())
                .unwrap_or("Do not run it. Continue another way within your Task, or finish blocked with hub done.");
            live.write(format!("The human denied that command. {note}").as_bytes())?;
            std::thread::sleep(Duration::from_millis(150));
            live.write(b"\r")?;
        }
        let db = self.db();
        let worker = db::worker(&db, id)?;
        let verb = if approve { "approved" } else { "denied" };
        let body = format!("The human {verb} this permission prompt on w{id} in the Hub App:\n{prompt}");
        db::insert_message(&db, &worker, kind::HUMAN, &body)?;
        drop(db);
        self.notify();
        Ok(json!({}))
    }

    /// Approve or Deny on a Normal session's own prompt: press the key; the human is the only one to tell.
    fn decide_agent(&self, id: i64, approve: bool, note: Option<&str>) -> Result<Value> {
        let live = self.agent_live(id)?;
        if screen::look(&live.screen()) != Look::PermissionPrompt {
            bail!("no permission prompt is waiting on agent {id}");
        }
        if approve {
            live.write(b"\r")?;
        } else {
            live.write(b"\x1b")?;
            if let Some(note) = note.map(str::trim).filter(|n| !n.is_empty()) {
                std::thread::sleep(Duration::from_millis(500));
                live.write(note.as_bytes())?;
                std::thread::sleep(Duration::from_millis(150));
                live.write(b"\r")?;
            }
        }
        self.agent_prompts.lock().unwrap().remove(&id);
        self.notify();
        Ok(json!({}))
    }

    /// Watches a Normal session's screen for permission prompts, so they reach Needs you.
    fn watch_agent(self: Arc<Self>, live: Arc<Live>) {
        while live.is_alive() {
            std::thread::sleep(Duration::from_secs(1));
            let waiting = screen::look(&live.screen()) == Look::PermissionPrompt;
            let mut prompts = self.agent_prompts.lock().unwrap();
            let changed = if waiting {
                // Keep the time it was first seen.
                !prompts.contains_key(&live.id) && prompts.insert(live.id, db::now()).is_none()
            } else {
                prompts.remove(&live.id).is_some()
            };
            drop(prompts);
            if changed {
                self.notify();
            }
        }
    }

    fn attach(&self, p: &Value, mut reader: BufReader<UnixStream>, mut stream: UnixStream) -> Result<()> {
        let live = match self.terminal(p) {
            Ok(live) => live,
            Err(error) => return proto::write_line(&mut stream, &proto::err(&error)),
        };
        if let (Some(rows), Some(cols)) = (
            p.get("rows").and_then(Value::as_u64),
            p.get("cols").and_then(Value::as_u64),
        ) {
            live.resize(rows as u16, cols as u16)?;
        }
        proto::write_line(&mut stream, &proto::ok(json!({})))?;
        let (snapshot, chunks) = live.subscribe();
        let mut out = stream.try_clone()?;
        out.write_all(b"\x1b[H\x1b[2J")?;
        out.write_all(&snapshot)?;
        out.flush()?;
        std::thread::spawn(move || {
            for chunk in chunks {
                if out.write_all(&chunk).and_then(|_| out.flush()).is_err() {
                    break;
                }
            }
            let _ = out.shutdown(std::net::Shutdown::Both);
        });
        // An unnamed agent takes its name from the first line the human types into it.
        let mut naming = match p.get("agent").and_then(Value::as_i64) {
            Some(id) if db::agent(&self.db(), id).is_ok_and(|a| a.name.is_none()) => Some((id, LineReader::default())),
            _ => None,
        };
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    live.write(&buf[..n])?;
                    if let Some((id, line)) = &mut naming {
                        let id = *id;
                        for typed in line.feed(&buf[..n]) {
                            if self.name_from_input(id, &typed).unwrap_or(true) {
                                naming = None;
                                break;
                            }
                        }
                    }
                }
            }
        }
        let _ = stream.shutdown(std::net::Shutdown::Both);
        Ok(())
    }
}

/// Session markers a Worker must not inherit from whatever agent started the daemon: Claude Code
/// reads `CLAUDE_CODE_CHILD_SESSION`, for one, as "do not save transcripts", which breaks resume.
/// Collects what the human types into a terminal, a line at a time, without escape sequences.
#[derive(Default)]
struct LineReader {
    line: Vec<u8>,
    escape: bool,
}

impl LineReader {
    /// Feeds typed bytes; returns every non-empty line Enter finished.
    fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        let mut done = Vec::new();
        for &b in bytes {
            if self.escape {
                // CSI and friends end on a letter or `~`.
                if b.is_ascii_alphabetic() || b == b'~' {
                    self.escape = false;
                }
                continue;
            }
            match b {
                0x1b => self.escape = true,
                b'\r' | b'\n' => {
                    let line = String::from_utf8_lossy(&self.line).trim().to_string();
                    self.line.clear();
                    if !line.is_empty() {
                        done.push(line);
                    }
                }
                0x7f | 0x08 => {
                    // Drop the last character, all of its UTF-8 bytes.
                    while let Some(last) = self.line.pop() {
                        if last & 0xC0 != 0x80 {
                            break;
                        }
                    }
                }
                0x15 => self.line.clear(),
                b if b >= 0x20 => self.line.push(b),
                _ => {}
            }
        }
        done
    }
}

/// A short name from the human's first request: its first words, without a slash command.
pub fn name_from_request(line: &str) -> Option<String> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('/') || line.starts_with('!') {
        return None;
    }
    let mut name = String::new();
    for word in line.split_whitespace().take(6) {
        if name.chars().count() + word.chars().count() + 1 > 48 {
            break;
        }
        if !name.is_empty() {
            name.push(' ');
        }
        name.push_str(word);
    }
    let name = name.trim_end_matches(|c: char| ",.;:!?".contains(c)).to_string();
    let mut chars = name.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().chain(chars).collect())
}

/// The human's shell: `HUB_SHELL`, else `$SHELL`, else zsh.
fn user_shell() -> String {
    std::env::var("HUB_SHELL")
        .or_else(|_| std::env::var("SHELL"))
        .unwrap_or_else(|_| "/bin/zsh".into())
}

/// A multiplexer session name for a target, e.g. `echo-lanh-a3`: letters, digits, `-` and `_`
/// only, since tmux treats `.` and `:` as separators.
fn mux_session(repo_name: &str, label: &str) -> String {
    let clean: String = repo_name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    format!("echo-{}-{label}", clean.trim_matches('-'))
}

/// `word` as one POSIX shell word.
fn shell_quote(word: &str) -> String {
    if !word.is_empty()
        && word
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_./=:@%+,".contains(c))
    {
        return word.to_string();
    }
    format!("'{}'", word.replace('\'', "'\\''"))
}

fn inherited_agent_vars() -> Vec<String> {
    std::env::vars()
        .map(|(key, _)| key)
        .filter(|key| is_agent_var(key))
        .collect()
}

fn is_agent_var(key: &str) -> bool {
    key == "CLAUDECODE"
        || key == "AI_AGENT"
        || key.starts_with("CLAUDE_CODE_")
        || key.starts_with("ORCA_")
        || key == "CLAUDE_PID"
        || key == "CLAUDE_EFFORT"
}

/// "in place" for the repo's own checkout, else the worktree's folder name.
fn place(repo: &Path, cwd: &Path) -> String {
    if cwd == repo {
        "in place".into()
    } else {
        cwd.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    }
}

/// Keys `hub worker key` understands, as terminal input.
pub fn key_bytes(key: &str) -> Result<Vec<u8>> {
    Ok(match key {
        "enter" => b"\r".to_vec(),
        "esc" => b"\x1b".to_vec(),
        "up" => b"\x1b[A".to_vec(),
        "down" => b"\x1b[B".to_vec(),
        "right" => b"\x1b[C".to_vec(),
        "left" => b"\x1b[D".to_vec(),
        "tab" => b"\t".to_vec(),
        "shift-tab" => b"\x1b[Z".to_vec(),
        "space" => b" ".to_vec(),
        "backspace" => b"\x7f".to_vec(),
        "ctrl-c" => b"\x03".to_vec(),
        single if single.chars().count() == 1 => single.as_bytes().to_vec(),
        other => bail!(
            "unknown key {other:?}; use enter, esc, up, down, left, right, tab, shift-tab, space, backspace, ctrl-c, or one character"
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mux_sessions_are_safe_names() {
        assert_eq!(mux_session("lanh", "a3"), "echo-lanh-a3");
        assert_eq!(mux_session("my.repo:v2", "w21"), "echo-my-repo-v2-w21");
    }

    #[test]
    fn shell_words_are_quoted_only_when_needed() {
        assert_eq!(shell_quote("/usr/local/bin/hub"), "/usr/local/bin/hub");
        assert_eq!(shell_quote("HUB_STATE=/tmp/x"), "HUB_STATE=/tmp/x");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn usage_lines_become_named_limits() {
        let text = "You are currently using your subscription to power your Claude Code usage\n\n\
                    Current session: 48% used · resets Oct 17 at 4:50pm (Asia/Saigon)\n\
                    Current week (all models): 9% used · resets Oct 23 at 11pm (Asia/Saigon)\n\
                    Current week (Fable): 0% used\n\
                    Last 24h · 1962 requests · 64 sessions\n  74% of your usage was at >150k context";
        let limits = parse_usage(text);
        assert_eq!(limits.len(), 3);
        assert_eq!(
            limits[0],
            json!({ "name": "Session", "percent": 48, "resets": "Oct 17 at 4:50pm" })
        );
        assert_eq!(limits[1]["name"], "Week");
        assert_eq!(
            limits[2],
            json!({ "name": "Week (Fable)", "percent": 0, "resets": null })
        );
    }

    #[test]
    fn a_first_request_names_an_agent() {
        assert_eq!(
            name_from_request("  run all the rerank follow-ups, verify each one, and keep the bench going").as_deref(),
            Some("Run all the rerank follow-ups, verify")
        );
        assert_eq!(name_from_request("fix it.").as_deref(), Some("Fix it"));
        assert_eq!(name_from_request("/model opus"), None);
        assert_eq!(name_from_request("   "), None);
    }

    #[test]
    fn typed_lines_skip_escapes_and_backspaces() {
        let mut reader = LineReader::default();
        assert!(reader.feed(b"fix th").is_empty());
        assert_eq!(reader.feed(b"\x1b[Ae\x7fe bug\r"), ["fix the bug"]);
        assert!(reader.feed(b"\r").is_empty(), "an empty Enter is not a line");
        assert_eq!(reader.feed("héllo\x7f\x7fo\r".as_bytes()), ["hélo"]);
        assert_eq!(reader.feed(b"/model opus\rfix it\r"), ["/model opus", "fix it"]);
    }

    #[test]
    fn titles_come_from_the_first_spec_line() {
        assert_eq!(title_from_spec("\n# Task: Add login\n\nmore"), "Add login");
        assert_eq!(title_from_spec("Fix the build"), "Fix the build");
        assert_eq!(title_from_spec(""), "Task");
    }

    #[test]
    fn keys_map_to_terminal_input() {
        assert_eq!(key_bytes("enter").unwrap(), b"\r");
        assert_eq!(key_bytes("down").unwrap(), b"\x1b[B");
        assert_eq!(key_bytes("2").unwrap(), b"2");
        assert!(key_bytes("hyper").is_err());
    }

    #[test]
    fn agent_session_markers_are_not_inherited() {
        assert!(is_agent_var("CLAUDE_CODE_CHILD_SESSION"));
        assert!(is_agent_var("CLAUDECODE"));
        assert!(is_agent_var("ORCA_TERMINAL_HANDLE"));
        assert!(!is_agent_var("CLAUDE_CONFIG_DIR"));
        assert!(!is_agent_var("PATH"));
    }

    #[test]
    fn place_names_worktrees() {
        assert_eq!(place(Path::new("/r"), Path::new("/r")), "in place");
        assert_eq!(place(Path::new("/r"), Path::new("/w/r/feat-x")), "feat-x");
    }
}
