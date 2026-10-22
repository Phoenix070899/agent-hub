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
        self.run_with(args, &[])
    }

    fn run_with(&self, args: &[&str], env: &[(&str, &str)]) -> Output {
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
            .envs(env.iter().copied())
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

    fn eventually(&self, what: &str, mut check: impl FnMut() -> bool) {
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
fn a_picked_orchestrator_model_is_kept_for_the_session() {
    let hub = Hub::new("model");
    hub.ok(&["status"]);
    let repo = hub.repo_key();
    let opened = hub.call(
        "session.open",
        serde_json::json!({ "repo": repo, "model": "claude-opus-5-5" }),
    );
    assert_eq!(opened["result"]["model"], "claude-opus-5-5", "{opened}");
    let sessions = hub.call("sessions.list", serde_json::json!({}));
    assert_eq!(sessions["result"]["sessions"][0]["model"], "claude-opus-5-5");
    hub.call("session.close", serde_json::json!({ "repo": repo }));
    hub.eventually("the Orchestrator to stop", || {
        hub.call("sessions.list", serde_json::json!({}))["result"]["sessions"][0]["live"] == false
    });
    let reopened = hub.call("session.open", serde_json::json!({ "repo": repo }));
    assert_eq!(
        reopened["result"]["model"], "claude-opus-5-5",
        "a start without a model keeps the saved one"
    );
    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let request = serde_json::json!({ "method": "events", "params": { "repo": repo } });
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    let mut lines = BufReader::new(stream).lines();
    lines.next();
    let snapshot: serde_json::Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    assert_eq!(snapshot["orchestrator"]["model"], "claude-opus-5-5");
}

#[test]
fn worker_rows_carry_model_effort_and_progress() {
    let hub = Hub::new("progress");
    hub.ok(&["status"]);
    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let request = serde_json::json!({ "method": "events", "params": { "repo": hub.repo_key() } });
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    let mut lines = BufReader::new(stream).lines();
    lines.next();
    hub.ok(&["worker", "start", "bash", "--spec", "status then wait"]);
    loop {
        let snapshot: serde_json::Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
        let Some(row) = snapshot["workers"].as_array().and_then(|rows| rows.first()) else {
            continue;
        };
        assert_eq!(row["model"], "claude-haiku-5-5");
        assert_eq!(row["effort"], "low");
        assert_eq!(snapshot["orchestrator"]["model"], serde_json::Value::Null);
        if row["progress"] == "41 of 44 tests passing" {
            break;
        }
    }
}

/// The repo's first snapshot from the events stream.
fn snapshot(hub: &Hub) -> serde_json::Value {
    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let request = serde_json::json!({ "method": "events", "params": { "repo": hub.repo_key() } });
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    let mut lines = BufReader::new(stream).lines();
    lines.next();
    serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap()
}

#[test]
fn a_final_report_stays_in_echo_until_dismissed() {
    let hub = Hub::new("dismiss");
    hub.ok(&["worker", "start", "bash", "--spec", "done quickly"]);
    hub.eventually("w1 to finish", || snapshot(&hub)["workers"][0]["phase"] == "done");
    let row = snapshot(&hub)["workers"][0].clone();
    assert!(row["settledAt"].is_i64(), "{row}");
    // The Orchestrator tidying up does not take the report off Echo's Done list.
    hub.ok(&["worker", "close", "w1"]);
    assert_eq!(snapshot(&hub)["workers"][0]["id"], "w1");
    hub.call("worker.dismiss", serde_json::json!({ "id": 1 }));
    assert_eq!(snapshot(&hub)["workers"], serde_json::json!([]));
}

#[test]
fn a_repo_runs_several_orchestrators_and_each_hears_only_its_workers() {
    let hub = Hub::new("agents");
    hub.ok(&["status"]);
    let repo = hub.repo_key();
    let a = hub.call(
        "agent.open",
        serde_json::json!({ "repo": repo, "kind": "orchestrator", "name": "Rerank" }),
    );
    let b = hub.call(
        "agent.open",
        serde_json::json!({ "repo": repo, "kind": "orchestrator" }),
    );
    let (a, b) = (
        a["result"]["agent"].as_i64().unwrap(),
        b["result"]["agent"].as_i64().unwrap(),
    );
    assert_ne!(a, b);
    let sessions = hub.call("sessions.list", serde_json::json!({}));
    let agents = sessions["result"]["sessions"][0]["agents"].as_array().unwrap().clone();
    assert_eq!(agents.len(), 2);
    assert_eq!(agents[0]["name"], "Rerank");
    assert!(agents.iter().all(|agent| agent["live"] == true));

    // `hub worker start` in b's terminal carries HUB_AGENT=b.
    let started = hub.run_with(
        &["worker", "start", "bash", "--spec", "done quickly"],
        &[("HUB_AGENT", &b.to_string())],
    );
    assert!(started.status.success(), "{}", String::from_utf8_lossy(&started.stderr));
    hub.eventually("w1 to finish", || snapshot(&hub)["workers"][0]["phase"] == "done");
    assert_eq!(snapshot(&hub)["workers"][0]["agent"], b);
    let listed = |agent: i64| {
        let out = hub.run_with(&["worker", "list", "--json"], &[("HUB_AGENT", &agent.to_string())]);
        serde_json::from_slice::<serde_json::Value>(&out.stdout).unwrap()["workers"]
            .as_array()
            .unwrap()
            .len()
    };
    assert_eq!(
        (listed(a), listed(b)),
        (0, 1),
        "each Orchestrator lists only its own Workers"
    );
    let for_a = hub.call(
        "wait",
        serde_json::json!({ "repo": repo, "agent": a, "timeout_ms": 500 }),
    );
    assert_eq!(for_a["result"]["messages"].as_array().map(Vec::len), Some(0), "{for_a}");
    let for_b = hub.call(
        "wait",
        serde_json::json!({ "repo": repo, "agent": b, "timeout_ms": 5000 }),
    );
    assert_eq!(for_b["result"]["messages"][0]["kind"], "done", "{for_b}");

    hub.call("agent.forget", serde_json::json!({ "agent": a }));
    let sessions = hub.call("sessions.list", serde_json::json!({}));
    assert_eq!(sessions["result"]["sessions"][0]["agents"].as_array().unwrap().len(), 1);
}

#[test]
fn a_normal_session_puts_its_permission_prompt_under_needs_you() {
    let hub = Hub::new("normal");
    hub.ok(&["status"]);
    let repo = hub.repo_key();
    // The fake agent runs the script its Normal session is named after.
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": repo, "kind": "claude", "name": "prompt me" }),
    );
    let agent = opened["result"]["agent"].as_i64().unwrap();
    assert_eq!(opened["result"]["kind"], "claude");
    hub.eventually("the prompt to reach Needs you", || {
        snapshot(&hub)["needs"]
            .as_array()
            .is_some_and(|needs| !needs.is_empty())
    });
    let need = snapshot(&hub)["needs"][0].clone();
    assert_eq!(need["agent"], agent);
    assert_eq!(need["worker"], serde_json::Value::Null);
    assert_eq!(need["prompt"], "Bash command\nrm -rf junk\nDo you want to proceed?");
    let decided = hub.call("decide", serde_json::json!({ "agent": agent, "approve": true }));
    assert_eq!(decided["ok"], true, "{decided}");
    hub.eventually("the prompt to clear", || {
        snapshot(&hub)["needs"].as_array().is_some_and(|needs| needs.is_empty())
    });
}

#[test]
fn an_orchestrator_puts_its_own_permission_prompt_under_needs_you() {
    let hub = Hub::new("orchprompt");
    hub.ok(&["status"]);
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": hub.repo_key(), "kind": "orchestrator", "request": "prompt me" }),
    );
    let agent = opened["result"]["agent"].as_i64().unwrap();
    hub.eventually("the prompt to reach Needs you", || {
        snapshot(&hub)["needs"]
            .as_array()
            .is_some_and(|needs| !needs.is_empty())
    });
    let need = snapshot(&hub)["needs"][0].clone();
    assert_eq!(need["agent"], agent);
    assert_eq!(need["worker"], serde_json::Value::Null);
    assert_eq!(need["profile"], "orchestrator");
    assert_eq!(need["title"], "Orchestrator");
    assert_eq!(need["prompt"], "Bash command\nrm -rf junk\nDo you want to proceed?");
    let decided = hub.call("decide", serde_json::json!({ "agent": agent, "approve": true }));
    assert_eq!(decided["ok"], true, "{decided}");
    hub.eventually("the prompt to clear", || {
        snapshot(&hub)["needs"].as_array().is_some_and(|needs| needs.is_empty())
    });
}

