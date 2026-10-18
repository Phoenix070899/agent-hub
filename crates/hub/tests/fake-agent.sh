#!/bin/sh
# A stand-in for `claude` in daemon tests: $1 is the Task spec, and its first word picks a script.
if [ "$1" = "-p" ] && [ "$2" = "/usage" ] && [ -n "$HUB_FAKE_USAGE_FLAKY" ] && [ ! -e "$HUB_FAKE_USAGE_FLAKY" ]; then
  # The first call fails the way the real one sometimes does: a cost summary, no limits.
  touch "$HUB_FAKE_USAGE_FLAKY"
  printf 'Total cost:            $0.0000\nTotal duration (API):  0s\n'
  exit 0
fi
if [ "$1" = "-p" ] && [ "$2" = "/usage" ]; then
  # What `claude -p /usage` prints on a subscription.
  printf 'You are currently using your subscription to power your Claude Code usage\n\n'
  printf 'Current session: 48%% used · resets Oct 17 at 4:50pm (Asia/Saigon)\n'
  printf 'Current week (all models): 9%% used · resets Oct 23 at 11pm (Asia/Saigon)\n'
  printf 'Current week (Fable): 0%% used · resets Oct 23 at 11pm (Asia/Saigon)\n'
  exit 0
fi
echo "· Working… (1s · fake agent)"
case "$1" in
  ask*) answer=$(hub ask "Which color?") && hub done --state done "answer was $answer" ;;
  done*) hub done --state done "finished" ;;
  status*) hub send --type status "41 of 44 tests passing
details the ledger leaves out" ;;
  exit*) sleep 2; echo "fake agent giving up"; sleep 1; exit 1 ;;
  echo*) while IFS= read -r line; do echo "got: $line"; done ;;
  prompt*)
    printf '────────\nBash command\n rm -rf junk\nDo you want to proceed?\n> 1. Yes\n  2. No\n'
    IFS= read -r line
    printf '\033[2J\033[H'
    case "$line" in
      "") echo "approved" ;;
      *denied*) echo "denied: $line" ;;
    esac ;;
  *) sleep 600 ;;
esac
sleep 600
