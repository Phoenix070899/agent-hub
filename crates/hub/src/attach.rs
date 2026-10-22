//! `hub attach`: this terminal becomes a Worker's or an agent's terminal until Ctrl-] or it ends.
//! With `--follow` it stays put and reattaches whenever the agent starts again, which is how
//! Echo shows an agent inside the human's multiplexer. With `--echo` it is one of Echo's own
//! terminal panes: Ctrl-] is typed like any key, and the screen stays when the terminal ends.

use std::io::{BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::proto;

/// Ctrl-] detaches, as in telnet; the terminal keeps running.
const DETACH: u8 = 0x1d;
const CTRL_C: u8 = 0x03;

static ORIGINAL: OnceLock<libc::termios> = OnceLock::new();
/// Where typed input goes: the attached terminal, or nowhere while waiting.
static CURRENT: Mutex<Option<UnixStream>> = Mutex::new(None);
/// The attached terminal's params, for resizes.
static TARGET: Mutex<Option<Value>> = Mutex::new(None);
/// Running in an Echo pane (`--echo`).
static ECHO: AtomicBool = AtomicBool::new(false);

/// What `hub attach` names: `w12` (or `12`, `#12`) is a Worker, `a3` an agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Worker(i64),
    Agent(i64),
}

impl Target {
    pub fn parse(text: &str) -> Result<Target> {
        let bad = || format!("{text:?} is not a terminal like w12 or a3");
        if let Some(id) = text.strip_prefix('a') {
            return Ok(Target::Agent(id.parse().with_context(bad)?));
        }
        let id = text.trim_start_matches(['w', '#']).parse().with_context(bad)?;
        Ok(Target::Worker(id))
    }

    pub fn params(self) -> Value {
        match self {
            Target::Worker(id) => json!({ "id": id }),
            Target::Agent(id) => json!({ "agent": id }),
        }
    }

    fn label(self) -> String {
        match self {
            Target::Worker(id) => format!("w{id}"),
            Target::Agent(id) => format!("a{id}"),
        }
    }

    /// Whether it has a live terminal now; `None` once it is gone for good.
    fn live(self) -> Option<bool> {
        match self {
            Target::Worker(id) => Some(proto::call("worker.read", json!({ "id": id, "lines": 1 })).is_ok()),
            Target::Agent(id) => {
                let sessions = proto::call("sessions.list", json!({})).ok()?;
                sessions["sessions"]
                    .as_array()?
                    .iter()
                    .flat_map(|s| s["agents"].as_array().cloned().unwrap_or_default())
                    .find(|a| a["id"].as_i64() == Some(id))
                    .map(|a| a["live"].as_bool() == Some(true))
            }
        }
    }
}

fn size() -> (u16, u16) {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) } == 0 && ws.ws_row > 0 {
        (ws.ws_row, ws.ws_col)
    } else {
        (crate::pty::ROWS, crate::pty::COLS)
    }
}

fn raw_mode() {
    unsafe {
        let mut term: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(libc::STDIN_FILENO, &mut term) != 0 {
            return;
        }
        let _ = ORIGINAL.set(term);
        libc::cfmakeraw(&mut term);
        libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &term);
    }
}

fn restore_and_exit(note: &str) -> ! {
    if let Some(term) = ORIGINAL.get() {
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, term) };
    }
    eprintln!("\r\n[hub: {note}]");
    std::process::exit(0)
}

/// A line in raw mode, between attachments.
fn say(note: &str) {
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\r\n\x1b[2m[hub: {note}]\x1b[0m\r\n");
    let _ = stdout.flush();
}

/// Opens an `attach` connection: the stream to type into, and the reader the terminal's bytes
/// arrive on (it may already hold some, read along with the response line).
fn connect(params: &Value) -> Result<(UnixStream, BufReader<UnixStream>)> {
    let (rows, cols) = size();
    let mut params = params.clone();
    params["rows"] = json!(rows);
    params["cols"] = json!(cols);
    let mut stream = proto::connect()?;
    proto::write_line(&mut stream, &json!({ "method": "attach", "params": params }))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    proto::into_result(proto::read_line(&mut reader)?)?;
    Ok((stream, reader))
}

/// Typed input goes to whatever is attached; Ctrl-] leaves. While nothing is attached, Ctrl-C
/// leaves too.
fn forward_input(label: String, follow: bool) {
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut buf = [0u8; 4096];
        loop {
            let n = match stdin.read(&mut buf) {
                Ok(0) | Err(_) => restore_and_exit("detached"),
                Ok(n) => n,
            };
            let input = &buf[..n];
            let mut current = CURRENT.lock().unwrap();
            let Some(stream) = current.as_mut() else {
                if !ECHO.load(Ordering::Relaxed) && (input.contains(&DETACH) || input.contains(&CTRL_C)) {
                    restore_and_exit(&format!("stopped following {label}"));
                }
                continue;
            };
            if let Some(at) = input.iter().position(|&b| b == DETACH && !ECHO.load(Ordering::Relaxed)) {
                let _ = stream.write_all(&input[..at]);
                let note = if follow {
                    format!("stopped following {label}; it keeps running")
                } else {
                    format!("detached; {label} keeps running")
                };
                restore_and_exit(&note);
            }
            if stream.write_all(input).is_err() {
                *current = None;
            }
        }
    });
}