#[test]
fn an_unnamed_agent_is_named_after_the_first_request() {
    let hub = Hub::new("naming");
    hub.ok(&["status"]);
    let repo = hub.repo_key();
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": repo, "kind": "orchestrator" }),
    );
    let agent = opened["result"]["agent"].as_i64().unwrap();
    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let request = serde_json::json!({ "method": "attach", "params": { "agent": agent, "rows": 30, "cols": 100 } });
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    stream.write_all(b"/model opus\r").unwrap();
    stream.write_all(b"fix the flaky bench, then rerun it\r").unwrap();
    let name =
        || hub.call("sessions.list", serde_json::json!({}))["result"]["sessions"][0]["agents"][0]["name"].clone();
    hub.eventually("the agent to be named", || name() != serde_json::Value::Null);
    assert_eq!(name(), "Fix the flaky bench, then rerun");
    stream.write_all(b"something else entirely\r").unwrap();
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(
        name(),
        "Fix the flaky bench, then rerun",
        "only the first request names it"
    );
    hub.call("agent.rename", serde_json::json!({ "agent": agent, "name": "Bench" }));
    assert_eq!(name(), "Bench");
}

#[test]
fn a_new_agent_starts_on_the_request_it_was_opened_with() {
    let hub = Hub::new("request");
    hub.ok(&["status"]);
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": hub.repo_key(), "kind": "claude", "name": "request",
                            "request": "Fix issue #12: the bench is flaky" }),
    );
    let agent = opened["result"]["agent"].as_i64().unwrap();
    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let attach = serde_json::json!({ "method": "attach", "params": { "agent": agent, "rows": 30, "cols": 100 } });
    stream.write_all(format!("{attach}\n").as_bytes()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    read_until(
        &mut stream,
        &mut Vec::new(),
        "first request: Fix issue #12: the bench is flaky",
    );
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
fn a_worker_diff_shows_its_branch_and_a_review_reaches_it() {
    let hub = Hub::new("review");
    hub.ok(&[
        "worker",
        "start",
        "bash",
        "--spec",
        "echo",
        "--worktree",
        "new:feat/review",
    ]);
    let listed = hub.call("worker.list", serde_json::json!({ "repo": hub.repo_key() }));
    let cwd = PathBuf::from(
        listed["result"]["workers"][0]["cwd"]
            .as_str()
            .unwrap_or_else(|| panic!("{listed}")),
    );
    let commit = ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam"];
    // The Worker commits one change and leaves a new file uncommitted.
    std::fs::write(cwd.join("README.md"), "# test\nworker line\n").unwrap();
    git(&cwd, &[&commit[..], &["worker change"]].concat());
    std::fs::write(cwd.join("notes.txt"), "new file\n").unwrap();
    // Main moves on meanwhile; that is not the Worker's change.
    std::fs::write(hub.repo.join("MAIN.md"), "main only\n").unwrap();
    git(&hub.repo, &["add", "."]);
    git(&hub.repo, &[&commit[..], &["main change"]].concat());

    let diff = hub.call("worker.diff", serde_json::json!({ "id": 1 }));
    let text = diff["result"]["diff"].as_str().unwrap_or_else(|| panic!("{diff}"));
    assert!(text.contains("+worker line"), "{text}");
    assert!(text.contains("+++ b/notes.txt") && text.contains("+new file"), "{text}");
    assert!(!text.contains("MAIN.md"), "{text}");
    assert_eq!(diff["result"]["truncated"], false);

    let sent = hub.call(
        "worker.review",
        serde_json::json!({ "id": 1, "to": "worker", "body": "README.md:2 say why" }),
    );
    assert_eq!(sent["ok"], true, "{sent}");
    hub.eventually("the review to be typed into the Worker", || {
        hub.ok(&["worker", "read", "w1"]).contains("got: README.md:2 say why")
    });
    hub.call(
        "worker.review",
        serde_json::json!({ "id": 1, "to": "orchestrator", "body": "notes.txt:1 drop this file" }),
    );
    let messages = hub.wait();
    assert!(
        messages.contains("The human sent w1 a review of its changes in Echo:\nREADME.md:2 say why"),
        "{messages}"
    );
    assert!(
        messages
            .contains("The human reviewed w1's changes in Echo and wants them addressed:\nnotes.txt:1 drop this file"),
        "{messages}"
    );
}

#[test]
fn a_fan_out_runs_one_task_three_ways_and_the_pick_is_merged() {
    let hub = Hub::new("fanout");
    hub.ok(&["status"]);
    let profiles = hub.call("profiles.list", serde_json::json!({}));
    let naruto = profiles["result"]["profiles"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["name"] == "naruto")
        .cloned();
    assert_eq!(
        naruto.map(|p| p["writes"].clone()),
        Some(serde_json::json!(true)),
        "{profiles}"
    );
    let fanned = hub.call(
        "worker.fanout",
        serde_json::json!({ "repo": hub.repo_key(), "profile": "bash", "spec": "done", "title": "Try it",
                            "branch": "feat/try", "count": 3 }),
    );
    assert_eq!(
        fanned["result"]["workers"],
        serde_json::json!(["w1", "w2", "w3"]),
        "{fanned}"
    );
    let workers =
        || hub.call("worker.list", serde_json::json!({ "repo": hub.repo_key() }))["result"]["workers"].clone();
    hub.eventually("every try to finish", || {
        workers().as_array().unwrap().iter().all(|w| w["state"] == "done")
    });
    let tries = workers();
    let by_branch = |branch: &str| {
        let row = tries
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["branch"] == branch)
            .unwrap();
        (
            row["id"].as_str().unwrap().to_string(),
            PathBuf::from(row["cwd"].as_str().unwrap()),
        )
    };
    let (winner_id, winner) = by_branch("feat/try-2");
    let (_, loser) = by_branch("feat/try-1");
    std::fs::write(winner.join("picked.txt"), "picked\n").unwrap();
    hub.wait();

    let number: i64 = winner_id[1..].parse().unwrap();
    let picked = hub.call("worker.pick", serde_json::json!({ "id": number }));
    assert_eq!(picked["result"]["into"], "main", "{picked}");
    assert_eq!(picked["result"]["closed"].as_array().unwrap().len(), 2, "{picked}");
    assert_eq!(
        std::fs::read_to_string(hub.repo.join("picked.txt")).unwrap(),
        "picked\n"
    );
    assert!(!loser.exists(), "the losing worktree is removed");
    let ids: Vec<String> = snapshot(&hub)["workers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids, vec![winner_id.clone()], "only the kept try stays in Echo");
    assert!(
        git(&hub.repo, &["branch", "--list", "feat/try-1"]).contains("feat/try-1"),
        "its branch stays"
    );
    let messages = hub.wait();
    assert!(
        messages.contains(&format!(
            "The human picked {winner_id} of a fan-out in Echo and merged feat/try-2 into main."
        )),
        "{messages}"
    );
}

#[test]
fn an_orchestrator_in_its_own_worktree_keeps_its_workers_there() {
    let hub = Hub::new("place");
    hub.ok(&["status"]);
    let commit = ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam"];
    git(&hub.repo, &["branch", "fix/old"]);
    let open = |params: serde_json::Value| {
        let opened = hub.call("agent.open", params);
        assert_eq!(opened["ok"], true, "{opened}");
        opened["result"]["agent"].as_i64().unwrap()
    };
    let login = open(
        serde_json::json!({ "repo": hub.repo_key(), "kind": "orchestrator", "new_branch": "feat/login", "base": "main" }),
    );
    let old =
        open(serde_json::json!({ "repo": hub.repo_key(), "kind": "claude", "name": "sleeper", "branch": "fix/old" }));
    let here =
        open(serde_json::json!({ "repo": hub.repo_key(), "kind": "claude", "name": "sleeper", "branch": "main" }));
    let agents = hub.call("sessions.list", serde_json::json!({}))["result"]["sessions"][0]["agents"].clone();
    let agent = |id: i64| {
        agents
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["id"] == id)
            .unwrap()
            .clone()
    };
    let home = PathBuf::from(agent(login)["cwd"].as_str().unwrap());
    assert!(home.ends_with("feat-login"), "{}", home.display());
    assert_eq!(agent(login)["branch"], "feat/login");
    assert!(agent(old)["cwd"].as_str().unwrap().ends_with("fix-old"));
    assert_eq!(
        agent(here)["cwd"],
        serde_json::Value::Null,
        "main is the repo's own checkout"
    );

    // The Orchestrator commits on its branch; its Workers start from there, not from main.
    std::fs::write(home.join("README.md"), "# login\n").unwrap();
    git(&home, &[&commit[..], &["login work"]].concat());
    let start = |worktree: &str| {
        let started = hub.call(
            "worker.start",
            serde_json::json!({ "repo": hub.repo_key(), "profile": "bash", "spec": "sleep", "agent": login, "worktree": worktree }),
        );
        PathBuf::from(started["result"]["cwd"].as_str().unwrap_or_else(|| panic!("{started}")))
    };
    assert_eq!(start("current"), home, "in place means the Orchestrator's worktree");
    let branched = start("new:feat/form");
    assert_eq!(
        std::fs::read_to_string(branched.join("README.md")).unwrap(),
        "# login\n"
    );

    let branches = hub.call("branches.list", serde_json::json!({ "repo": hub.repo_key() }))["result"].clone();
    assert_eq!(branches["current"], "main");
    let row = branches["branches"]
        .as_array()
        .unwrap()
        .iter()
        .find(|b| b["name"] == "feat/login")
        .unwrap()
        .clone();
    assert_eq!(row["agent"], login, "{branches}");
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

#[test]
fn account_usage_comes_from_claude_usage() {
    let hub = Hub::new("usage");
    hub.ok(&["status"]);
    hub.call("usage.refresh", serde_json::json!({}));
    hub.eventually("usage to load", || {
        hub.call("usage", serde_json::json!({}))["result"]["limits"]
            .as_array()
            .is_some_and(|limits| limits.len() == 3)
    });
    let usage = hub.call("usage", serde_json::json!({}));
    assert_eq!(usage["result"]["limits"][0]["name"], "Session");
    assert_eq!(usage["result"]["limits"][0]["percent"], 48);
    assert_eq!(usage["result"]["limits"][0]["resets"], "Oct 17 at 4:50pm");
    assert_eq!(usage["result"]["limits"][2]["name"], "Week (Fable)");
}

#[test]
fn a_usage_read_that_prints_no_limits_is_retried() {
    let hub = Hub::new("flaky");
    let marker = hub.state.join("usage-failed-once");
    let out = hub.run_with(&["status"], &[("HUB_FAKE_USAGE_FLAKY", marker.to_str().unwrap())]);
    assert!(out.status.success());
    hub.call("usage.refresh", serde_json::json!({}));
    hub.eventually("usage to load after a retry", || {
        hub.call("usage", serde_json::json!({}))["result"]["limits"]
            .as_array()
            .is_some_and(|limits| limits.len() == 3)
    });
    assert!(marker.exists(), "the first read failed");
    assert!(hub.call("usage", serde_json::json!({}))["result"]["error"].is_null());
}

#[test]
fn what_echo_types_reaches_the_agent_as_given() {
    let hub = Hub::new("write");
    hub.ok(&["status"]);
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": hub.repo_key(), "kind": "claude", "name": "echo me" }),
    );
    let agent = serde_json::json!({ "agent": opened["result"]["agent"] });
    hub.eventually("the agent to start", || screen_of(&hub, &agent).contains("Working"));
    let mut write = agent.clone();
    write["text"] = serde_json::json!("typed by echo\r");
    let wrote = hub.call("terminal.write", write);
    assert_eq!(wrote["ok"], true, "{wrote}");
    hub.eventually("the typed line", || {
        screen_of(&hub, &agent).contains("got: typed by echo")
    });
    let ping = hub.call("ping", serde_json::json!({}));
    assert!(
        ping["result"]["exe"].as_str().is_some_and(|exe| exe.ends_with("hub")),
        "{ping}"
    );
}

