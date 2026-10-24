//! Echo Remote (ADR 0008): the phone web app the Hub Daemon serves. It listens on 127.0.0.1 only;
//! `tailscale serve` carries it to the human's tailnet over HTTPS. It reads the ledger and screens
//! in-process and sends every action through the daemon's socket, as Echo does.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::daemon::Hub;
use crate::paths;
use crate::proto;
use crate::push::{self, Sent, Subscription};

pub const LOCAL_PORT: u16 = 7480;
/// The HTTPS port `tailscale serve` listens on, on the tailnet: the default, so the phone's
/// address has no port in it.
pub const TAILNET_PORT: u16 = 443;
const COOKIE: &str = "echo_remote";
/// Only what Echo's own buttons do; `reply` always counts as the human's.
const ACTIONS: &[&str] = &[
    "decide",
    "reply",
    "terminal.send",
    "terminal.key",
    "agent.open",
    "agent.close",
    "worker.dismiss",
    "branches.list",
];
const MAX_HEADERS: usize = 32 * 1024;
const MAX_BODY: usize = 256 * 1024;

const INDEX: &str = include_str!("../remote/index.html");
const SERVICE_WORKER: &str = include_str!("../remote/sw.js");
const MANIFEST: &str = include_str!("../remote/manifest.webmanifest");
const ICON_180: &[u8] = include_bytes!("../remote/icon-180.png");
const ICON_192: &[u8] = include_bytes!("../remote/icon-192.png");
const ICON_512: &[u8] = include_bytes!("../remote/icon-512.png");

/// `$HUB_STATE/remote.json`, mode 0600: whether Echo Remote is on, the pairing token, the VAPID
/// keys, and the phones that asked for notifications.
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub enabled: bool,
    /// 0 means LOCAL_PORT; tests set their own.
    pub port: u16,
    pub token: String,
    pub vapid_private: String,
    pub vapid_public: String,
    pub subscriptions: Vec<Subscription>,
}

impl Config {
    fn path() -> PathBuf {
        paths::state_dir().join("remote.json")
    }

    fn load() -> Config {
        std::fs::read(Self::path())
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn save(&self) -> Result<()> {
        let path = Self::path();
        let temp = path.with_extension("json.new");
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(&serde_json::to_vec_pretty(self)?)?;
        drop(file);
        std::fs::rename(&temp, &path)?;
        Ok(())
    }

    fn port(&self) -> u16 {
        if self.port == 0 {
            LOCAL_PORT
        } else {
            self.port
        }
    }

    /// A token and VAPID keys, made the first time they are needed.
    fn ensure_keys(&mut self) {
        if self.token.is_empty() {
            self.token = push::random_token();
        }
        if self.vapid_private.is_empty() {
            (self.vapid_private, self.vapid_public) = push::new_vapid_keys();
        }
    }
}

pub struct Remote {
    config: Mutex<Config>,
    /// The running server's stop flag; none while off.
    running: Mutex<Option<Arc<AtomicBool>>>,
    /// Why it is not serving as asked: the port taken, or Tailscale failing.
    error: Mutex<Option<String>>,
    /// This Mac's tailnet name, or why there is none, and when it was read: Echo asks for the
    /// status every few seconds, and the CLI can take that long itself.
    tailnet: Mutex<Option<(Instant, std::result::Result<String, String>)>>,
}

impl Remote {
    pub fn load() -> Remote {
        Remote {
            config: Mutex::new(Config::load()),
            running: Mutex::new(None),
            error: Mutex::new(None),
            tailnet: Mutex::new(None),
        }
    }

    fn config(&self) -> Config {
        self.config.lock().unwrap().clone()
    }

