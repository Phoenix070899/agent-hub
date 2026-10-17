//! End-to-end tests of the Hub Daemon through the `hub` binary, with a fake agent for `claude`.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

struct Hub {
    state: PathBuf,
    repo: PathBuf,
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

impl Hub {
    /// A fresh daemon state and repo. Short /tmp paths: macOS caps socket paths at 104 bytes.
    fn new(name: &str) -> Hub {
        let state = PathBuf::from(format!("/tmp/hubt-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&state);
        let repo = state.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("README.md"), "# test\n").unwrap();
        git(&repo, &["add", "."]);
        git(
            &repo,
            &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"],
        );
        Hub { state, repo }
    }

    fn run(&self, args: &[&str]) -> Output {
        let bin = Path::new(env!("CARGO_BIN_EXE_hub"));
        let fake = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake-agent.sh");
        Command::new(bin)
            .args(args)
            .current_dir(&self.repo)
            .env("HUB_STATE", &self.state)
            .env("HUB_TEST_AGENT", fake)
            .env(
                "PATH",
                format!("{}:{}", bin.parent().unwrap().display(), std::env::var("PATH").unwrap()),
            )
            .env_remove("HUB_WORKER")
            .output()
            .unwrap()
    }

    fn ok(&self, args: &[&str]) -> String {
        let out = self.run(args);
        assert!(
            out.status.success(),
            "hub {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn fails(&self, args: &[&str]) -> String {
        let out = self.run(args);
        assert!(!out.status.success(), "hub {args:?} should fail");
        String::from_utf8_lossy(&out.stderr).into_owned()
    }

    /// One request on the daemon socket, as the Hub App sends it.
    fn call(&self, method: &str, params: serde_json::Value) -> serde_json::Value {
        let mut stream = UnixStream::connect(self.state.join("hubd.sock")).unwrap();
        let request = serde_json::json!({ "method": method, "params": params });
        stream.write_all(format!("{request}\n").as_bytes()).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }

    fn repo_key(&self) -> String {
        self.repo.canonicalize().unwrap().display().to_string()
    }

    fn wait(&self) -> String {
        self.ok(&["wait", "--timeout", "15"])
    }

    fn status(&self) -> serde_json::Value {
        serde_json::from_str(&self.ok(&["status", "--json"])).unwrap()
    }

    fn eventually(&self, what: &str, check: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(15);
        while !check() {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(200));
        }
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        let _ = self.run(&["shutdown", "--force"]);
        std::thread::sleep(Duration::from_millis(300));
        let _ = std::fs::remove_dir_all(&self.state);
    }
}

#[test]
fn question_reply_and_final_report() {
    let hub = Hub::new("ask");
    assert!(hub
        .ok(&["worker", "start", "bash", "--spec", "ask about color"])
        .starts_with("Started w1"));

    let question = hub.wait();
    assert!(
        question.contains("#1 question from w1 (bash: ask about color)"),
        "{question}"
    );
    assert!(question.contains("Which color?"));
    assert!(question.contains("hub reply 1"));
    assert_eq!(hub.status()[0]["state"], "needs you");
    assert!(hub.ok(&["inbox"]).contains("#1 from w1"));

    hub.ok(&["reply", "1", "blue"]);
    let done = hub.wait();
    assert!(done.contains("done (done) from w1"), "{done}");
    assert!(done.contains("answer was blue"));
    assert!(done.contains("hub worker close w1"));
    assert_eq!(hub.status()[0]["state"], "done");
    assert!(hub.fails(&["reply", "1", "again"]).contains("already answered"));

    hub.ok(&["worker", "close", "w1"]);
    hub.eventually("w1 to close", || {
        hub.ok(&["worker", "list"]).contains("No open Workers.")
    });
    assert_eq!(
        hub.status()[0]["state"],
        "done",
        "settled Workers stay on the Dashboard a while"
    );
}

#[test]
fn an_exit_without_a_final_report_is_reported() {
    let hub = Hub::new("exit");
    hub.ok(&["worker", "start", "bash", "--spec", "exit early"]);
    let exited = hub.wait();
    assert!(exited.contains("exited from w1"), "{exited}");
    assert!(exited.contains("fake agent giving up"));
    assert_eq!(hub.status()[0]["state"], "failed");
}

#[test]
fn new_worktrees_get_a_typed_branch() {
    let hub = Hub::new("wt");
    let started = hub.ok(&[
        "worker",
        "start",
        "bash",
        "--spec",
        "sleep",
        "--worktree",
        "new:feat/thing",
    ]);
    assert!(started.contains("on feat/thing"), "{started}");
    assert!(git(&hub.repo, &["branch", "--list", "feat/thing"]).contains("feat/thing"));
    assert_eq!(hub.status()[0]["place"], "feat-thing");
    assert!(hub.ok(&["worker", "list"]).contains("feat/thing"));
    let refused = hub.fails(&[
        "worker",
        "start",
        "bash",
        "--spec",
        "sleep",
        "--worktree",
        "new:feature/x",
    ]);
    assert!(refused.contains("type one of"), "{refused}");
}

#[test]
fn attach_streams_the_screen_and_types_input() {
    let hub = Hub::new("attach");
    hub.ok(&["worker", "start", "bash", "--spec", "echo back"]);
    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    stream
        .write_all(b"{\"method\":\"attach\",\"params\":{\"id\":1,\"rows\":30,\"cols\":100}}\n")
        .unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.contains("\"ok\":true"), "{line}");
    stream.write_all(b"hello\r").unwrap();

    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut seen = Vec::new();
    let mut buf = [0u8; 4096];
    while !String::from_utf8_lossy(&seen).contains("got: hello") {
        let n = reader.read(&mut buf).expect("attached output");
        assert!(n > 0, "stream ended early: {}", String::from_utf8_lossy(&seen));
        seen.extend_from_slice(&buf[..n]);
    }
    assert!(
        String::from_utf8_lossy(&seen).contains("Working"),
        "the snapshot redraws the screen first"
    );
    assert!(hub.ok(&["worker", "read", "w1", "--lines", "3"]).contains("got: hello"));
}

#[test]
fn a_daemon_crash_marks_workers_lost_and_they_resume() {
    let hub = Hub::new("lost");
    hub.ok(&["worker", "start", "bash", "--spec", "sleep"]);
    let pid = Command::new("lsof")
        .arg("-t")
        .arg(hub.state.join("hubd.sock"))
        .output()
        .unwrap();
    for pid in String::from_utf8_lossy(&pid.stdout).split_whitespace() {
        Command::new("kill").args(["-9", pid]).status().unwrap();
    }
    std::thread::sleep(Duration::from_millis(500));

    let lost = hub.wait();
    assert!(lost.contains("lost from w1"), "{lost}");
    assert!(lost.contains("hub worker resume w1"));
    assert_eq!(hub.status()[0]["state"], "needs you");

    assert!(hub.ok(&["worker", "resume", "w1"]).contains("Resumed w1"));
    hub.eventually("w1 to run again", || hub.status()[0]["state"] == "running");
}

#[test]
fn worker_commands_need_a_worker() {
    let hub = Hub::new("env");
    assert!(hub.fails(&["done", "--state", "done", "x"]).contains("HUB_WORKER"));
    assert!(hub.fails(&["worker", "key", "w1", "hyper"]).contains("unknown key"));
}

#[test]
fn a_forced_shutdown_closes_workers_instead_of_losing_them() {
    let hub = Hub::new("shut");
    hub.ok(&["worker", "start", "bash", "--spec", "sleep"]);
    hub.ok(&["shutdown", "--force"]);
    std::thread::sleep(Duration::from_millis(500));
    assert!(hub.ok(&["worker", "list"]).contains("No open Workers."));
    assert!(hub.ok(&["wait", "--timeout", "1"]).contains("No messages"));
    assert_eq!(hub.status()[0]["state"], "failed");
}

#[test]
fn the_daemon_owns_one_orchestrator_per_repo() {
    let hub = Hub::new("orch");
    hub.ok(&["status"]); // starts the daemon
    let repo = hub.repo_key();
    let first = hub.call("session.open", serde_json::json!({ "repo": repo }));
    assert_eq!(first["result"]["started"], true, "{first}");
    let again = hub.call("session.open", serde_json::json!({ "repo": repo }));
    assert_eq!(again["result"]["started"], false, "{again}");
    let sessions = hub.call("sessions.list", serde_json::json!({}));
    assert_eq!(sessions["result"]["sessions"][0]["repo"], repo);
    assert_eq!(sessions["result"]["sessions"][0]["live"], true);

    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let request =
        serde_json::json!({ "method": "attach", "params": { "orchestrator": repo, "rows": 30, "cols": 100 } });
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut seen = Vec::new();
    let mut buf = [0u8; 4096];
    while !String::from_utf8_lossy(&seen).contains("Working") {
        let n = stream.read(&mut buf).expect("orchestrator output");
        assert!(n > 0);
        seen.extend_from_slice(&buf[..n]);
    }

    hub.call("session.close", serde_json::json!({ "repo": repo }));
    hub.eventually("the Orchestrator to stop", || {
        hub.call("sessions.list", serde_json::json!({}))["result"]["sessions"][0]["live"] == false
    });
}

#[test]
fn events_stream_a_snapshot_on_every_change() {
    let hub = Hub::new("events");
    hub.ok(&["status"]);
    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let request = serde_json::json!({ "method": "events", "params": { "repo": hub.repo_key() } });
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    let mut lines = BufReader::new(stream).lines();
    assert!(lines.next().unwrap().unwrap().contains("\"ok\":true"));
    let first: serde_json::Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    assert_eq!(first["workers"].as_array().unwrap().len(), 0);

    hub.ok(&["worker", "start", "bash", "--spec", "ask about color"]);
    loop {
        let snapshot: serde_json::Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
        if snapshot["needs"].as_array().is_some_and(|needs| !needs.is_empty()) {
            assert_eq!(snapshot["needs"][0]["kind"], "question");
            assert_eq!(snapshot["needs"][0]["body"], "Which color?");
            assert_eq!(snapshot["workers"][0]["state"], "needs you");
            break;
        }
    }
}

#[test]
fn approving_a_prompt_presses_it_and_tells_the_orchestrator() {
    let hub = Hub::new("approve");
    hub.ok(&["worker", "start", "bash", "--spec", "prompt me"]);
    let blocker = hub.wait();
    assert!(blocker.contains("blocker from w1"), "{blocker}");
    let mut events = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let request = serde_json::json!({ "method": "events", "params": { "repo": hub.repo_key() } });
    events.write_all(format!("{request}\n").as_bytes()).unwrap();
    let mut lines = BufReader::new(events).lines();
    lines.next();
    let snapshot: serde_json::Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    assert_eq!(snapshot["needs"][0]["kind"], "permission_prompt");
    assert_eq!(
        snapshot["needs"][0]["prompt"],
        "Bash command\nrm -rf junk\nDo you want to proceed?"
    );
    let decided = hub.call("decide", serde_json::json!({ "worker": 1, "approve": true }));
    assert_eq!(decided["ok"], true, "{decided}");
    hub.eventually("the prompt to be approved", || {
        hub.ok(&["worker", "read", "w1"]).contains("approved")
    });
    let told = hub.wait();
    assert!(told.contains("human from w1"), "{told}");
    assert!(told.contains("The human approved this permission prompt"));
    assert!(told.contains("rm -rf junk"));
    let again = hub.call("decide", serde_json::json!({ "worker": 1, "approve": true }));
    assert_eq!(again["ok"], false, "a cleared prompt cannot be approved twice");
}

#[test]
fn denying_a_prompt_tells_the_worker_why() {
    let hub = Hub::new("deny");
    hub.ok(&["worker", "start", "bash", "--spec", "prompt me"]);
    hub.wait();
    hub.call(
        "decide",
        serde_json::json!({ "worker": 1, "approve": false, "note": "Use trash instead." }),
    );
    hub.eventually("the worker to hear the denial", || {
        let screen = hub.ok(&["worker", "read", "w1"]);
        screen.contains("denied:") && screen.contains("Use trash instead.")
    });
    assert!(hub.wait().contains("The human denied this permission prompt"));
}

#[test]
fn a_human_reply_in_the_app_is_reported() {
    let hub = Hub::new("hreply");
    hub.ok(&["worker", "start", "bash", "--spec", "ask about color"]);
    hub.wait();
    let replied = hub.call(
        "reply",
        serde_json::json!({ "id": 1, "body": "green", "by_human": true }),
    );
    assert_eq!(replied["ok"], true, "{replied}");
    let messages = hub.wait();
    assert!(
        messages.contains("The human answered question #1 from w1 in the Hub App:\ngreen"),
        "{messages}"
    );
    assert!(messages.contains("answer was green"));
}

#[test]
fn simultaneous_starts_leave_one_daemon() {
    let hub = Hub::new("race");
    let starts: Vec<_> = (0..10)
        .map(|_| {
            Command::new(env!("CARGO_BIN_EXE_hub"))
                .arg("daemon")
                .env("HUB_STATE", &hub.state)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap()
        })
        .collect();
    std::thread::sleep(Duration::from_millis(1500));
    let holders = Command::new("lsof")
        .arg("-t")
        .arg(hub.state.join("hub.db"))
        .output()
        .unwrap();
    let alive = String::from_utf8_lossy(&holders.stdout).split_whitespace().count();
    for mut start in starts {
        let _ = start.kill();
        let _ = start.wait();
    }
    assert_eq!(alive, 1, "exactly one daemon holds this state folder");
}