/// Reads an attached stream until `want` shows up.
fn read_until(reader: &mut impl Read, seen: &mut Vec<u8>, want: &str) {
    let mut buf = [0u8; 4096];
    while !String::from_utf8_lossy(seen).contains(want) {
        let n = reader
            .read(&mut buf)
            .unwrap_or_else(|e| panic!("waiting for {want:?}: {e}\n{}", String::from_utf8_lossy(seen)));
        assert!(n > 0, "stream ended before {want:?}: {}", String::from_utf8_lossy(seen));
        seen.extend_from_slice(&buf[..n]);
    }
}

#[test]
fn hub_opens_the_orchestrator_working_in_this_checkout() {
    let hub = Hub::new("which");
    hub.ok(&["status"]);
    let open = |params: serde_json::Value| {
        let opened = hub.call("agent.open", params);
        assert_eq!(opened["ok"], true, "{opened}");
        opened["result"]["agent"].as_i64().unwrap()
    };
    let first = open(serde_json::json!({ "repo": hub.repo_key(), "kind": "orchestrator" }));
    let login = open(
        serde_json::json!({ "repo": hub.repo_key(), "kind": "orchestrator", "new_branch": "feat/login", "base": "main" }),
    );
    let agents = hub.call("sessions.list", serde_json::json!({}))["result"]["sessions"][0]["agents"].clone();
    let home = agents.as_array().unwrap().iter().find(|a| a["id"] == login).unwrap()["cwd"]
        .as_str()
        .unwrap()
        .to_string();
    let session = |extra: serde_json::Value| {
        let mut params = serde_json::json!({ "repo": hub.repo_key() });
        params
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        let opened = hub.call("session.open", params);
        assert_eq!(opened["ok"], true, "{opened}");
        opened["result"]["agent"].as_i64().unwrap()
    };
    assert_eq!(session(serde_json::json!({ "checkout": home })), login, "its worktree");
    assert_eq!(
        session(serde_json::json!({ "checkout": hub.repo_key() })),
        first,
        "the repo's own checkout"
    );
    assert_eq!(session(serde_json::json!({})), first, "an older client");
}

