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
const SCREEN_LINES: usize = 25;

pub struct Hub {
    db: Mutex<Connection>,
    live: Mutex<HashMap<i64, Arc<Live>>>,
    tick: Mutex<u64>,
    changed: Condvar,
    hub_dir: PathBuf,
    /// Tests only: run this program with the spec instead of `claude`.
    test_agent: Option<String>,
}

pub fn run() -> Result<()> {
    std::fs::create_dir_all(paths::state_dir())?;
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
        tick: Mutex::new(0),
        changed: Condvar::new(),
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
            "worker.list" => self.list_workers(str_param(p, "repo")?),
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
            "worker.resize" => {
                let live = self.live(id_param(p, "id")?)?;
                live.resize(id_param(p, "rows")? as u16, id_param(p, "cols")? as u16)?;
                Ok(json!({}))
            }
            "worker.close" => self.close_worker(id_param(p, "id")?),
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
                db::insert_message(&db, &worker, kind::DONE, &format!("State: {final_state}\n\n{body}"))?;
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
                timeout_param(p, Duration::from_secs(3600)),
                stream,
            ),
            "reply" => {
                db::answer(&self.db(), id_param(p, "id")?, str_param(p, "body")?)?;
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
                let live = self.live.lock().unwrap().len();
                if live > 0 && !p.get("force").and_then(Value::as_bool).unwrap_or(false) {
                    bail!("{live} Worker(s) still live; close them first or pass --force");
                }
                for live in self.live.lock().unwrap().values() {
                    live.closing.store(true, std::sync::atomic::Ordering::SeqCst);
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
            env: vec![
                ("HUB_WORKER".into(), worker.id.to_string()),
                ("AGENT_HUB".into(), self.hub_dir.display().to_string()),
                ("HUB_STATE".into(), paths::state_dir().display().to_string()),
                ("TERM".into(), "xterm-256color".into()),
                ("COLORTERM".into(), "truecolor".into()),
            ],
        })
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
                        live.blocker.lock().unwrap().take();
                    }
                    Look::Idle => {}
                }
                let started = look == Look::Working || paths::transcript_exists(&worker.session_id);
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

    fn wait(&self, repo: &str, timeout: Duration, stream: &UnixStream) -> Result<Value> {
        let messages = self.wait_until(
            timeout,
            || peer_gone(stream),
            || {
                if peer_gone(stream) {
                    return Ok(None); // never hand messages to a listener that hung up
                }
                let taken = db::take_undelivered(&self.db(), repo)?;
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

    fn list_workers(&self, repo: &str) -> Result<Value> {
        let db = self.db();
        let mut out = Vec::new();
        for worker in db::workers(&db, repo)? {
            if worker.closed_at.is_none() {
                out.push(self.view(&db, &worker)?);
            }
        }
        Ok(json!({ "workers": out }))
    }

    /// The Dashboard rows: live Workers, and settled ones for a while after.
    fn status(&self, repo: &str) -> Result<Value> {
        let db = self.db();
        let now = db::now();
        let mut rows = Vec::new();
        for worker in db::workers(&db, repo)? {
            let recent = worker.settled_at.is_none_or(|at| now - at < KEEP_SETTLED_SECONDS);
            if !recent {
                continue;
            }
            let needs_you = !db::open_questions(&db, worker.id)?.is_empty()
                || self
                    .live(worker.id)
                    .is_ok_and(|live| live.blocker.lock().unwrap().is_some());
            let row_state = match worker.state.as_str() {
                state::DONE => "done",
                state::BLOCKED | state::LOST => "needs you",
                state::EXITED => "failed",
                _ if needs_you => "needs you",
                _ => "running",
            };
            rows.push(json!({
                "id": format!("w{}", worker.id),
                "profile": worker.profile,
                "title": worker.title,
                "state": row_state,
                "quietSeconds": (now - worker.last_message_at.unwrap_or(worker.created_at)).max(0),
                "place": place(Path::new(repo), Path::new(&worker.cwd)),
            }));
        }
        let order = |row: &Value| match row["state"].as_str() {
            Some("needs you") => 0,
            Some("running") => 1,
            Some("failed") => 2,
            _ => 3,
        };
        rows.sort_by_key(|row| (order(row), row["quietSeconds"].as_i64().unwrap_or(0)));
        Ok(json!({ "workers": rows }))
    }

    fn attach(&self, p: &Value, mut reader: BufReader<UnixStream>, mut stream: UnixStream) -> Result<()> {
        let live = match id_param(p, "id").and_then(|id| self.live(id)) {
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
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => live.write(&buf[..n])?,
            }
        }
        let _ = stream.shutdown(std::net::Shutdown::Both);
        Ok(())
    }
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
    fn place_names_worktrees() {
        assert_eq!(place(Path::new("/r"), Path::new("/r")), "in place");
        assert_eq!(place(Path::new("/r"), Path::new("/w/r/feat-x")), "feat-x");
    }
}
