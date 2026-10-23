//! The daemon protocol: one JSON request line, one JSON response line, over a Unix socket.
//! `attach` then turns the connection into a raw terminal stream.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::paths;

#[derive(Debug, Serialize, Deserialize)]
pub struct Request {
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

pub fn ok(result: Value) -> Value {
    json!({ "ok": true, "result": result })
}

pub fn err(error: &anyhow::Error) -> Value {
    json!({ "ok": false, "error": format!("{error:#}") })
}

pub fn write_line(stream: &mut impl Write, value: &Value) -> Result<()> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    stream.flush()?;
    Ok(())
}

pub fn read_line(reader: &mut impl BufRead) -> Result<Value> {
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        bail!("the Hub Daemon closed the connection");
    }
    Ok(serde_json::from_str(&line)?)
}

/// Unwraps a response line into its result, or its error.
pub fn into_result(response: Value) -> Result<Value> {
    if response["ok"].as_bool() == Some(true) {
        Ok(response["result"].clone())
    } else {
        bail!(
            "{}",
            response["error"]
                .as_str()
                .unwrap_or("the Hub Daemon refused the request")
        )
    }
}

/// Connects to the Hub Daemon, starting it first if it is not running.
pub fn connect() -> Result<UnixStream> {
    if let Ok(stream) = UnixStream::connect(paths::socket()) {
        return Ok(stream);
    }
    spawn_daemon()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match UnixStream::connect(paths::socket()) {
            Ok(stream) => return Ok(stream),
            Err(error) if Instant::now() >= deadline => {
                return Err(error)
                    .with_context(|| format!("the Hub Daemon did not start; see {}", paths::log().display()))
            }
            Err(_) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
}

fn spawn_daemon() -> Result<()> {
    std::fs::create_dir_all(paths::state_dir())?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths::log())?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("daemon")
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    // Its own session: the daemon must outlive the terminal and the agent that started it.
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut daemon = command.spawn().context("starting the Hub Daemon")?;
    // Reaped when it exits, so a long-lived caller like `hub attach --follow` leaves no zombie.
    std::thread::spawn(move || daemon.wait());
    Ok(())
}

pub fn call(method: &str, params: Value) -> Result<Value> {
    let mut stream = connect()?;
    write_line(&mut stream, &json!({ "method": method, "params": params }))?;
    into_result(read_line(&mut BufReader::new(stream))?)
}