#[test]
fn an_attached_terminal_passes_its_resize_on() {
    use portable_pty::{native_pty_system, CommandBuilder, PtySize};
    let hub = Hub::new("winch");
    hub.ok(&["status"]);
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": hub.repo_key(), "kind": "claude", "name": "size me" }),
    );
    let id = opened["result"]["agent"].as_i64().unwrap();
    let agent = serde_json::json!({ "agent": id });
    let mut enter = agent.clone();
    enter["text"] = serde_json::json!("\r");

    // `hub attach --echo`, as an Echo pane runs it, in a terminal that grows after it attaches.
    let size = |rows, cols| PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    };
    let pair = native_pty_system().openpty(size(16, 47)).unwrap();
    let mut command = CommandBuilder::new(env!("CARGO_BIN_EXE_hub"));
    command.args(["attach", "--echo", &format!("a{id}")]);
    command.env("HUB_STATE", &hub.state);
    let mut child = pair.slave.spawn_command(command).unwrap();
    let mut output = pair.master.try_clone_reader().unwrap();
    std::thread::spawn(move || std::io::copy(&mut output, &mut std::io::sink()));
    hub.eventually("the pane to attach at its size", || {
        hub.call("terminal.write", enter.clone());
        screen_of(&hub, &agent).contains("size: 16 47")
    });
    pair.master.resize(size(61, 144)).unwrap();
    hub.eventually("the resize to reach the agent", || {
        hub.call("terminal.write", enter.clone());
        screen_of(&hub, &agent).contains("size: 61 144")
    });
    child.kill().unwrap();
}

