---
name: implement-plan
description: Execute phases from a spec-workflow plan. Delegates BUILD to a build agent (Sonnet), runs 3-axis parallel REVIEW, handles quality gates, visual comparison, and ralph-loop recovery. Requires /spec-workflow:spec + /spec-workflow:decompose to have been run first.
argument-hint: "[--plan <plan_name>] [--phase <phase_number>] [--figma <figma_url>] [--max-iterations <n>] [--max-quality-iterations <n>] [--quality-threshold <n>] [context...]"
user-invocable: true
allowed-tools: Write Edit Read Glob Grep Bash AskUserQuestion Skill Agent
hooks:
  UserPromptSubmit: 
    - hooks:
        - type: command
          command: "S=\"$CLAUDE_PLUGIN_ROOT/scripts/plan-hook.sh\"; [ -f \"$S\" ] || S=$(ls -t \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/*/spec-workflow/*/scripts/plan-hook.sh 2>/dev/null | head -1); [ -f \"$S\" ] && sh \"$S\" prompt; true"
  PostToolUse:
    - matcher: "Write|Edit"
      hooks:
        - type: command
          command: "S=\"$CLAUDE_PLUGIN_ROOT/scripts/plan-hook.sh\"; [ -f \"$S\" ] || S=$(ls -t \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/*/spec-workflow/*/scripts/plan-hook.sh 2>/dev/null | head -1); [ -f \"$S\" ] && sh \"$S\" post-slice; true"
  Stop:
    - hooks:
        - type: command
          command: "S=\"$CLAUDE_PLUGIN_ROOT/scripts/plan-hook.sh\"; [ -f \"$S\" ] || S=$(ls -t \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/*/spec-workflow/*/scripts/plan-hook.sh 2>/dev/null | head -1); [ -f \"$S\" ] && sh \"$S\" stop; true"
---

# Implementation Plan — Execute Phases with Build Agent

**Plan root:** `${PLAN_ROOT}` (from the `SPEC_WORKFLOW_ROOT` environment variable — required, see Root Resolution)
**Plans folder:** `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`)

**Architecture**: Orchestrator delegates BUILD to the `spec-workflow:build-agent` subagent (Sonnet), runs 3-axis REVIEW with parallel agents, handles quality gates and recovery inline.


## Root Resolution

Every plan lives under one root folder, set by the `SPEC_WORKFLOW_ROOT` environment variable. Any directory works: a plain folder, a synced folder, or an Obsidian vault. Plans go in `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`).

At the start of the skill, run `echo "$SPEC_WORKFLOW_ROOT"`.

- **Set:** use it as `PLAN_ROOT`. If that directory does not exist, stop with: "`SPEC_WORKFLOW_ROOT` points to `{path}`, which does not exist. Create it, or fix the value in the `env` block of `~/.claude/settings.json`." Create `${PLANS_DIR}` if it is missing.
- **Unset:** the root is required. Never fall back to a default, the working directory, or the repo. Invoke `Skill("spec-workflow:setup")`, which asks for a folder, creates it, and saves it to settings. Continue with the `SPEC_WORKFLOW_ROOT=` path it reports. If the user cancels setup, stop with: "spec-workflow needs a plan root folder. Run `/spec-workflow:setup` when ready."

---

## Plan Resolution

Plans are independent: several can be open at once, in the same repo or different ones. There is no global active-plan pointer — never write one.

1. If `--plan <name>` was given, glob `${PLANS_DIR}/*/` and match the slug (case-insensitive, partial match OK).
2. Otherwise, get the current repo (`git rev-parse --show-toplevel`, else the working directory) and find plans whose `task_plan.md` frontmatter has `repo:` or `workspace:` equal to that path and a `status` other than `completed`.
3. One match → use it. Several → AskUserQuestion listing them (plan name, status, updated date). None → stop with: "No plan found for this repo. Run `/spec-workflow:spec` then `/spec-workflow:decompose` first, or pass `--plan <name>`."

Once resolved, `{PLAN_DIR}` is this plan for the rest of the session. Name the plan in summaries so parallel sessions stay distinguishable.

---

## Plan File Protocol

All plan files live at absolute paths under the plan root. NEVER write plan files to the repo.

