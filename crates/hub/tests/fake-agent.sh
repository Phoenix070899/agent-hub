#!/bin/sh
# A stand-in for `claude` in daemon tests: $1 is the Task spec, and its first word picks a script.
echo "· Working… (1s · fake agent)"
case "$1" in
  ask*) answer=$(hub ask "Which color?") && hub done --state done "answer was $answer" ;;
  done*) hub done --state done "finished" ;;
  exit*) sleep 2; echo "fake agent giving up"; sleep 1; exit 1 ;;
  echo*) while IFS= read -r line; do echo "got: $line"; done ;;
  prompt*)
    printf 'Bash command\n rm -rf junk\nDo you want to proceed?\n> 1. Yes\n  2. No\n'
    IFS= read -r line
    printf '\033[2J\033[H'
    case "$line" in
      "") echo "approved" ;;
      *denied*) echo "denied: $line" ;;
    esac ;;
  *) sleep 600 ;;
esac
sleep 600
