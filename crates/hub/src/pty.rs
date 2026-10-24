//! One Worker's terminal: the agent process on a PTY the daemon owns, its parsed screen,
//! and the clients attached to it.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use anyhow::{Context, Result};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};

pub const ROWS: u16 = 45;
pub const COLS: u16 = 160;
/// Only the visible screen is ever read or redrawn; the attached terminal keeps its own history.
const SCROLLBACK: usize = 0;
/// Output chunks (16 KiB at most) queued for one attached client. A client that falls this far
/// behind, like a stopped `hub attach`, is let go rather than held in memory without limit; it
/// attaches again to a fresh screen.
const BACKLOG: usize = 1024;

pub struct Spawn {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
    /// Inherited variables to drop, e.g. another agent's session markers.
    pub env_remove: Vec<String>,
}

pub struct Live {
    pub id: i64,
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    parser: Mutex<vt100::Parser>,
    subscribers: Mutex<Vec<SyncSender<Arc<Vec<u8>>>>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    /// The blocker kind already reported for the current stretch, cleared when work resumes.
    pub blocker: Mutex<Option<String>>,
    /// Set by `hub worker close`, so the exit is not reported as a failure.
    pub closing: AtomicBool,
    alive: AtomicBool,
    started: Instant,
}

impl Live {
    /// Starts the process; `on_exit` runs on the reader thread once its output ends.
    pub fn spawn(id: i64, spawn: Spawn, on_exit: impl FnOnce(i64) + Send + 'static) -> Result<Arc<Live>> {
        let size = PtySize {
            rows: ROWS,
            cols: COLS,
            pixel_width: 0,
            pixel_height: 0,
        };
        let pair = native_pty_system().openpty(size).context("opening a PTY")?;
        let mut command = CommandBuilder::new(&spawn.program);
        command.args(&spawn.args);
        command.cwd(&spawn.cwd);
        for key in &spawn.env_remove {
            command.env_remove(key);
        }
        for (key, value) in &spawn.env {
            command.env(key, value);
        }
        let mut child = pair
            .slave
            .spawn_command(command)
            .with_context(|| format!("starting {}", spawn.program))?;
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader()?;
        let live = Arc::new(Live {
            id,
            writer: Mutex::new(pair.master.take_writer()?),
            master: Mutex::new(pair.master),
            parser: Mutex::new(vt100::Parser::new(ROWS, COLS, SCROLLBACK)),
            subscribers: Mutex::new(Vec::new()),
            killer: Mutex::new(child.clone_killer()),
            blocker: Mutex::new(None),
            closing: AtomicBool::new(false),
            alive: AtomicBool::new(true),
            started: Instant::now(),
        });
        let reading = Arc::clone(&live);
        std::thread::spawn(move || {
            let mut buf = [0u8; 16 * 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => reading.output(&buf[..n]),
                }
            }
            let _ = child.wait();
            reading.alive.store(false, Ordering::SeqCst);
            reading.subscribers.lock().unwrap().clear();
            on_exit(reading.id);
        });
        Ok(live)
    }

    /// Hands the bytes to every attached client before parsing them, so they never wait on the
    /// parser; the parser lock is held throughout, so a new subscriber's snapshot and its first
    /// chunk still line up.
    fn output(&self, bytes: &[u8]) {
        let mut parser = self.parser.lock().unwrap();
        let chunk = Arc::new(bytes.to_vec());
        self.subscribers
            .lock()
            .unwrap()
            .retain(|subscriber| subscriber.try_send(Arc::clone(&chunk)).is_ok());
        parser.process(bytes);
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    pub fn age(&self) -> std::time::Duration {
        self.started.elapsed()
    }

    /// The visible screen as plain text.
    pub fn screen(&self) -> String {
        self.parser.lock().unwrap().screen().contents()
    }

    /// Reads the parsed screen itself: its cells, colours, and modes.
    pub fn with_screen<T>(&self, read: impl FnOnce(&vt100::Screen) -> T) -> T {
        read(self.parser.lock().unwrap().screen())
    }

    pub fn write(&self, bytes: &[u8]) -> Result<()> {
        let mut writer = self.writer.lock().unwrap();
        writer.write_all(bytes)?;
        writer.flush()?;
        Ok(())
    }

    pub fn resize(&self, rows: u16, cols: u16) -> Result<()> {
        if rows == 0 || cols == 0 {
            return Ok(());
        }
        let mut parser = self.parser.lock().unwrap();
        self.master.lock().unwrap().resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        parser.screen_mut().set_size(rows, cols);
        Ok(())
    }

    /// The screen as escape codes that redraw it, and every byte of output after it.
    pub fn subscribe(&self) -> (Vec<u8>, Receiver<Arc<Vec<u8>>>) {
        let parser = self.parser.lock().unwrap();
        let (sender, receiver) = mpsc::sync_channel(BACKLOG);
        self.subscribers.lock().unwrap().push(sender);
        (parser.screen().state_formatted(), receiver)
    }

    pub fn kill(&self) {
        let _ = self.killer.lock().unwrap().kill();
    }
}