| File | When to READ | When to WRITE |
|------|-------------|---------------|
| `{PLAN_DIR}/task_plan.md` | Session start + before each slice | After each slice: check off tasks, update status, `updated:` date |
| `{PLAN_DIR}/progress.md` | Session start + after errors | After each slice + errors + session end |
| `{PLAN_DIR}/findings.md` | Session start + before technical decisions | After each slice (if new discoveries) |
| `{PLAN_DIR}/spec.md` | Session start (if exists) | Rarely — only if spec boundaries change |

## Plan RAG Policy

If the `obsidian-plan-rag` MCP server is available, use it opportunistically at phase start. Prefer compact queries and never pass raw, large retrieval dumps to build agents.

Default retrievals:
- Call `refresh_index` or `index_status` when plan files were just updated.
- Call `repo_memory` with the repo path/basename and phase topics to recover prior gotchas, testing patterns, blockers, and reusable implementation notes.
- Call `similar_plans` with the phase goal and acceptance criteria when the work has a recognizable prior pattern.
- Call `get_plan_context` only for a specific plan that appears highly relevant.

Add only the useful citations to the phase context using `{filePath}:{sourceLineStart}-{sourceLineEnd}`. If MCP is unavailable, log "Plan RAG unavailable, skipping" in the phase journal and continue. Do not duplicate database/search logic inside the skill.

---

## Step 0: Initialize

Parse `$ARGUMENTS` for flags:

| Flag | Default | Purpose |
|------|---------|---------|
| `--plan <name>` | Plan matching the current repo | Plan slug (partial match OK) |
| `--phase <N>` | All incomplete phases | Specific phase number |
| `--figma <url>` | Auto-detect from findings.md | Figma design URL for visual comparison |
| `--max-iterations <N>` | `10` | Max ralph-loop iterations if triggered |
| `--max-quality-iterations <N>` | `2` | Max evaluator-driven quality loop iterations per phase |
| `--quality-threshold <N>` | `10` | Minimum score out of 12 for phase completion |

Remaining text = additional context for the Spec step.

### 0.0. Keep the computer awake

Run once, before anything else (macOS; skip silently if `caffeinate` is missing). Prevents display, idle, disk, and system sleep for the whole run. The 12h timeout is a safety net so it can never be left running forever.

```bash
if command -v caffeinate >/dev/null 2>&1; then
  [ -f ~/.claude/implement-plan-caffeinate.pid ] && kill "$(cat ~/.claude/implement-plan-caffeinate.pid)" 2>/dev/null
  nohup caffeinate -dims -t 43200 >/dev/null 2>&1 &
  echo $! > ~/.claude/implement-plan-caffeinate.pid
fi
```

Release it (see Step 7 → "Release wake lock") when the run ends — on success **or** on a hard-failure stop.

### 0a. Resolve the plan

1. Resolve the plan per **Plan Resolution** above, matching on `task_plan.md`.
2. **Read ALL plan files** — task_plan.md, findings.md, progress.md, and spec.md (if exists). Log brief summary.

### 0b. Extract repo and configuration

1. **Repo path**: From `repo:` frontmatter. Verify it exists. Also read `related_repos:` for context.
2. **Detect tooling in one pass**: Glob the repo root for `{pnpm-lock.yaml,yarn.lock,package-lock.json,bun.lockb,package.json,jest.config.*,vitest.config.*,playwright.config.*}`. Read package.json once. Derive:
   - **Package manager**: from lockfile (pnpm > yarn > npm > bun)
   - **Test command**: from package.json scripts or config files
   - **Lint/type commands**: from scripts or tsc in devDependencies
3. **Figma URL**: If `--figma` not provided, search findings.md for `figma.com/design/` or `figma.com/make/` URLs.

### 0b.2. Choose workspace (current branch, new branch, or worktree)

Apart from disambiguating the plan in 0a, this is the **only** user question in the run. Ask it once, before any code changes.

Run `git -C {repo} branch --show-current`, detect the default branch (`git -C {repo} symbolic-ref --short refs/remotes/origin/HEAD`, strip `origin/`), and check for uncommitted changes (`git -C {repo} status --porcelain`). Then use AskUserQuestion:

> Where should I implement **{Plan Name}**?