/// What a terminal shows now: its redrawn screen, read without resizing it.
fn screen_of(hub: &Hub, target: &serde_json::Value) -> String {
    let mut stream = UnixStream::connect(hub.state.join("hubd.sock")).unwrap();
    let request = serde_json::json!({ "method": "attach", "params": target });
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    stream.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
    let mut seen = Vec::new();
    let mut buf = [0u8; 4096];
    while let Ok(n) = stream.read(&mut buf) {
        if n == 0 {
            break;
        }
        seen.extend_from_slice(&buf[..n]);
    }
    String::from_utf8_lossy(&seen).into_owned()
}

/// `hub mux` in a terminal of its own, as an Echo pane runs it: what it prints, and keys to type.
struct MuxPane {
    output: std::sync::Arc<std::sync::Mutex<Vec<u8>>>,
    keys: Box<dyn Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

impl MuxPane {
    fn start(hub: &Hub, line: &str) -> MuxPane {
        use portable_pty::{native_pty_system, CommandBuilder, PtySize};
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 30,
                cols: 100,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut command = CommandBuilder::new(env!("CARGO_BIN_EXE_hub"));
        command.arg("mux");
        command.env("HUB_STATE", &hub.state);
        command.env("HUB_SHELL", "/bin/sh");
        command.env("HUB_MUX", line);
        let child = pair.slave.spawn_command(command).unwrap();
        let output = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = std::sync::Arc::clone(&output);
        let mut reader = pair.master.try_clone_reader().unwrap();
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                sink.lock().unwrap().extend_from_slice(&buf[..n]);
            }
        });
        let keys = pair.master.take_writer().unwrap();
        MuxPane { output, keys, child }
    }

    fn wait_for(&self, want: &str) {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let seen = String::from_utf8_lossy(&self.output.lock().unwrap()).into_owned();
            if seen.contains(want) {
                return;
            }
            assert!(Instant::now() < deadline, "no {want:?} in {seen}");
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    fn clear(&self) {
        self.output.lock().unwrap().clear();
    }

    fn type_keys(&mut self, keys: &[u8]) {
        self.keys.write_all(keys).unwrap();
        self.keys.flush().unwrap();
    }
}

