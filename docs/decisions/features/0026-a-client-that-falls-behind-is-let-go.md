# An attached client that falls far behind is let go

Decided: 2026-10-22
Status: accepted

The daemon queues at most 1024 output chunks (16 KiB each at most) for each attached terminal client.
A client whose queue is full is dropped; it attaches again and gets a fresh screen.
Why: the queue had no limit, so a stopped `hub attach` or a hung pane kept every byte of a busy agent's output in daemon memory.
Blocking the agent's output until the client catches up was rejected: one stuck client would stall the agent and every other client.