    fn update(&self, change: impl FnOnce(&mut Config)) -> Result<()> {
        let mut config = self.config.lock().unwrap();
        change(&mut config);
        config.save()
    }
}

/// At daemon start: serve again if the human left Echo Remote on.
pub fn start_if_enabled(hub: &Arc<Hub>) {
    if hub.remote().config().enabled {
        if let Err(error) = start(hub) {
            eprintln!("hubd: Echo Remote: {error:#}");
            *hub.remote().error.lock().unwrap() = Some(format!("{error:#}"));
        }
    }
}

/// `remote.enable`: turns Echo Remote on, serves it, and puts it on the tailnet.
pub fn enable(hub: &Arc<Hub>, port: Option<u16>) -> Result<Value> {
    let remote = hub.remote();
    remote.update(|config| {
        config.enabled = true;
        config.ensure_keys();
        if let Some(port) = port {
            config.port = port;
        }
    })?;
    *remote.error.lock().unwrap() = None;
    if let Err(error) = start(hub) {
        *remote.error.lock().unwrap() = Some(format!("{error:#}"));
    }
    Ok(status(hub))
}

/// `remote.disable`: stops serving and takes it off the tailnet. The pairing stays.
pub fn disable(hub: &Arc<Hub>) -> Result<Value> {
    let remote = hub.remote();
    remote.update(|config| config.enabled = false)?;
    stop(remote);
    if !hub.is_test() {
        if let Some(cli) = tailscale() {
            let _ = run_tailscale(&cli, &["serve", &format!("--https={TAILNET_PORT}"), "off"]);
        }
    }
    *remote.error.lock().unwrap() = None;
    Ok(status(hub))
}

/// `remote.pair`: a new token, so every phone paired before must pair again.
pub fn new_pairing(hub: &Arc<Hub>) -> Result<Value> {
    hub.remote().update(|config| {
        config.token = push::random_token();
        config.subscriptions.clear();
    })?;
    Ok(status(hub))
}

/// `remote.status`: what Echo's settings and `hub remote` show.
pub fn status(hub: &Arc<Hub>) -> Value {
    let remote = hub.remote();
    let config = remote.config();
    let running = remote.running.lock().unwrap().is_some();
    let local = format!("http://127.0.0.1:{}", config.port());
    let (tailscale_state, url) = match (hub.is_test(), tailscale()) {
        (true, _) => ("test".to_string(), None),
        (false, None) => ("missing".to_string(), None),
        (false, Some(cli)) => match remote.tailnet_name(&cli) {
            Ok(name) => ("ready".to_string(), Some(format!("https://{name}"))),
            Err(error) => (error, None),
        },
    };
    let base = url.clone().unwrap_or_else(|| local.clone());
    json!({
        "enabled": config.enabled,
        "running": running,
        "error": remote.error.lock().unwrap().clone(),
        "local": local,
        "url": url,
        "tailscale": tailscale_state,
        "pairLink": (!config.token.is_empty()).then(|| format!("{base}/#pair={}", config.token)),
        "phones": config.subscriptions.len(),
    })
}

fn start(hub: &Arc<Hub>) -> Result<()> {
    let remote = hub.remote();
    let config = remote.config();
    if remote.running.lock().unwrap().is_none() {
        let listener = TcpListener::bind(("127.0.0.1", config.port()))
            .with_context(|| format!("port {} on 127.0.0.1 is taken", config.port()))?;
        let stop = Arc::new(AtomicBool::new(false));
        *remote.running.lock().unwrap() = Some(Arc::clone(&stop));
        let server = Arc::clone(hub);
        let serving = Arc::clone(&stop);
        std::thread::spawn(move || serve(server, listener, serving));
        let watcher = Arc::clone(hub);
        let watching = Arc::clone(&stop);
        std::thread::spawn(move || watch(watcher, watching));
    }
    if !hub.is_test() {
        match tailscale() {
            None => bail!("Tailscale is not installed: get it from tailscale.com/download, on this Mac and the phone"),
            Some(cli) => {
                let target = format!("http://127.0.0.1:{}", config.port());
                run_tailscale(&cli, &["serve", "--bg", &format!("--https={TAILNET_PORT}"), &target])
                    .context("tailscale serve")?;
                *remote.tailnet.lock().unwrap() = None;
            }
        }
    }
    Ok(())
}

fn stop(remote: &Remote) {
    let Some(flag) = remote.running.lock().unwrap().take() else {
        return;
    };
    flag.store(true, Ordering::SeqCst);
    // Wake the accept loop so it sees the flag and lets the port go.
    let _ = TcpStream::connect(("127.0.0.1", remote.config().port()));
}

/// The `tailscale` CLI: the Mac app's, or Homebrew's.
fn tailscale() -> Option<PathBuf> {
    let known = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ];
    known.iter().map(PathBuf::from).find(|path| path.exists())
}

