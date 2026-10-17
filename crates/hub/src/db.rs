//! The Hub Daemon's SQLite store: Workers (one per Task) and their messages.

use std::path::Path;

use anyhow::{bail, Result};
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::Serialize;

/// A Worker's lifecycle. `starting` and `running` have a live terminal; the rest are settled.
pub mod state {
    pub const STARTING: &str = "starting";
    pub const RUNNING: &str = "running";
    /// Final Report says done.
    pub const DONE: &str = "done";
    /// Final Report says blocked.
    pub const BLOCKED: &str = "blocked";
    /// The agent exited without a Final Report.
    pub const EXITED: &str = "exited";
    /// The daemon restarted while the Worker was live; resume it with `hub worker resume`.
    pub const LOST: &str = "lost";

    pub fn is_live(state: &str) -> bool {
        state == STARTING || state == RUNNING
    }
}

/// What a message is. Workers send question, escalation, status, done; the daemon sends the rest.
pub mod kind {
    pub const QUESTION: &str = "question";
    pub const ESCALATION: &str = "escalation";
    pub const STATUS: &str = "status";
    pub const DONE: &str = "done";
    pub const BLOCKER: &str = "blocker";
    pub const EXITED: &str = "exited";
    pub const LOST: &str = "lost";
    /// The human acted directly in the Hub App; the daemon tells the Orchestrator.
    pub const HUMAN: &str = "human";
}

#[derive(Debug, Clone, Serialize)]
pub struct Worker {
    pub id: i64,
    pub repo: String,
    pub profile: String,
    pub title: String,
    pub cwd: String,
    pub branch: Option<String>,
    pub session_id: String,
    pub state: String,
    pub final_report: Option<String>,
    pub created_at: i64,
    pub settled_at: Option<i64>,
    pub closed_at: Option<i64>,
    pub last_message_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Message {
    pub id: i64,
    pub repo: String,
    pub worker_id: i64,
    pub kind: String,
    pub body: String,
    pub created_at: i64,
    pub delivered_at: Option<i64>,
    pub answer: Option<String>,
    pub answered_at: Option<i64>,
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn open(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "pragma journal_mode = wal;
         create table if not exists workers (
           id integer primary key,
           repo text not null,
           profile text not null,
           title text not null,
           spec text not null,
           cwd text not null,
           branch text,
           session_id text not null,
           state text not null,
           final_report text,
           created_at integer not null,
           settled_at integer,
           closed_at integer,
           last_message_at integer
         );
         create table if not exists messages (
           id integer primary key,
           repo text not null,
           worker_id integer not null references workers(id),
           kind text not null,
           body text not null,
           created_at integer not null,
           delivered_at integer,
           answer text,
           answered_at integer
         );
         create index if not exists messages_undelivered on messages(repo, delivered_at);
         create table if not exists sessions (
           id integer primary key,
           repo text not null unique,
           session_id text not null,
           created_at integer not null
         );",
    )?;
    Ok(conn)
}

const WORKER_COLUMNS: &str = "id, repo, profile, title, cwd, branch, session_id, state, final_report, \
                              created_at, settled_at, closed_at, last_message_at";

fn worker_row(row: &Row) -> rusqlite::Result<Worker> {
    Ok(Worker {
        id: row.get(0)?,
        repo: row.get(1)?,
        profile: row.get(2)?,
        title: row.get(3)?,
        cwd: row.get(4)?,
        branch: row.get(5)?,
        session_id: row.get(6)?,
        state: row.get(7)?,
        final_report: row.get(8)?,
        created_at: row.get(9)?,
        settled_at: row.get(10)?,
        closed_at: row.get(11)?,
        last_message_at: row.get(12)?,
    })
}

const MESSAGE_COLUMNS: &str = "id, repo, worker_id, kind, body, created_at, delivered_at, answer, answered_at";

fn message_row(row: &Row) -> rusqlite::Result<Message> {
    Ok(Message {
        id: row.get(0)?,
        repo: row.get(1)?,
        worker_id: row.get(2)?,
        kind: row.get(3)?,
        body: row.get(4)?,
        created_at: row.get(5)?,
        delivered_at: row.get(6)?,
        answer: row.get(7)?,
        answered_at: row.get(8)?,
    })
}

pub struct NewWorker<'a> {
    pub repo: &'a str,
    pub profile: &'a str,
    pub title: &'a str,
    pub spec: &'a str,
    pub cwd: &'a str,
    pub branch: Option<&'a str>,
    pub session_id: &'a str,
}