- **"Current branch ({branch})"** — commit directly in `{repo}` on `{branch}`. If `{branch}` is the default branch, say so in the option description.
- **"New branch ({plan-slug})"** — check out a new branch in the same checkout (no worktree). Mark "(Recommended)" when on the default branch and the working tree is clean. If the working tree is dirty, note in the description that uncommitted changes will carry over to the new branch.
- **"New worktree branch"** — create an isolated worktree. Mark "(Recommended)" when the working tree is dirty.
- If progress.md logs a worktree for this plan from a prior session and that path still exists, add **"Reuse worktree ({path})"** as the first option, marked "(Recommended)" (overrides the other recommendations).

Branch name = plan slug for both new-branch options (never prefix with `codex/`).

**New branch setup:**
```bash
git -C {repo} checkout -b {plan-slug}
```
If `{plan-slug}` already exists, `git -C {repo} checkout {plan-slug}` instead. `{repo}` stays the same path.

**Worktree setup:**
```bash
git -C {repo} worktree add "{repo}/../{repo-basename}-{plan-slug}" -b {plan-slug}
```
If the branch already exists, add the worktree without `-b`. Install dependencies in the worktree with the detected package manager.

When the workspace path differs from `repo:` (worktree), set `workspace: {path}` in task_plan.md frontmatter so hooks and later sessions opened in the worktree find this plan.

From here on, **`{repo}` means the chosen workspace path** — pass it to build agents, reviewers, and verification commands. Log the choice (branch + path) in progress.md in Step 0e.

### 0b.1. Retrieve plan memory

After repo/tooling detection, query plan RAG if available:

1. Refresh or check index freshness.
2. Retrieve `repo_memory` for the primary repo and current phase keywords.
3. Retrieve `similar_plans` for the phase goal and acceptance criteria.
4. Stage only high-signal citations in the phase journal. Pass compact citations to the build agent, not full retrieval dumps.

### 0b.5. Define phase quality contract

Before the first phase, define the evaluator contract for this run:

```markdown
## Phase Quality Contract
- Acceptance criteria:
- Required verification commands:
- Evaluator rubric: correctness, test coverage, architecture/readability, security, scope control, maintainability
- Threshold: {quality_threshold}/12 and no rubric axis scored 0
- Max quality iterations: {max_quality_iterations}
- Keep condition: tests/checks pass and evaluator threshold is met
- Rework condition: evaluator finds fixable gaps within scope
- Stop condition: max quality iterations exceeded, unclear product judgment, or verification cannot run
```

Stage this in the phase journal. This is the implementation version of the generator-evaluator loop: build, verify, evaluate, revise, and repeat within the configured limits.

### 0c. Determine execution mode

**All-phases mode** (DEFAULT — no `--phase` flag):

**CRITICAL: Do NOT stop between phases. Do NOT ask "want me to continue?" Do NOT output per-phase summaries. Run ALL incomplete phases back-to-back in a single response until every phase is complete or one fails.**

1. Parse all phases from task_plan.md. Filter to status NOT `complete`.
2. Execute each through Steps 1–7. Transition directly to the next phase — no intermediate output, no user confirmation, no pause.
3. **MANDATORY after each phase**: Update task_plan.md (check off ALL completed tasks, set phase `**Status:** complete`, bump `current_phase` to N+1, update `updated:` date). Hard gate before next phase.
4. **Before each new phase**: Re-read task_plan.md and progress.md for current state.
5. If a phase fails (ralph-loop exhausted), stop and report.
6. When ALL phases complete, set frontmatter `status: completed`. Output a single consolidated summary covering all phases executed.

**Single-phase mode** (`--phase N`): Execute only that phase.

### Best-Judgment Rule (both modes)

After the workspace question in Step 0b.2, **never call AskUserQuestion or pause for the user**. The spec was approved and open questions were locked in by `/spec-workflow:spec`; anything left is an implementation call. Whenever a step would otherwise need user input (unclear requirement, many slices, product-judgment gap, visual discrepancy):

1. Pick the option most consistent with spec.md (success criteria, boundaries, key decisions) and existing repo patterns. When options are equal, choose the smaller, more reversible one.
2. Log it in progress.md under `### Judgment Calls`: question, choice, rationale.
3. Continue.

Stop only on hard failures: ralph-loop exhausted, verification commands cannot run, or the only viable path violates a spec.md **Never Do** boundary (release the wake lock before reporting). Report all judgment calls in the final summary so the user can review them.

