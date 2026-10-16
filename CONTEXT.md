# Agent Hub

A working environment where one human talks only to an Orchestrator, which hands Tasks to specialised Workers and reports back.

## Language

**Orchestrator**:
The single agent the human talks to; it owns all Tasks, Workers, and summaries.
_Avoid_: main agent, coordinator, lead

**Hub Session**:
One Orchestrator run bound to exactly one repo; working on another repo means starting a separate Hub Session there.
_Avoid_: run, workspace

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
