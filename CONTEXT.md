# Agent Hub

A working environment where one human talks to Orchestrators, which hand Tasks to specialised Workers and report back, or to plain Claude Code sessions, all in one app: Echo.

## Language

**Orchestrator**:
An agent that hands Tasks to Workers and reports back; it owns the Tasks, Workers, and summaries it started, and hears only from its own Workers.
_Avoid_: main agent, coordinator, lead

**Hub Session**:
Everything Echo runs in one repo: its Orchestrators and Normal sessions, and their Workers. Working on another repo means a separate Hub Session there, shown as its own repo tab.
_Avoid_: run, workspace

**Agent**:
One long-lived Claude conversation the human starts in a repo, either an Orchestrator or a Normal session. A repo can hold several; each has an optional name, else it is named after its first request.
_Avoid_: session (alone), tab

**Normal session**:
A plain Claude Code agent with no Workers; its own permission prompts still land in Needs you.
_Avoid_: solo mode, chat

**Agent Profile**:
A reusable definition of a specialist: which agent CLI, model, tools, role, skills, and context it starts with.
_Avoid_: subagent, agent type, persona

**Worker**:
A running instance of one Agent Profile, in its own terminal (and, when the Orchestrator decides, its own worktree), working on exactly one Task, closed when that Task ends.
_Avoid_: subagent, agent, session

**Task**:
A bounded unit of work the Orchestrator hands to one Worker.
_Avoid_: job, ticket

**Intervention**:
An instruction the human gives directly to a Worker, bypassing the Orchestrator; the Worker always reports it to the Orchestrator.
_Avoid_: override, manual input

**Worker Contract**:
The shared rules every Worker gets before its role, whatever its CLI: report each Intervention, ask the Orchestrator when blocked, and finish with a Final Report.
_Avoid_: base prompt, preamble

**Final Report**:
A Worker's last message for its Task: done or blocked, what changed, and how it was verified.
_Avoid_: result, output

**Summary**:
The Orchestrator's report to the human, always in three sections: Needs you, Done, Running.
_Avoid_: status update, digest

**Preferences**:
The human's standing instructions about how work should be done, kept between sessions and applied to every new Task.
_Avoid_: memory, settings

**Dashboard**:
The always-visible band above the Orchestrator's prompt listing every Worker of the Hub Session with its state.
_Avoid_: status panel, monitor

**Hub Daemon**:
The long-running process that owns every Worker's terminal, worktree, and messages, so Workers outlive the Orchestrator and the app.
_Avoid_: server, backend, runtime

**Echo**:
The native macOS app (formerly Hub App): one tab per repo, a ledger grouped by agent (Needs you, Running, Done), and one terminal; it only views and drives the Hub Daemon. The CLI and daemon keep the name `hub`.
_Avoid_: Hub App, client, GUI, frontend
