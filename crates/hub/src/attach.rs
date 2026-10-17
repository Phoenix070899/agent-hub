//! `hub attach`: this terminal becomes the Worker's terminal until Ctrl-] or the Worker ends.

use std::io::{BufReader, Read, Write};
use std::sync::OnceLock;
use std::time::Duration;

use anyhow::Result;
use serde_json::{json, Value};

use crate::proto;

/// Ctrl-] detaches, as in telnet; the Worker keeps running.
const DETACH: u8 = 0x1d;

static ORIGINAL: OnceLock<libc::termios> = OnceLock::new();

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

/// Attaches to one terminal: `{"id": n}` for a Worker, `{"orchestrator": repo}` for the Orchestrator.
pub fn run(target: Value, label: &str) -> Result<()> {
    let (rows, cols) = size();
    let mut params = target.clone();
    params["rows"] = json!(rows);
    params["cols"] = json!(cols);
    let mut stream = proto::connect()?;
    proto::write_line(&mut stream, &json!({ "method": "attach", "params": params }))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    proto::into_result(proto::read_line(&mut reader)?)?;
    raw_mode();

    let ended = format!("{label} ended");
    std::thread::spawn(move || {
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
        restore_and_exit(&ended);
    });

    std::thread::spawn(move || {
        let mut last = (rows, cols);
        loop {
            std::thread::sleep(Duration::from_millis(300));
            let now = size();
            if now != last {
                last = now;
                let mut params = target.clone();
                params["rows"] = json!(now.0);
                params["cols"] = json!(now.1);
                let _ = proto::call("terminal.resize", params);
            }
        }
    });

    let mut stdin = std::io::stdin();
    let mut buf = [0u8; 4096];
    loop {
        let n = stdin.read(&mut buf)?;
        if n == 0 {
            restore_and_exit("detached");
        }
        let input = &buf[..n];
        if let Some(at) = input.iter().position(|&b| b == DETACH) {
            let _ = stream.write_all(&input[..at]);
            restore_and_exit(&format!("detached; {label} keeps running"));
        }
        if stream.write_all(input).is_err() {
            restore_and_exit(&format!("{label} ended"));
        }
    }
}