fn winch() -> libc::sigset_t {
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    unsafe {
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGWINCH);
    }
    set
}

/// Passes this terminal's size on to whatever is attached once it has held for `SETTLE`, so a
/// window being dragged resizes the agent once, not at every step. Call it before starting any
/// other thread: SIGWINCH is blocked here so that only its own thread takes it.
fn forward_resizes() {
    const SETTLE: Duration = Duration::from_millis(200);
    // SIGWINCH is ignored by default, and macOS drops an ignored signal even while it is blocked,
    // so `sigwait` would never see it; a handler that does nothing keeps it pending.
    extern "C" fn pending(_: libc::c_int) {}
    let set = winch();
    unsafe {
        libc::signal(libc::SIGWINCH, pending as *const () as libc::sighandler_t);
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
    }
    let (changed, changes) = std::sync::mpsc::channel();
    std::thread::spawn(move || loop {
        let mut signal = 0;
        if unsafe { libc::sigwait(&set, &mut signal) } != 0 || changed.send(()).is_err() {
            return;
        }
    });
    std::thread::spawn(move || {
        let mut last = size();
        while changes.recv().is_ok() {
            while changes.recv_timeout(SETTLE).is_ok() {}
            let now = size();
            if now != last {
                last = now;
                if let Some(mut params) = TARGET.lock().unwrap().clone() {
                    params["rows"] = json!(now.0);
                    params["cols"] = json!(now.1);
                    let _ = proto::call("terminal.resize", params);
                }
            }
        }
    });
}

/// Copies the terminal's bytes here until it ends.
fn pump((stream, mut reader): (UnixStream, BufReader<UnixStream>), params: &Value) {
    *TARGET.lock().unwrap() = Some(params.clone());
    *CURRENT.lock().unwrap() = Some(stream);
    let mut stdout = std::io::stdout();
    let mut buf = [0u8; 16 * 1024];
    loop {
        match reader.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let _ = stdout.write_all(&buf[..n]);
                let _ = stdout.flush();
            }
        }
    }
    *CURRENT.lock().unwrap() = None;
    *TARGET.lock().unwrap() = None;
}

/// Attaches to one terminal (`{"id": n}` for a Worker, `{"agent": n}` for an agent) until it
/// ends or Ctrl-] detaches.
pub fn run(target: Value, label: &str) -> Result<()> {
    let attached = connect(&target)?;
    forward_resizes();
    raw_mode();
    forward_input(label.to_string(), false);
    pump(attached, &target);
    restore_and_exit(&format!("{label} ended"))
}

/// An Echo pane: attaches once, and when the terminal ends, or cannot be reached, says so and
/// keeps the screen until Echo closes the pane.
pub fn echo(target: Target) -> ! {
    ECHO.store(true, Ordering::Relaxed);
    let params = target.params();
    forward_resizes();
    raw_mode();
    forward_input(target.label(), false);
    match connect(&params) {
        Ok(attached) => {
            pump(attached, &params);
            say_dim("terminal ended");
        }
        Err(error) => say_dim(&format!("{error:#}")),
    }
    loop {
        std::thread::park();
    }
}

fn say_dim(note: &str) {
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\r\n\x1b[2m[{note}]\x1b[0m\r\n");
    let _ = stdout.flush();
}

/// Shows `target` here for as long as it exists: when its terminal ends it waits, and attaches
/// again when it starts. Leaves once it is gone for good, or on Ctrl-].
pub fn follow(target: Target) -> Result<()> {
    let label = target.label();
    let params = target.params();
    forward_resizes();
    raw_mode();
    forward_input(label.clone(), true);
    let mut first = true;
    loop {
        match connect(&params) {
            Ok(attached) => {
                if !first {
                    // A fresh screen: the daemon redraws the terminal from its own copy.
                    print!("\x1b[2J\x1b[H");
                }
                pump(attached, &params);
                say(&format!("{label} stopped. This pane picks it up again when it starts."));
            }
            Err(_) if first => say(&format!(
                "{label} is not running. This pane picks it up when it starts."
            )),
            Err(_) => {}
        }
        first = false;
        loop {
            std::thread::sleep(Duration::from_secs(1));
            match target.live() {
                None => restore_and_exit(&format!("{label} is closed")),
                Some(true) => break,
                Some(false) if matches!(target, Target::Worker(_)) => restore_and_exit(&format!("{label} ended")),
                Some(false) => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn targets_name_workers_and_agents() {
        assert_eq!(Target::parse("w12").unwrap(), Target::Worker(12));
        assert_eq!(Target::parse("#12").unwrap(), Target::Worker(12));
        assert_eq!(Target::parse("12").unwrap(), Target::Worker(12));
        assert_eq!(Target::parse("a3").unwrap(), Target::Agent(3));
        assert!(Target::parse("ax").is_err());
        assert_eq!(Target::Agent(3).label(), "a3");
        assert_eq!(Target::Agent(3).params(), json!({ "agent": 3 }));
    }
}