#[test]
fn a_multiplexer_line_names_its_session_and_dir() {
    let hub = Hub::new("muxline");
    hub.ok(&["status"]);
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": hub.repo_key(), "kind": "claude", "name": "sleeper" }),
    );
    let agent = opened["result"]["agent"].as_i64().unwrap();
    let mux = hub.call(
        "mux.command",
        serde_json::json!({ "agent": agent, "command": "tmux new-session -A -s {session} -c {dir} {command}" }),
    );
    assert_eq!(mux["result"]["session"], format!("echo-repo-a{agent}"), "{mux}");
    let line = mux["result"]["command"].as_str().unwrap();
    assert!(
        line.starts_with(&format!("tmux new-session -A -s echo-repo-a{agent} -c ")),
        "{line}"
    );
    assert!(line.contains(&format!("attach --follow a{agent}")), "{line}");
}

#[test]
fn a_multiplexer_shows_an_agent_and_follows_it_through_restarts() {
    let hub = Hub::new("mux");
    let repo = hub.repo_key();
    hub.ok(&["status"]);
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": repo, "kind": "claude", "name": "echo me" }),
    );
    let agent = opened["result"]["agent"].as_i64().unwrap();
    // A stand-in for `tmux new-session -A -s {session} -c {dir} {command}`.
    let command = "printf 'mux %s in %s\\n' {session} {dir}; sh -c {command}";
    let mux = hub.call("mux.command", serde_json::json!({ "agent": agent, "command": command }));
    let mut pane = MuxPane::start(&hub, mux["result"]["command"].as_str().unwrap());
    pane.wait_for(&format!("mux echo-repo-a{agent} in {repo}"));
    pane.wait_for("Working");
    pane.type_keys(b"hello\r");
    pane.wait_for("got: hello");

    hub.call("agent.close", serde_json::json!({ "agent": agent }));
    pane.wait_for("picks it up again when it starts");
    hub.call("agent.open", serde_json::json!({ "agent": agent }));
    pane.clear();
    pane.wait_for("Working");
    pane.type_keys(b"again\r");
    pane.wait_for("got: again");

    hub.call("agent.forget", serde_json::json!({ "agent": agent }));
    pane.wait_for(&format!("a{agent} is closed"));
    hub.eventually("the multiplexer to exit", || pane.child.try_wait().unwrap().is_some());
}

