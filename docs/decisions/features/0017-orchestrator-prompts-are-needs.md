# An Orchestrator's own permission prompt is a Need, like a Normal session's

Decided: 2026-10-20
Status: accepted

The daemon watches every agent's screen for permission prompts, Orchestrators included, not only Normal sessions (ADR 0006).
The Need has no Worker; its profile is "orchestrator", Echo heads it "The Orchestrator wants to run", and it notifies like any other new Need.
Approve and Deny press the key in the Orchestrator's terminal, as they do for a Normal session.
Leaving Orchestrators out meant a prompt waited silently whenever the human was looking at another agent or away from Echo.