### 0d. Validate and activate the target phase

1. Extract target phase section from task_plan.md.
2. If already `complete` (single-phase mode) → re-implement it and log a judgment call.
3. If prior phases incomplete (single-phase mode) → log a dependency warning in progress.md and proceed.
4. Update frontmatter: `current_phase: {N}`, phase status to `in_progress`.

### 0e. Log session start

Append to progress.md:
```markdown

## Implementation Session: {today}

### Phase {N}: {phase name}
- **Status:** in_progress
- **Started:** {today}
- **Repo:** {repo path}
- **Package manager:** {detected}
- **Workspace:** {branch} at {path} ({current branch | new branch | worktree})
```

---

## Step 1: SPEC — Understand Requirements

**Goal**: Complete understanding before writing code.

1. List every checkbox from the target phase section.
2. Refer to findings.md context for requirements, decisions, architecture notes.
3. If spec.md exists, use its success criteria as acceptance criteria and boundaries to constrain scope.
4. Check prior phase outputs if applicable.
5. Incorporate additional context from `$ARGUMENTS`.
6. If anything is unclear, resolve it with the Best-Judgment Rule.

Write a spec summary to progress.md.

---

## Step 2: PLAN — Break Into Vertical Slices

**Vertical slicing** (not layer-by-layer): each slice delivers a complete, testable piece.

1. Group phase tasks into slices. Target: 1-5 tasks, <150 lines per slice.
2. For each slice: tasks included, files to create/modify, verification criteria.
3. Order by dependency chain.
4. Log slice plan to progress.md.
5. If >5 slices, re-check that each slice is necessary and in scope, then proceed without asking.

---

## Step 3: BUILD+VERIFY — Delegate to Build Agent

For each slice, launch an Agent with `subagent_type: "spec-workflow:build-agent"` (`model: "sonnet"`). The agent definition ships with this plugin and carries the TDD protocol and journal format. The prompt contains:

- Slice tasks, files to create/modify, verification criteria
- Repo config: path, package manager, test/lint/typecheck commands
- Relevant patterns from findings.md (existing components, conventions, test patterns)
- Project-specific code quality rules if applicable (React composition, frontend patterns, etc.)

### 3.5: Process Build Journal

After the build agent returns:

1. **Parse the structured journal** from the agent's response (between `<!-- BUILD_JOURNAL_START -->` and `<!-- BUILD_JOURNAL_END -->` markers).
2. **Update task_plan.md**: Check off completed tasks (`- [x]`), update `updated:` date.
3. **Append to progress.md**: Build journal contents — files, tests, commits, reuse decisions.
4. **Update findings.md**: If the agent reported new discoveries.

**If agent returned `failed_after_3_strikes`:**

Invoke ralph-loop with full context:
```
Skill("ralph-loop:ralph-loop", args="'Fix verification failures in {repo path}. Error: {failure context from journal}. Files: {files list}. Previous attempts: {3 attempt summaries from journal}. Run {test command} to verify. <promise>ALL TESTS PASS</promise> when green.' --max-iterations {max_iterations} --completion-promise 'ALL TESTS PASS'")
```

After ralph-loop: verify fix is sound (not a hack), log in progress.md, continue.

