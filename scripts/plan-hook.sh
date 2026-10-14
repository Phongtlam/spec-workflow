#!/bin/sh
# Prints plan context for skill hooks. Finds open plans whose task_plan.md `repo:` or
# `workspace:` frontmatter matches the current git repo, so several plans can run in
# parallel without a global pointer. Silent when nothing matches.
#
# Usage: plan-hook.sh prompt|pre|post|post-slice|stop

MODE="${1:-prompt}"
VAULT="${OBSIDIAN_VAULT_PATH:-}"
[ -n "$VAULT" ] && [ -d "$VAULT/plans" ] || exit 0

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

frontmatter() {
  sed -n '1{/^---$/!q;};2,/^---$/p' "$1"
}

MATCHES=""
for f in "$VAULT"/plans/*/task_plan.md; do
  [ -f "$f" ] || continue
  frontmatter "$f" | grep -qE '^status: *"?(completed|paused)' && continue
  if frontmatter "$f" | grep -E '^(repo|workspace):' \
      | sed -E 's/^[a-z_]+: *//; s/^"//; s/"$//' | grep -qxF "$ROOT"; then
    MATCHES="${MATCHES}$(dirname "$f")
"
  fi
done

COUNT=$(printf '%s' "$MATCHES" | grep -c .)
[ "$COUNT" -eq 0 ] && exit 0

if [ "$COUNT" -gt 1 ]; then
  case "$MODE" in
    prompt|stop)
      echo "[spec-workflow] $COUNT open plans for $ROOT:"
      printf '%s' "$MATCHES" | sed 's/^/  - /'
      echo "[spec-workflow] Stay on the plan this session is working on; update only its files."
      ;;
  esac
  exit 0
fi

PLAN_DIR=$(printf '%s' "$MATCHES" | head -1)
PLAN="$PLAN_DIR/task_plan.md"
PHASE=$(grep -m1 '^current_phase:' "$PLAN" | sed 's/current_phase: *//')

case "$MODE" in
  prompt)
    echo "[spec-workflow] Plan: $PLAN_DIR — Phase $PHASE active"
    sed -n "/### Phase $PHASE/,/^### Phase/p" "$PLAN" | head -25
    echo ''
    echo '=== recent progress ==='
    tail -15 "$PLAN_DIR/progress.md" 2>/dev/null
    echo ''
    echo "[spec-workflow] Read findings.md for research context. Stay focused on Phase $PHASE. Verify before marking complete."
    ;;
  pre)
    head -30 "$PLAN"
    ;;
  post)
    echo "[spec-workflow] Update $PLAN_DIR/progress.md with what you just did. If a phase is now complete, update task_plan.md status and current_phase."
    ;;
  post-slice)
    echo '[spec-workflow] Update plan files after each slice. If the build agent returned a journal, process it now.'
    ;;
  stop)
    SECTION=$(sed -n "/### Phase $PHASE/,/^### Phase/p" "$PLAN")
    TOTAL=$(printf '%s\n' "$SECTION" | grep -c -- '- \[')
    DONE=$(printf '%s\n' "$SECTION" | grep -c -- '- \[x\]')
    if printf '%s\n' "$SECTION" | grep -F '**Status:**' | head -1 | grep -q complete; then
      echo "[spec-workflow] Phase $PHASE COMPLETE ($DONE/$TOTAL tasks)."
    else
      echo "[spec-workflow] Phase $PHASE IN PROGRESS ($DONE/$TOTAL tasks). Update progress.md before stopping."
    fi
    ;;
esac
exit 0
