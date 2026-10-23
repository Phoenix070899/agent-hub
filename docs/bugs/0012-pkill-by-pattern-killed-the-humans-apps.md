# A test cleanup with pkill killed the human's daemon, agents, and apps

Found: 2026-10-19
Where: agent test cleanup on the human's Mac (shell commands, not repo code)
Fixed in: the change that adds this file

`pkill -f 'hub daemon' -P 1 -U $(id -u) -n` killed the human's Hub Daemon, and with it their Orchestrators a5, a6, a10, and a12, plus helper processes of Chrome, Slack, Zalo, and Orca.
Cause: BSD pkill on macOS stops reading options at the pattern, so `-P`, `1`, `-U`, `501`, and `-n` became extra patterns, and "1" matched almost every process.
Fix: until now the rule lived only in agent memory (never-pkill-by-pattern): kill test processes only by an exact PID checked first with `ps -o pid,command -p <pid>` and `ps eww` for `HUB_STATE`.
Lesson: never kill by pattern; kill one PID you have checked, put every pgrep option before the pattern, and preview with pgrep first.