#[test]
fn tmux_runs_the_agent_in_its_first_pane() {
    if Command::new("tmux").arg("-V").output().is_err() {
        eprintln!("tmux is not installed; skipping");
        return;
    }
    let hub = Hub::new("tmux");
    hub.ok(&["status"]);
    let socket = format!("hubt{}", std::process::id());
    let opened = hub.call(
        "agent.open",
        serde_json::json!({ "repo": hub.repo_key(), "kind": "claude", "name": "echo me" }),
    );
    let agent = opened["result"]["agent"].as_i64().unwrap();
    // Echo's default, on a private tmux server.
    let command = format!("tmux -L {socket} new-session -A -s {{session}} -c {{dir}} {{command}}");
    let mux = hub.call("mux.command", serde_json::json!({ "agent": agent, "command": command }));
    let mut pane = MuxPane::start(&hub, mux["result"]["command"].as_str().unwrap());
    pane.wait_for("Working");
    pane.type_keys(b"hello\r");
    pane.wait_for("got: hello");
    let panes = Command::new("tmux")
        .args([
            "-L",
            &socket,
            "list-panes",
            "-t",
            &format!("echo-repo-a{agent}"),
            "-F",
            "#{pane_current_command}",
        ])
        .output()
        .unwrap();
    let _ = Command::new("tmux").args(["-L", &socket, "kill-server"]).output();
    let _ = pane.child.kill();
    assert!(panes.status.success(), "{}", String::from_utf8_lossy(&panes.stderr));
}