**Checkpoint commit** (if build agent didn't already commit): `git add` specific files, commit referencing phase + slice.

---

## Step 3.6: Slice Quality Loop

After each slice journal is processed, evaluate the changed slice against the Phase Quality Contract.

1. Score each axis 0-2:
   - correctness,
   - test coverage / verification,
   - architecture / readability,
   - security,
   - scope control,
   - maintainability.
2. If the score is at least `--quality-threshold` and no axis is 0, continue.
3. If the gaps are concrete and in scope, create a small rework slice and loop back to Step 3 for those fixes only.
4. If the gaps require product judgment, unclear scope, or risky tradeoffs, apply the Best-Judgment Rule.
5. If `--max-quality-iterations` is exceeded, stop and report the unresolved gaps with the verification state.

Keep the loop journal compact: score, top gaps, action taken, verification command, result. Do not expand scope just to improve the score.

---

## Step 4: SIMPLIFY — Clean Up (before review, so reviewers see final code)

1. Remove dead code, unused imports, commented-out blocks.
2. Simplify overly complex logic.
3. Ensure consistent formatting with project conventions.
4. Verification run.
5. Commit: "Phase {N}: cleanup and simplification".

---

## Step 5: REVIEW — Three-Axis Parallel Review

Launch **3 Agent subagents in a single message**:

1. **Correctness + Performance** (`model: "opus"`): Logic, edge cases, test coverage, bugs, N+1 queries, unbounded loops, memory leaks, re-renders.
2. **Architecture + Readability** (`model: "sonnet"`): Pattern consistency, appropriate abstractions, naming clarity, code organization.
3. **Security** (`model: "opus"`): Input validation, injection risks, credential handling, dependency vulnerabilities.

Each agent gets: list of files changed, repo path, instructions to focus on their axis only.

**After agents return:**
1. Consolidate — filter nitpicks, focus on bugs/security/maintenance.
2. Fix legitimate issues and commit.
3. Re-run verification if fixes were made.
4. Log review findings in progress.md.

---

## Step 6: VISUAL COMPARISON (Conditional)

**Only if** Figma URL provided. Skip if Figma or Playwright MCPs unavailable.

**Circuit breaker**: Max **1 Figma attempt**. If it fails, skip and log.

### 7a. Figma Values Verification

Cross-check implementation against design values in findings.md (**Design System Findings**). Verify colors map to tokens, spacing uses scale, typography references theme.

If findings.md has no Figma values, attempt a single `get_design_context` call. If that fails, skip to 7b.

### 7b. Screenshot Comparison

1. **Figma screenshot**: Extract fileKey/nodeId. If nodeId missing, skip. Call `get_screenshot` once.
2. **Implementation screenshot**: Start dev server, poll HTTP 200 (max 30s), screenshot via Playwright MCP, stop dev server.
3. **Compare**: Compare both screenshots yourself (do not pause for the user). If discrepancies: list specifics, create fix tasks, loop back to Step 3 for those tasks only. Describe any unresolved discrepancies in the final summary. **Stop dev server before looping.**
4. **Cleanup**: Close Playwright browser.

---

## Step 7: FINALIZE

### Cleanup
```bash
rm -f impl-plan-screenshot-*.png
```

### Release wake lock

Run after the final phase completes (or on any hard-failure stop), before the report. In all-phases mode do this only once, after the last phase.

```bash
[ -f ~/.claude/implement-plan-caffeinate.pid ] && kill "$(cat ~/.claude/implement-plan-caffeinate.pid)" 2>/dev/null; rm -f ~/.claude/implement-plan-caffeinate.pid
```

### Optional metric autoresearch mode

Use this only when the phase has a measurable optimization target such as runtime, bundle size, memory, query count, visual diff score, flaky-test rate, or lint/error count.

1. Record a baseline metric and the exact command used to measure it.
2. Propose one bounded experiment at a time.
3. Implement the experiment on the current branch and commit it.
4. Run the metric command with output redirected to a log when noisy.
5. Keep the experiment only if it improves the metric without violating tests, scope, security, or maintainability; otherwise revert the experiment commit and log `discard` or `crash`.
6. Stop when the target is met, iteration budget is reached, or improvements become too small to justify added complexity.

Log metric loops as a compact table in the phase journal: commit, metric, status (`keep`, `discard`, `crash`), and description.

### Quality gates

Verify all prior gates passed (tests, lint, typecheck, simplify, review, visual, Slice Quality Loop). If any failed, loop back to the relevant step within the configured iteration limit.

### Update plan files (MANDATORY hard gate)

1. **task_plan.md**: Check off ALL tasks. Set phase `**Status:** complete`. Update `current_phase` to N+1. Update `updated:` date. If last phase → set `status: completed`.
2. **progress.md**: Session summary — slices, files, tests, commits, review findings.
3. **findings.md**: Append new discoveries. Update `updated:` date.

### Report

**Single-phase mode**: Log phase name, slices completed, files, tests, commits, review issues.

**All-phases mode**: Do NOT output anything between phases. Accumulate all results. Output a single consolidated summary ONLY after ALL phases are complete. Never ask "want me to continue?" — just continue.

Both modes: end the summary with a **Judgment Calls** list (from progress.md) so the user can review decisions made without asking.

---

## Parallelization Rules

**Do NOT parallelize**: Build agent slices (sequential by dependency), plan file updates.