impl Remote {
    /// This Mac's name on the tailnet, read at most every 30 seconds.
    fn tailnet_name(&self, cli: &Path) -> std::result::Result<String, String> {
        if let Some((at, name)) = self.tailnet.lock().unwrap().as_ref() {
            if at.elapsed() < Duration::from_secs(30) {
                return name.clone();
            }
        }
        let name = tailnet_name(cli).map_err(|error| format!("{error:#}"));
        let before = self.tailnet.lock().unwrap().replace((Instant::now(), name.clone()));
        // Renamed in the Tailscale console: Serve answers only to the old name until it is set
        // up again.
        let renamed = matches!((&before, &name), (Some((_, Ok(old))), Ok(new)) if old != new);
        if renamed && self.running.lock().unwrap().is_some() {
            let https = format!("--https={TAILNET_PORT}");
            let target = format!("http://127.0.0.1:{}", self.config().port());
            let _ = run_tailscale(cli, &["serve", &https, "off"]);
            if let Err(error) = run_tailscale(cli, &["serve", "--bg", &https, &target]) {
                *self.error.lock().unwrap() = Some(format!("tailscale serve: {error:#}"));
            }
        }
        name
    }
}

/// Runs the Tailscale CLI, giving up after 8 seconds: the Mac app's CLI can hang, or fail to
/// reach the app, when started outside the human's login session.
fn run_tailscale(cli: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let mut child = Command::new(cli)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("running tailscale")?;
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let out = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.read_to_end(&mut bytes);
        bytes
    });
    let err = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stderr.read_to_string(&mut text);
        text
    });
    let deadline = Instant::now() + Duration::from_secs(8);
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            // `tailscale serve` waits here while the tailnet has not allowed Serve yet, after
            // printing the link that allows it: pass that on.
            let printed = format!(
                "{}{}",
                String::from_utf8_lossy(&out.join().unwrap_or_default()),
                err.join().unwrap_or_default()
            );
            let printed = printed.trim();
            if printed.is_empty() {
                bail!("Tailscale did not answer within 8 seconds");
            }
            bail!("Tailscale did not finish within 8 seconds: {printed}");
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    let stdout = out.join().unwrap_or_default();
    let stderr = err.join().unwrap_or_default();
    if !status.success() {
        let why = stderr.trim();
        bail!("{}", if why.is_empty() { "Tailscale failed" } else { why });
    }
    Ok(stdout)
}

/// This Mac's name on the tailnet, like `mac.tail1234.ts.net`.
fn tailnet_name(cli: &Path) -> Result<String> {
    let out = run_tailscale(cli, &["status", "--json"])?;
    let status: Value = serde_json::from_slice(&out).context("Tailscale is not running")?;
    if status["BackendState"].as_str() != Some("Running") {
        bail!("Tailscale is not connected; open it and log in");
    }
    let name = status["Self"]["DNSName"]
        .as_str()
        .unwrap_or_default()
        .trim_end_matches('.');
    if name.is_empty() {
        bail!("Tailscale gave this Mac no name; turn on MagicDNS in the Tailscale admin console");
    }
    Ok(name.to_string())
}

fn serve(hub: Arc<Hub>, listener: TcpListener, stop: Arc<AtomicBool>) {
    for stream in listener.incoming() {
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let Ok(stream) = stream else { continue };
        let hub = Arc::clone(&hub);
        let stop = Arc::clone(&stop);
        std::thread::spawn(move || {
            if let Err(error) = handle(&hub, stream, &stop) {
                eprintln!("hubd: Echo Remote: {error:#}");
            }
        });
    }
}

struct Request {
    method: String,
    path: String,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

impl Request {
    fn header(&self, name: &str) -> &str {
        self.headers.get(name).map(String::as_str).unwrap_or("")
    }

    fn cookie(&self, name: &str) -> Option<&str> {
        self.header("cookie").split(';').find_map(|pair| {
            let (key, value) = pair.trim().split_once('=')?;
            (key == name).then_some(value)
        })
    }