pub fn insert_worker(conn: &Connection, w: &NewWorker) -> Result<i64> {
    conn.execute(
        "insert into workers (repo, profile, title, spec, cwd, branch, session_id, state, created_at)
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            w.repo,
            w.profile,
            w.title,
            w.spec,
            w.cwd,
            w.branch,
            w.session_id,
            state::STARTING,
            now()
        ],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn worker(conn: &Connection, id: i64) -> Result<Worker> {
    let found = conn
        .query_row(
            &format!("select {WORKER_COLUMNS} from workers where id = ?1"),
            [id],
            worker_row,
        )
        .optional()?;
    match found {
        Some(worker) => Ok(worker),
        None => bail!("no Worker w{id}"),
    }
}

pub fn workers(conn: &Connection, repo: &str) -> Result<Vec<Worker>> {
    let mut stmt = conn.prepare(&format!(
        "select {WORKER_COLUMNS} from workers where repo = ?1 order by id"
    ))?;
    let rows = stmt
        .query_map([repo], worker_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn set_state(conn: &Connection, id: i64, new_state: &str) -> Result<()> {
    let settled = if state::is_live(new_state) { None } else { Some(now()) };
    conn.execute(
        "update workers set state = ?2, settled_at = coalesce(?3, settled_at) where id = ?1",
        params![id, new_state, settled],
    )?;
    if state::is_live(new_state) {
        conn.execute(
            "update workers set settled_at = null, closed_at = null where id = ?1",
            [id],
        )?;
    }
    Ok(())
}

pub fn settle(conn: &Connection, id: i64, final_state: &str, report: &str) -> Result<()> {
    conn.execute(
        "update workers set state = ?2, final_report = ?3, settled_at = ?4 where id = ?1",
        params![id, final_state, report, now()],
    )?;
    Ok(())
}

pub fn mark_closed(conn: &Connection, id: i64) -> Result<()> {
    conn.execute("update workers set closed_at = ?2 where id = ?1", params![id, now()])?;
    Ok(())
}

/// Live Workers from before a daemon restart have no terminal any more.
pub fn mark_lost(conn: &Connection) -> Result<Vec<Worker>> {
    let mut stmt = conn.prepare(&format!(
        "select {WORKER_COLUMNS} from workers where state in (?1, ?2) and closed_at is null"
    ))?;
    let lost = stmt
        .query_map([state::STARTING, state::RUNNING], worker_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for worker in &lost {
        set_state(conn, worker.id, state::LOST)?;
    }
    Ok(lost)
}

pub fn insert_message(conn: &Connection, worker: &Worker, kind: &str, body: &str) -> Result<i64> {
    let at = now();
    conn.execute(
        "insert into messages (repo, worker_id, kind, body, created_at) values (?1, ?2, ?3, ?4, ?5)",
        params![worker.repo, worker.id, kind, body, at],
    )?;
    let id = conn.last_insert_rowid();
    conn.execute(
        "update workers set last_message_at = ?2 where id = ?1",
        params![worker.id, at],
    )?;
    Ok(id)
}

pub fn message(conn: &Connection, id: i64) -> Result<Message> {
    let found = conn
        .query_row(
            &format!("select {MESSAGE_COLUMNS} from messages where id = ?1"),
            [id],
            message_row,
        )
        .optional()?;
    match found {
        Some(message) => Ok(message),
        None => bail!("no message #{id}"),
    }
}

/// Every message for the repo not yet handed to the Orchestrator, now marked delivered.
pub fn take_undelivered(conn: &Connection, repo: &str) -> Result<Vec<Message>> {
    let mut stmt = conn.prepare(&format!(
        "select {MESSAGE_COLUMNS} from messages where repo = ?1 and delivered_at is null order by id"
    ))?;
    let messages = stmt
        .query_map([repo], message_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if let Some(last) = messages.last() {
        conn.execute(
            "update messages set delivered_at = ?3 where repo = ?1 and delivered_at is null and id <= ?2",
            params![repo, last.id, now()],
        )?;
    }
    Ok(messages)
}

pub fn open_questions(conn: &Connection, worker_id: i64) -> Result<Vec<Message>> {
    let mut stmt = conn.prepare(&format!(
        "select {MESSAGE_COLUMNS} from messages where worker_id = ?1 and kind = ?2 and answered_at is null order by id"
    ))?;
    let rows = stmt
        .query_map(params![worker_id, kind::QUESTION], message_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn answer(conn: &Connection, question_id: i64, text: &str) -> Result<()> {
    let question = message(conn, question_id)?;
    if question.kind != kind::QUESTION {
        bail!(
            "message #{question_id} is a {}, not a question; answer an on-screen prompt with `hub worker key`",
            question.kind
        );
    }
    if question.answered_at.is_some() {
        bail!("question #{question_id} is already answered");
    }
    conn.execute(
        "update messages set answer = ?2, answered_at = ?3 where id = ?1",
        params![question_id, text, now()],
    )?;
    Ok(())
}

/// A Hub Session's Orchestrator: one per repo, on one Claude session for its whole life.
#[derive(Debug, Clone, Serialize)]
pub struct Session {
    pub id: i64,
    pub repo: String,
    pub session_id: String,
}

/// The repo's session, created on first use.
pub fn session(conn: &Connection, repo: &str) -> Result<Session> {
    conn.execute(
        "insert or ignore into sessions (repo, session_id, created_at) values (?1, ?2, ?3)",
        params![repo, uuid::Uuid::new_v4().to_string(), now()],
    )?;
    Ok(conn.query_row(
        "select id, repo, session_id from sessions where repo = ?1",
        [repo],
        |row| {
            Ok(Session {
                id: row.get(0)?,
                repo: row.get(1)?,
                session_id: row.get(2)?,
            })
        },
    )?)
}

pub fn sessions(conn: &Connection) -> Result<Vec<Session>> {
    let mut stmt = conn.prepare("select id, repo, session_id from sessions order by repo")?;
    let rows = stmt
        .query_map([], |row| {
            Ok(Session {
                id: row.get(0)?,
                repo: row.get(1)?,
                session_id: row.get(2)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// The Worker's newest message of a kind, if any.
pub fn last_message(conn: &Connection, worker_id: i64, message_kind: &str) -> Result<Option<Message>> {
    Ok(conn
        .query_row(
            &format!(
                "select {MESSAGE_COLUMNS} from messages where worker_id = ?1 and kind = ?2 order by id desc limit 1"
            ),
            params![worker_id, message_kind],
            message_row,
        )
        .optional()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (Connection, Worker) {
        let conn = open(Path::new(":memory:")).unwrap();
        let id = insert_worker(
            &conn,
            &NewWorker {
                repo: "/r",
                profile: "naruto",
                title: "t",
                spec: "s",
                cwd: "/r",
                branch: None,
                session_id: "sid",
            },
        )
        .unwrap();
        let w = worker(&conn, id).unwrap();
        (conn, w)
    }

    #[test]
    fn undelivered_messages_are_taken_once() {
        let (conn, w) = fixture();
        insert_message(&conn, &w, kind::STATUS, "a").unwrap();
        insert_message(&conn, &w, kind::DONE, "b").unwrap();
        let first = take_undelivered(&conn, "/r").unwrap();
        assert_eq!(first.iter().map(|m| m.body.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        assert!(take_undelivered(&conn, "/r").unwrap().is_empty());
        assert!(take_undelivered(&conn, "/other").unwrap().is_empty());
    }

    #[test]
    fn questions_open_until_answered_once() {
        let (conn, w) = fixture();
        let q = insert_message(&conn, &w, kind::QUESTION, "which?").unwrap();
        assert_eq!(open_questions(&conn, w.id).unwrap().len(), 1);
        answer(&conn, q, "this").unwrap();
        assert!(open_questions(&conn, w.id).unwrap().is_empty());
        assert!(answer(&conn, q, "again").is_err());
        assert_eq!(message(&conn, q).unwrap().answer.as_deref(), Some("this"));
    }

    #[test]
    fn only_questions_take_answers() {
        let (conn, w) = fixture();
        let b = insert_message(&conn, &w, kind::BLOCKER, "prompt").unwrap();
        assert!(answer(&conn, b, "yes")
            .unwrap_err()
            .to_string()
            .contains("hub worker key"));
    }

    #[test]
    fn one_session_per_repo() {
        let (conn, _) = fixture();
        let first = session(&conn, "/r").unwrap();
        assert_eq!(session(&conn, "/r").unwrap().session_id, first.session_id);
        assert_ne!(session(&conn, "/other").unwrap().session_id, first.session_id);
        assert_eq!(sessions(&conn).unwrap().len(), 2);
    }

    #[test]
    fn restart_marks_live_workers_lost() {
        let (conn, w) = fixture();
        set_state(&conn, w.id, state::RUNNING).unwrap();
        assert_eq!(mark_lost(&conn).unwrap().len(), 1);
        let after = worker(&conn, w.id).unwrap();
        assert_eq!(after.state, state::LOST);
        assert!(after.settled_at.is_some());
    }
}
