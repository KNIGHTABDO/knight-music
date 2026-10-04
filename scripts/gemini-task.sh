#!/usr/bin/env bash
# Run one task with Gemini 3.8 Flash (Antigravity CLI) in its own git worktree, then loop on CI until green.
#
#   scripts/gemini-task.sh new    <branch> <brief.md> [base-ref=main]   # start a task
#   scripts/gemini-task.sh feedback <branch> <feedback.md>               # send review notes, loop again
#
# State lives in .gemini-tasks/<branch>/ (conversation id, log, last CI errors, screenshots).
# Gemini never pushes; this script commits, pushes, watches CI and feeds compile errors back (max $MAX_FIX rounds).
set -uo pipefail
ROOT=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
MODEL=${GEMINI_MODEL:-gemini-3.8-flash-high}
MAX_FIX=${MAX_FIX:-6}
MODE=$1; BRANCH=$2; FILE=$(realpath "$3")
SAFE=${BRANCH//\//-}
STATE="$ROOT/.gemini-tasks/$SAFE"; WT="$ROOT/.claude/worktrees/gem-$SAFE"
mkdir -p "$STATE"; LOG="$STATE/log.md"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

RULES="Rules: You are working inside a git worktree of the Knight Music iOS app. Read CLAUDE.md fully before coding and obey it.
There is NO Mac and NO Swift compiler here — do not try to build or run swift/xcodebuild; write code that compiles first time:
correct imports, exact type/method names copied from the existing code (open and read the files you call into), no invented APIs.
Do NOT run git commands, do NOT push, do NOT edit files outside the paths the brief allows. Do not create placeholder or fake data.
When finished, reply with a short list of files you created/changed."

agy_run() { # $1 = prompt ; uses conversation id if present
  local args=(-p "$1" --model "$MODEL" --dangerously-skip-permissions --output-format json --print-timeout 0)
  [ -f "$STATE/conv" ] && args+=(--conversation "$(cat "$STATE/conv")")
  local out; out=$(cd "$WT" && agy "${args[@]}" 2>>"$STATE/agy.err")
  local conv; conv=$(echo "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("conversation_id",""))' 2>/dev/null)
  [ -n "$conv" ] && echo "$conv" > "$STATE/conv"
  echo "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("status","?"), "-", round(d.get("duration_seconds",0)),"s"); print(d.get("response",""))' 2>/dev/null | tee -a "$LOG"
}

ci_round() { # commit, push, wait; returns 0 when green
  cd "$WT"
  git add -A
  git diff --cached --quiet && { say "no changes to commit"; }
  git commit -qm "$1" 2>/dev/null
  for _ in 1 2 3 4; do git push -q -u origin "$BRANCH" 2>>"$LOG" && break; say "push failed, retrying"; sleep 15; done
  local sha; sha=$(git rev-parse HEAD); local id=""
  for _ in $(seq 1 40); do
    id=$(gh run list --branch "$BRANCH" --limit 5 --json databaseId,headSha -q ".[] | select(.headSha==\"$sha\") | .databaseId" | head -1)
    [ -n "$id" ] && break; sleep 6
  done
  [ -z "$id" ] && { say "CI run not found"; return 1; }
  say "CI run https://github.com/KNIGHTABDO/knight-music/actions/runs/$id"
  gh run watch "$id" --exit-status >/dev/null 2>&1
  local concl; concl=$(gh run view "$id" --json conclusion -q .conclusion)
  echo "$id" > "$STATE/last_run"
  if [ "$concl" = success ]; then
    rm -rf "$STATE/screens"; gh run download "$id" -n screens -D "$STATE/screens" >/dev/null 2>&1 && say "screenshots → $STATE/screens"
    say "CI GREEN"; return 0
  fi
  gh run view "$id" --log-failed 2>/dev/null | grep -E "error:|fatal error" | sed -E 's/^.*Z //; s#.*/KnightMusic/#KnightMusic/#' | sort -u | head -80 > "$STATE/errors.txt"
  say "CI FAILED ($(wc -l < "$STATE/errors.txt") error lines)"; return 1
}

fix_loop() {
  for i in $(seq 1 "$MAX_FIX"); do
    ci_round "$1" && return 0
    [ -s "$STATE/errors.txt" ] || { say "failure without compiler errors — needs a human look (gh run view $(cat "$STATE/last_run") --log-failed)"; return 1; }
    say "fix round $i"
    agy_run "The CI build (Xcode 26, iOS 26 SDK) failed with these compiler errors. Open each file, understand the cause (check the real declarations of the types you use), and fix all of them properly — no stubs, no deleting features to silence errors.
$(cat "$STATE/errors.txt")"
    set -- "Fix compile errors (round $i)$(grep -q "\[shots\]" "$STATE/brief.md" 2>/dev/null && echo " [shots]")"
  done
  ci_round "Fix compile errors (final)" && return 0
  say "still failing after $MAX_FIX rounds"; return 1
}

case "$MODE" in
  new)
    BASE=${4:-main}
    rm -f "$STATE/conv"; : > "$LOG"
    git -C "$ROOT" fetch -q origin
    [ -d "$WT" ] || git -C "$ROOT" worktree add -q -B "$BRANCH" "$WT" "origin/$BASE" 2>>"$LOG" || git -C "$ROOT" worktree add -q -B "$BRANCH" "$WT" "$BASE"
    cp "$FILE" "$STATE/brief.md"
    say "task $BRANCH started in $WT (model $MODEL)"
    agy_run "$RULES

Your task brief:
$(cat "$FILE")"
    fix_loop "$(head -1 "$FILE" | sed 's/^# *//') (Gemini)"
    ;;
  feedback)
    say "feedback round from $FILE"
    agy_run "Code review feedback on your work. Address EVERY point thoroughly (the reviewer will check each one). Same rules as before.
$(cat "$FILE")"
    fix_loop "Address review feedback (Gemini)$(grep -q "\[shots\]" "$STATE/brief.md" && echo " [shots]")"
    ;;
  write)   # code only: no push, no CI (the integrator merges + builds once)
    BASE=${4:-main}
    rm -f "$STATE/conv"; : > "$LOG"
    git -C "$ROOT" fetch -q origin
    [ -d "$WT" ] || git -C "$ROOT" worktree add -q -B "$BRANCH" "$WT" "origin/$BASE" 2>>"$LOG"
    cp "$FILE" "$STATE/brief.md"
    say "task $BRANCH (write-only) started in $WT"
    agy_run "$RULES

Your task brief:
$(cat "$FILE")"
    cd "$WT" && git add -A && git commit -qm "$(head -1 "$FILE" | sed 's/^# *//') (Gemini)" && say "WRITE DONE (committed locally)"
    ;;
  ci)
    say "resuming CI loop"
    fix_loop "Retry CI (Gemini)$(grep -q "\[shots\]" "$STATE/brief.md" && echo " [shots]")"
    ;;
  *) echo "usage: $0 new|feedback <branch> <file> [base]"; exit 2;;
esac