    /// Whether it came from this Mac rather than through `tailscale serve`.
    fn is_local(&self) -> bool {
        let host = self.header("host");
        host.starts_with("127.0.0.1") || host.starts_with("localhost")
    }
}

fn read_request(stream: &TcpStream) -> Result<Request> {
    stream.set_read_timeout(Some(Duration::from_secs(15)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let mut parts = line.split_whitespace();
    let method = parts.next().context("empty request")?.to_string();
    let target = parts.next().context("no request target")?.to_string();
    let mut headers = HashMap::new();
    let mut size = line.len();
    loop {
        line.clear();
        size += reader.read_line(&mut line)?;
        if size > MAX_HEADERS {
            bail!("headers too large");
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((key, value)) = line.split_once(':') {
            headers.insert(key.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }
    let length: usize = headers.get("content-length").and_then(|n| n.parse().ok()).unwrap_or(0);
    if length > MAX_BODY {
        bail!("body too large");
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    Ok(Request {
        method,
        path: path.to_string(),
        query: query
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        headers,
        body,
    })
}

fn respond(stream: &mut TcpStream, status: u16, content_type: &str, extra: &[String], body: &[u8]) -> Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Error",
    };
    let mut head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n\
         Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\
         Referrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n",
        body.len()
    );
    if content_type.starts_with("text/html") {
        head.push_str(
            "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; \
             style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'\r\n",
        );
    }
    for header in extra {
        head.push_str(header);
        head.push_str("\r\n");
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()?;
    Ok(())
}

fn json_reply(stream: &mut TcpStream, status: u16, value: &Value) -> Result<()> {
    respond(stream, status, "application/json", &[], value.to_string().as_bytes())
}

/// Equal without leaking how much of the token matched through timing.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |diff, (x, y)| diff | (x ^ y)) == 0
}

fn handle(hub: &Arc<Hub>, mut stream: TcpStream, stop: &AtomicBool) -> Result<()> {
    let request = read_request(&stream)?;
    let get = request.method == "GET";
    match request.path.as_str() {
        "/" | "/index.html" if get => {
            return respond(&mut stream, 200, "text/html; charset=utf-8", &[], INDEX.as_bytes())
        }
        // The service worker must not be cached, so a new one reaches the phone.
        "/sw.js" if get => return respond(&mut stream, 200, "text/javascript", &[], SERVICE_WORKER.as_bytes()),
        "/manifest.webmanifest" if get => {
            return respond(&mut stream, 200, "application/manifest+json", &[], MANIFEST.as_bytes())
        }
        "/icon-180.png" if get => return respond(&mut stream, 200, "image/png", &[], ICON_180),
        "/icon-192.png" if get => return respond(&mut stream, 200, "image/png", &[], ICON_192),
        "/icon-512.png" if get => return respond(&mut stream, 200, "image/png", &[], ICON_512),
        path if !path.starts_with("/api/") => return json_reply(&mut stream, 404, &json!({ "error": "not found" })),
        _ => {}
    }
    if !get {
        // Another site's page cannot post here: a browser always says where a cross-site post
        // comes from, and a form cannot send JSON.
        let origin = request.header("origin");
        let host = request.header("host");
        let same_site = origin.is_empty() || origin.split("://").nth(1) == Some(host);
        if !same_site || !request.header("content-type").starts_with("application/json") {
            return json_reply(&mut stream, 403, &json!({ "error": "cross-site request" }));
        }
    }
    let body: Value = if request.body.is_empty() {
        json!({})
    } else {
        match serde_json::from_slice(&request.body) {
            Ok(body) => body,
            Err(_) => return json_reply(&mut stream, 400, &json!({ "error": "the body is not JSON" })),
        }
    };
    let config = hub.remote().config();
    if request.path == "/api/pair" && !get {
        let given = body["token"].as_str().unwrap_or_default();
        if config.token.is_empty() || !same(given, &config.token) {
            return json_reply(
                &mut stream,
                403,
                &json!({ "error": "That pairing link is old. Copy a new one from Echo's settings." }),
            );
        }
        let secure = if request.is_local() { "" } else { "; Secure" };
        let cookie = format!(
            "Set-Cookie: {COOKIE}={}; Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000{secure}",
            config.token
        );
        return respond(&mut stream, 200, "application/json", &[cookie], b"{}");
    }
    let paired = request
        .cookie(COOKIE)
        .is_some_and(|given| !config.token.is_empty() && same(given, &config.token));
    if !paired {
        return json_reply(&mut stream, 401, &json!({ "error": "not paired" }));
    }
    match (request.method.as_str(), request.path.as_str()) {
        ("GET", "/api/stream") => stream_world(hub, stream, stop),
        ("GET", "/api/screen") => {
            let id = |key: &str| request.query.get(key).and_then(|v| v.parse::<i64>().ok());
            let screen = hub
                .running_terminal(id("agent"), id("worker"))
                .map(|live| live.with_screen(screen_html));
            json_reply(
                &mut stream,
                200,
                &json!({ "live": screen.is_some(), "html": screen.unwrap_or_default() }),
            )
        }
        ("POST", path) if path.starts_with("/api/call/") => {
            let method = &path["/api/call/".len()..];
            if !ACTIONS.contains(&method) {
                return json_reply(
                    &mut stream,
                    403,
                    &json!({ "error": format!("{method} is not allowed") }),
                );
            }
            let mut params = body;
            if method == "reply" {
                params["by_human"] = json!(true);
            }
            let response = call(method, params).unwrap_or_else(|error| proto::err(&error));
            json_reply(&mut stream, 200, &response)
        }
        ("GET", "/api/push/key") => json_reply(&mut stream, 200, &json!({ "key": config.vapid_public })),
        ("POST", "/api/push/subscribe") => {
            let subscription: Subscription = match serde_json::from_value(body) {
                Ok(subscription) => subscription,
                Err(_) => return json_reply(&mut stream, 400, &json!({ "error": "not a push subscription" })),
            };
            hub.remote().update(|config| {
                config.subscriptions.retain(|s| s.endpoint != subscription.endpoint);
                config.subscriptions.push(subscription);
            })?;
            json_reply(&mut stream, 200, &json!({}))
        }
        ("POST", "/api/push/unsubscribe") => {
            let endpoint = body["endpoint"].as_str().unwrap_or_default().to_string();
            hub.remote()
                .update(|config| config.subscriptions.retain(|s| s.endpoint != endpoint))?;
            json_reply(&mut stream, 200, &json!({}))
        }
        ("POST", "/api/push/test") => {
            let endpoint = body["endpoint"].as_str().unwrap_or_default();
            let Some(subscription) = config.subscriptions.iter().find(|s| s.endpoint == endpoint) else {
                return json_reply(
                    &mut stream,
                    404,
                    &json!({ "error": "this phone has not turned on notifications" }),
                );
            };
            let payload = json!({ "title": "Echo Remote", "body": "Notifications work.", "tag": "test", "url": "/" });
            match push::send(subscription, &config.vapid_private, payload.to_string().as_bytes()) {
                Ok(_) => json_reply(&mut stream, 200, &json!({})),
                Err(error) => json_reply(&mut stream, 200, &json!({ "error": format!("{error:#}") })),
            }
        }
        _ => json_reply(&mut stream, 404, &json!({ "error": "not found" })),
    }
}

/// One request on the daemon's socket, as Echo sends it.
fn call(method: &str, params: Value) -> Result<Value> {
    let mut socket = UnixStream::connect(paths::socket())?;
    proto::write_line(&mut socket, &json!({ "method": method, "params": params }))?;
    proto::read_line(&mut BufReader::new(socket))
}

/// Server-sent events: the whole ledger now, after every change, and a ping every 15 seconds
/// so proxies keep the connection open; until the phone leaves.
fn stream_world(hub: &Arc<Hub>, mut stream: TcpStream, stop: &AtomicBool) -> Result<()> {
    stream.write_all(
        b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\
          Connection: close\r\nX-Accel-Buffering: no\r\n\r\n",
    )?;
    let mut last = None;
    let mut seen = hub.tick();
    loop {
        if stop.load(Ordering::SeqCst) {
            return Ok(());
        }
        let world = hub.world()?;
        let line = if last.as_ref() != Some(&world) {
            let line = format!("data: {world}\n\n");
            last = Some(world);
            line
        } else {
            ": ping\n\n".to_string()
        };
        if stream.write_all(line.as_bytes()).and_then(|_| stream.flush()).is_err() {
            return Ok(());
        }
        seen = hub.wait_change(seen, Duration::from_secs(15));
    }
}

/// Pushes each new Need and each new Final Report to every phone that asked; what was already
/// there when Echo Remote started is not announced.
fn watch(hub: Arc<Hub>, stop: Arc<AtomicBool>) {
    let mut seen: Option<HashSet<String>> = None;
    let mut tick = hub.tick();
    while !stop.load(Ordering::SeqCst) {
        if let Ok(world) = hub.world() {
            let alerts = alerts(&world);
            let current: HashSet<String> = alerts.iter().map(|(key, _)| key.clone()).collect();
            if let Some(seen) = &seen {
                let fresh: Vec<Value> = alerts
                    .into_iter()
                    .filter(|(key, _)| !seen.contains(key))
                    .map(|(_, payload)| payload)
                    .collect();
                if !fresh.is_empty() {
                    let hub = Arc::clone(&hub);
                    std::thread::spawn(move || deliver(&hub, &fresh));
                }
            }
            seen = Some(current);
        }
        tick = hub.wait_change(tick, Duration::from_secs(30));
    }
}

fn deliver(hub: &Arc<Hub>, payloads: &[Value]) {
    let config = hub.remote().config();
    let mut gone = Vec::new();
    for subscription in &config.subscriptions {
        for payload in payloads {
            match push::send(subscription, &config.vapid_private, payload.to_string().as_bytes()) {
                Ok(Sent::Delivered) => {}
                Ok(Sent::Gone) => {
                    gone.push(subscription.endpoint.clone());
                    break;
                }
                Err(error) => eprintln!("hubd: Echo Remote push: {error:#}"),
            }
        }
    }
    if !gone.is_empty() {
        let _ = hub
            .remote()
            .update(|config| config.subscriptions.retain(|s| !gone.contains(&s.endpoint)));
    }
}

/// Every Need and Final Report in the ledger, keyed so the same one is announced once, with its
/// notification.
fn alerts(world: &Value) -> Vec<(String, Value)> {
    let mut out = Vec::new();
    for repo in world["repos"].as_array().into_iter().flatten() {
        let path = repo["repo"].as_str().unwrap_or_default();
        let repo_name = Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let agent_name = |id: Option<i64>| {
            repo["agents"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|a| a["id"].as_i64() == id)
                .map(|a| agent_title(a))
        };
        for need in repo["needs"].as_array().into_iter().flatten() {
            let kind = need["kind"].as_str().unwrap_or("other");
            let agent = need["agent"].as_i64();
            let key = match need["worker"].as_str() {
                Some(_) => format!("{kind}-{}", need["message"]),
                None => format!("{kind}-agent-{}-{}", agent.unwrap_or(0), need["at"]),
            };
            // As Echo heads it.
            let who = match need["worker"].as_str() {
                Some(worker) => format!("{worker} {}", need["profile"].as_str().unwrap_or("")),
                None if need["profile"] == "orchestrator" => "The Orchestrator".to_string(),
                None => "Claude Code".to_string(),
            };
            let (title, text) = match kind {
                "permission_prompt" => (format!("{who} wants to run"), command(need)),
                "question" => (format!("{who} asks"), need["body"].as_str().unwrap_or("").to_string()),
                "idle_prompt" => (
                    format!("{who} is idle"),
                    "Idle at its prompt with no Final Report.".into(),
                ),
                _ => (
                    format!("{who} needs you"),
                    first_line(need["body"].as_str().unwrap_or("")),
                ),
            };
            let place = match agent_name(agent) {
                Some(name) => format!("{repo_name}, {name}"),
                None => repo_name.clone(),
            };
            let url = format!("/#need={}", url_encode(&key));
            out.push((
                key.clone(),
                json!({ "title": title, "body": format!("{text}\n{place}"), "tag": key, "url": url }),
            ));
        }
        for worker in repo["workers"].as_array().into_iter().flatten() {
            let state = worker["state"].as_str().unwrap_or("");
            if !matches!(state, "done" | "failed") {
                continue;
            }
            let id = worker["id"].as_str().unwrap_or("");
            let key = format!("report-{id}-{}", worker["settledAt"]);
            let verb = if state == "done" { "finished" } else { "stopped" };
            let report = first_line(worker["finalReport"].as_str().unwrap_or("No Final Report."));
            let title = format!("{id} {verb}: {}", worker["title"].as_str().unwrap_or(""));
            let url = format!("/#worker={}", id.trim_start_matches('w'));
            out.push((
                key.clone(),
                json!({ "title": title, "body": format!("{report}\n{repo_name}"), "tag": key, "url": url }),
            ));
        }
    }
    out
}

fn agent_title(agent: &Value) -> String {
    match agent["name"].as_str() {
        Some(name) => name.to_string(),
        None => match agent["kind"].as_str() {
            Some("claude") => "Claude Code".into(),
            Some("terminal") => "Terminal".into(),
            _ => "Orchestrator".into(),
        },
    }
}

/// A permission prompt's command on one line, as Echo shows it.
fn command(need: &Value) -> String {
    let lines: Vec<&str> = need["prompt"]
        .as_str()
        .unwrap_or("")
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("Do you want"))
        .collect();
    match lines.len() {
        0 => need["body"].as_str().unwrap_or("").to_string(),
        1 => lines[0].to_string(),
        _ => lines[1..].join(" "),
    }
}

fn first_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("")
        .to_string()
}

fn url_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The screen as HTML: one line per row, runs of the same colours in one span, trailing blanks
/// left out.
pub fn screen_html(screen: &vt100::Screen) -> String {
    let (rows, cols) = screen.size();
    let mut lines: Vec<String> = Vec::with_capacity(rows as usize);
    for row in 0..rows {
        // Up to the last cell with text or a coloured background.
        let end = (0..cols)
            .rev()
            .find(|&col| {
                screen.cell(row, col).is_some_and(|cell| {
                    cell.has_contents() || cell.bgcolor() != vt100::Color::Default || cell.inverse()
                })
            })
            .map_or(0, |col| col + 1);
        let mut line = String::new();
        let mut open: Option<String> = None;
        let mut run = String::new();
        for col in 0..end {
            let Some(cell) = screen.cell(row, col) else { continue };
            if cell.is_wide_continuation() {
                continue;
            }
            let style = cell_style(cell);
            if open.as_ref() != Some(&style) {
                flush(&mut line, &open, &run);
                run.clear();
                open = Some(style);
            }
            let text = cell.contents();
            if text.is_empty() {
                run.push(' ');
            } else {
                for c in text.chars() {
                    match c {
                        '<' => run.push_str("&lt;"),
                        '>' => run.push_str("&gt;"),
                        '&' => run.push_str("&amp;"),
                        c => run.push(c),
                    }
                }
            }
        }
        flush(&mut line, &open, &run);
        lines.push(line);
    }
    while lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines.join("\n")
}

fn flush(line: &mut String, style: &Option<String>, run: &str) {
    if run.is_empty() {
        return;
    }
    match style.as_deref() {
        None | Some("") => line.push_str(run),
        Some(style) => {
            line.push_str(&format!("<span style=\"{style}\">{run}</span>"));
        }
    }
}

fn cell_style(cell: &vt100::Cell) -> String {
    let (mut fg, mut bg) = (color(cell.fgcolor()), color(cell.bgcolor()));
    if cell.inverse() {
        (fg, bg) = (
            Some(bg.unwrap_or_else(|| "var(--bg)".into())),
            Some(fg.unwrap_or_else(|| "var(--fg)".into())),
        );
    }
    let mut style = String::new();
    if let Some(fg) = fg {
        style.push_str(&format!("color:{fg};"));
    }
    if let Some(bg) = bg {
        style.push_str(&format!("background:{bg};"));
    }
    if cell.bold() {
        style.push_str("font-weight:700;");
    }
    if cell.dim() {
        style.push_str("opacity:.6;");
    }
    if cell.italic() {
        style.push_str("font-style:italic;");
    }
    if cell.underline() {
        style.push_str("text-decoration:underline;");
    }
    style
}

/// A terminal colour as CSS: the 16 named ones follow the page's theme, the rest are fixed.
fn color(color: vt100::Color) -> Option<String> {
    match color {
        vt100::Color::Default => None,
        vt100::Color::Idx(index) if index < 16 => Some(format!("var(--c{index})")),
        vt100::Color::Idx(index) if index < 232 => {
            let n = index - 16;
            let level = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
            Some(format!(
                "#{:02x}{:02x}{:02x}",
                level(n / 36),
                level(n / 6 % 6),
                level(n % 6)
            ))
        }
        vt100::Color::Idx(index) => {
            let grey = 8 + (index - 232) * 10;
            Some(format!("#{grey:02x}{grey:02x}{grey:02x}"))
        }
        vt100::Color::Rgb(r, g, b) => Some(format!("#{r:02x}{g:02x}{b:02x}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screens_become_html_with_their_colours() {
        let mut parser = vt100::Parser::new(4, 20, 0);
        parser.process(b"plain <b>\r\n\x1b[31mred\x1b[0m and \x1b[1;38;2;1;2;3mrgb\x1b[0m\r\n\x1b[7minv\x1b[0m");
        let html = screen_html(parser.screen());
        let lines: Vec<&str> = html.lines().collect();
        assert_eq!(lines[0], "plain &lt;b&gt;");
        assert_eq!(
            lines[1],
            "<span style=\"color:var(--c1);\">red</span> and <span style=\"color:#010203;font-weight:700;\">rgb</span>"
        );
        assert_eq!(
            lines[2],
            "<span style=\"color:var(--bg);background:var(--fg);\">inv</span>"
        );
        assert_eq!(lines.len(), 3, "blank rows at the end are left out");
    }

    #[test]
    fn colour_cube_and_greys() {
        assert_eq!(color(vt100::Color::Idx(196)).unwrap(), "#ff0000");
        assert_eq!(color(vt100::Color::Idx(16)).unwrap(), "#000000");
        assert_eq!(color(vt100::Color::Idx(244)).unwrap(), "#808080");
    }

    #[test]
    fn needs_and_reports_become_notifications() {
        let world = json!({ "repos": [{
            "repo": "/src/lanh",
            "agents": [{ "id": 1, "kind": "orchestrator", "name": "auth fix" }],
            "needs": [
                { "kind": "permission_prompt", "message": 7, "agent": 1, "worker": "w3", "profile": "bash",
                  "title": "t", "body": "", "prompt": "Bash command\n rm -rf junk\nDo you want to proceed?", "at": 5 },
                { "kind": "permission_prompt", "message": 0, "agent": 1, "worker": null, "profile": "orchestrator",
                  "title": "auth fix", "body": "", "prompt": "Bash command\n ls\nDo you want to proceed?", "at": 9 },
            ],
            "workers": [
                { "id": "w2", "state": "done", "title": "Write tests", "finalReport": "\nAll 12 pass.\nmore", "settledAt": 100 },
                { "id": "w4", "state": "running", "title": "x", "settledAt": null },
            ],
        }]});
        let alerts = alerts(&world);
        let keys: Vec<&str> = alerts.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(
            keys,
            ["permission_prompt-7", "permission_prompt-agent-1-9", "report-w2-100"]
        );
        assert_eq!(alerts[0].1["title"], "w3 bash wants to run");
        assert_eq!(alerts[0].1["body"], "rm -rf junk\nlanh, auth fix");
        assert_eq!(alerts[1].1["title"], "The Orchestrator wants to run");
        assert_eq!(alerts[2].1["title"], "w2 finished: Write tests");
        assert_eq!(alerts[2].1["body"], "All 12 pass.\nlanh");
        assert_eq!(alerts[2].1["url"], "/#worker=2");
    }

    #[test]
    fn tokens_compare_whole() {
        assert!(same("abc", "abc"));
        assert!(!same("abc", "abd"));
        assert!(!same("abc", "ab"));
    }
}
