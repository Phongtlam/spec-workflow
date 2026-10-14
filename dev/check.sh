#!/usr/bin/env bash
# Pre-commit checks for spec-workflow. Enforces the rules in CLAUDE.md that a
# script can verify. Run from anywhere: dev/check.sh
set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0
fail() { echo "✘ $*"; FAIL=1; }
ok() { echo "✔ $*"; }

# 1. Manifests
if command -v claude >/dev/null 2>&1; then
  claude plugin validate . >/dev/null 2>&1 && ok "marketplace.json valid" || fail "claude plugin validate . failed"
  claude plugin validate .claude-plugin/plugin.json >/dev/null 2>&1 && ok "plugin.json valid" || fail "claude plugin validate .claude-plugin/plugin.json failed"
else
  echo "- skipped manifest validation (claude CLI not found)"
fi

# 2. Frontmatter parses as YAML, and skill names match their folders
if command -v ruby >/dev/null 2>&1; then
  OUT=$(LANG=en_US.UTF-8 ruby -Eutf-8 -ryaml -e '
    bad = 0
    (Dir["skills/*/SKILL.md"] + Dir["agents/*.md"]).sort.each do |f|
      begin
        y = YAML.load(File.read(f).split(/^---$/)[1])
        if f.start_with?("skills/") && y["name"] != File.basename(File.dirname(f))
          puts "#{f}: name \"#{y["name"]}\" does not match its folder"; bad = 1
        end
      rescue => e
        puts "#{f}: #{e.message}"; bad = 1
      end
    end
    exit bad')
  [ $? -eq 0 ] && ok "frontmatter YAML parses" || fail "frontmatter: $OUT"
else
  echo "- skipped YAML check (ruby not found)"
fi

# 3. Every skill is in the README skills table
for d in skills/*/; do
  s=$(basename "$d")
  grep -q "^| \`$s\` |" README.md || fail "skill '$s' missing from the README skills table"
done
ok "README skills table checked"

# 4. Every config variable is documented in README and handled by setup
for v in $(grep -rhoE 'SPEC_WORKFLOW_[A-Z_]+' skills scripts | sort -u); do
  grep -q "$v" README.md || fail "$v is used but not documented in README.md"
  grep -q "$v" skills/setup/SKILL.md || fail "$v is used but not handled in skills/setup/SKILL.md"
done
ok "config variables checked"

# 5. Every external plugin a skill calls is installed by setup and listed in README
for p in $( { grep -rhoE 'Skill\("[a-z0-9-]+:' skills | sed -E 's/Skill\("//; s/://';
              grep -rhoE 'claude plugin install [a-z0-9-]+' skills | awk '{print $4}'; } \
            | grep -v '^spec-workflow$' | sort -u); do
  grep -q "$p" skills/setup/SKILL.md || fail "plugin '$p' is used but setup does not install it"
  grep -q "$p" README.md || fail "plugin '$p' is used but README does not mention it"
done
ok "plugin dependencies checked"

# 6. No personal paths, old pointer, or old variable outside setup's migration step
HITS=$(grep -rnE '/Users/|phonglam|active-plan-path|OBSIDIAN_VAULT_PATH' skills agents scripts .claude-plugin \
       | grep -v '^skills/setup/SKILL.md:')
[ -z "$HITS" ] && ok "no personal paths or pointer usage" || fail "forbidden references:
$HITS"

# 6b. No shared state files in ~/.claude: they break parallel plans. Per-plan state goes in the plan folder.
STATE=$(grep -rnE '(~|\$HOME|CLAUDE_CONFIG_DIR[^/]*)/\.?claude/' skills agents scripts \
        | grep -vE '\.claude\}?/(settings(\.local)?\.json|plugins/)' | grep -v '^skills/setup/SKILL.md:')
[ -z "$STATE" ] && ok "no shared state files under ~/.claude" || fail "shared state under ~/.claude (use the plan folder instead):
$STATE"

# 7. Hook script: syntax, and a fixture run that must find exactly one plan
if sh -n scripts/plan-hook.sh; then
  T=$(mktemp -d)
  mkdir -p "$T/root/plans/demo" "$T/repo" && git -C "$T/repo" init -q
  REPO=$(git -C "$T/repo" rev-parse --show-toplevel)
  printf -- '---\nplan: "demo"\nrepo: %s\nstatus: active\ncurrent_phase: 1\n---\n### Phase 1: Build\n**Status:** in_progress\n- [ ] task\n' \
    "$REPO" > "$T/root/plans/demo/task_plan.md"
  OUT=$(cd "$T/repo" && SPEC_WORKFLOW_ROOT="$T/root" sh "$OLDPWD/scripts/plan-hook.sh" prompt)
  echo "$OUT" | grep -q "plans/demo — Phase 1 active" && ok "hook script finds plan by repo" || fail "hook script fixture failed: $OUT"
  rm -rf "$T"
else
  fail "scripts/plan-hook.sh has a syntax error"
fi

# 8. Version bumped when shipped files changed since origin/main
if git rev-parse --verify -q origin/main >/dev/null; then
  if ! git diff --quiet origin/main -- skills agents scripts .claude-plugin/marketplace.json \
     || [ -n "$(git status --porcelain -- skills agents scripts)" ]; then
    OLD=$(git show origin/main:.claude-plugin/plugin.json | sed -nE 's/.*"version": *"([^"]+)".*/\1/p')
    NEW=$(sed -nE 's/.*"version": *"([^"]+)".*/\1/p' .claude-plugin/plugin.json)
    [ "$OLD" != "$NEW" ] && ok "version bumped ($OLD → $NEW)" \
      || fail "shipped files changed but version is still $NEW — bump it in .claude-plugin/plugin.json"
  else
    ok "no shipped changes since origin/main"
  fi
fi

echo
[ $FAIL -eq 0 ] && echo "All checks passed." || echo "Checks failed."
exit $FAIL
