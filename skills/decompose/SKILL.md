---
name: decompose
description: Read an approved spec from the plan root folder and decompose it into implementation phases via planning-with-files. Creates task_plan.md and progress.md. Requires /spec-workflow:spec to have been run first.
argument-hint: "[--plan <plan_name>]"
user-invocable: true
allowed-tools: Write Edit Read Glob Grep Bash AskUserQuestion Skill
---

# Decompose — Break Spec into Implementation Phases

**Plan root:** `${PLAN_ROOT}` (from the `SPEC_WORKFLOW_ROOT` environment variable — required, see Root Resolution)
**Plans folder:** `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`)

Reads an approved spec and decomposes it into implementation phases using planning-with-files.


## Root Resolution

Every plan lives under one root folder, set by the `SPEC_WORKFLOW_ROOT` environment variable. Any directory works: a plain folder, a synced folder, or an Obsidian vault. Plans go in `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`).

At the start of the skill, run `echo "$SPEC_WORKFLOW_ROOT"`.

- **Set:** use it as `PLAN_ROOT`. If that directory does not exist, stop with: "`SPEC_WORKFLOW_ROOT` points to `{path}`, which does not exist. Create it, or fix the value in the `env` block of `~/.claude/settings.json`." Create `${PLANS_DIR}` if it is missing.
- **Unset:** the root is required. Never fall back to a default, the working directory, or the repo. Invoke `Skill("spec-workflow:setup")`, which asks for a folder, creates it, and saves it to settings. Continue with the `SPEC_WORKFLOW_ROOT=` path it reports. If the user cancels setup, stop with: "spec-workflow needs a plan root folder. Run `/spec-workflow:setup` when ready."

---

## Plan RAG Policy

If the `obsidian-plan-rag` MCP server is available, use it opportunistically after reading the approved spec and findings. Call `refresh_index` or `index_status` when freshness matters, then use `similar_plans` with the spec goal, repo, and domain keywords. For clearly relevant prior plans, call `get_plan_context` to inspect phase structure and acceptance criteria.

Use retrieved context to improve decomposition shape, sequencing, risk handling, and verification ideas. Cite useful returned snippets in `progress.md` or decomposition notes with `{filePath}:{sourceLineStart}-{sourceLineEnd}`. If MCP is unavailable, log "Plan RAG unavailable, skipping" and continue from local spec/findings only.

---

## Step 1: Resolve the Plan

Plans are independent: several can be open at once, in the same repo or different ones. There is no global active-plan pointer — never write one.

1. If `--plan <name>` was given, glob `${PLANS_DIR}/*/` and match the slug (case-insensitive, partial match OK).
2. Otherwise, get the current repo (`git rev-parse --show-toplevel`, else the working directory) and find open plans whose `spec.md` frontmatter has `repo:` or `workspace:` equal to that path. Prefer plans with no `task_plan.md` yet; if exactly one plan has none, use it without asking.

A plan is **open** when it has no `task_plan.md` yet (spec stage), or its `task_plan.md` `status` is not `completed`. `spec.md` status never means finished.
3. One match → use it. Several → AskUserQuestion listing them (plan name, status, updated date). None → stop with: "No plan found for this repo. Run `/spec-workflow:spec <plan-name>` to create a spec first, or pass `--plan <name>`."

Once resolved, `{PLAN_DIR}` is this plan for the rest of the session. Name the plan in summaries so parallel sessions stay distinguishable.

---

## Step 2: Validate Spec

Read `{PLAN_DIR}/spec.md`.

- **If missing:** Stop with: "No spec found at `{PLAN_DIR}/spec.md`. Run `/spec-workflow:spec` to create and approve a spec."
- **If `status: draft`:** Stop with: "Spec is still in draft. Run `/spec-workflow:spec` to review and approve it, or edit it directly at `{PLAN_DIR}/spec.md`."
- **If `status: approved`:** Continue.

Read `{PLAN_DIR}/findings.md` for context. If missing, warn but continue — findings are helpful but not required.

If plan RAG is available, retrieve prior decomposition memory now. Prefer completed plans with similar repo/domain. Do not paste large prior plans into the new task plan; borrow only phase patterns, missing risk checks, and verification ideas that fit the current approved spec.

---

## Step 3: Check for Existing Plan Files

If `{PLAN_DIR}/task_plan.md` already exists:
- Ask with AskUserQuestion: "A task plan already exists for this spec. Re-decompose from scratch (overwrites task_plan.md), or resume the existing plan?"
- Re-decompose → continue to Step 4.
- Resume → invoke `Skill("spec-workflow:resume-plan")` and stop.

---

## Recursive Quality Policy

Use a bounded generator-evaluator loop for the decomposition before reporting success:

1. Generate or refresh `task_plan.md` and `progress.md`.
2. Evaluate the phase plan against the decomposition rubric.
3. Revise only the gaps found by the evaluator.
4. Repeat until the plan meets the threshold or the iteration limit is reached.

Defaults: max 2 quality iterations, score each rubric axis 0-2, require at least 10/12 total and no axis scored 0. Do not ask the user during the loop: when the evaluator finds a scope or sequencing decision that cannot be inferred from `spec.md`, `findings.md`, or repo patterns, make the best-judgment call and log it in progress.md.

---

## Step 4: Load Templates

Load planning-with-files templates:

```bash
ls -t ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/planning-with-files/*/skills/planning-with-files/templates/*.md
```

Read `task_plan.md` and `progress.md` templates — if several cached versions match, use the first (newest) copy of each. Strip HTML comments (`<!-- ... -->`). If the glob matches zero files, use these fallback headings:
- task_plan.md: frontmatter + `## Phases` with `### Phase N: {name}` sections
- progress.md: frontmatter + `## Sessions` section

---

## Step 5: Create Plan Files

### Frontmatter

Get today's date via `date +%Y-%m-%d`. Copy `plan`, `repo`, and `related_repos` from spec.md frontmatter.

### task_plan.md

Prepend frontmatter (type: `task_plan`, status: `active`, current_phase: `1`, tags: `[plan, task-plan]`).

Write to `{PLAN_DIR}/task_plan.md`.

### progress.md

Prepend frontmatter (type: `progress`, tags: `[plan, progress]`).

Write to `{PLAN_DIR}/progress.md`.

---

## Step 6: Hand Off to Planning-with-Files

Invoke `Skill("planning-with-files:plan")` with this context:

> task_plan.md and progress.md already exist at `{PLAN_DIR}/`. Write phase decomposition INTO the existing task_plan.md — do not recreate the file or overwrite its frontmatter. Append to the existing progress.md. findings.md also already exists from /spec-workflow:spec — do not recreate or overwrite it.
>
> **Before decomposing into phases**, read `{PLAN_DIR}/spec.md` for approved requirements, success criteria, and boundaries. Also read `{PLAN_DIR}/findings.md` for research context. Use the spec to inform phase planning:
> - **Success criteria** → acceptance criteria for phases
> - **Key decisions** → already locked in by `/spec-workflow:spec`; treat them as fixed constraints
> - **Boundaries** → scope constraints for all phases
> - **Open questions marked `(deferred by user)`** → decide now with best judgment (consistent with spec boundaries and repo patterns). Record each as `Judgment call: {question} → {choice} ({rationale})` in the relevant phase notes and in progress.md. Do not create tasks that ask the user
> - **Dependencies** → phase gates or blockers
>
> `/spec-workflow:implement-plan` runs every phase unattended. Phases must be executable without user input — no "confirm with user", "get approval", or "decide X" tasks.

---

## Step 6b: Decomposition Quality Loop

Evaluate `{PLAN_DIR}/task_plan.md` with the Recursive Quality Policy before Step 7.

Rubric:

| Axis | Check |
|------|-------|
| Success coverage | Every success criterion from `spec.md` maps to at least one phase task or acceptance criterion. |
| Vertical slicing | Phases produce complete, testable increments instead of layer-only work. |
| Dependency order | Early phases unblock later work and surface open questions before implementation depends on them. |
| Scope discipline | Boundaries from `spec.md` are reflected as constraints or "do not do" notes. |
| Verification | Each phase has practical acceptance criteria and likely verification commands or checks. |
| Handoff quality | `implement-plan` can build from the plan without rereading all source material or asking the user anything. |

If the score is below 10/12 or any axis is 0, revise `task_plan.md` and append a compact quality-loop note to `progress.md`, then re-evaluate, up to 2 iterations. If the threshold is still not met, stop and report the unresolved decomposition gaps instead of presenting the plan as ready.

---

## Step 7: Summary

Present to the user:

```
Plan decomposed: **{Plan Name}**
Location: {PLAN_DIR}/

Files:
  - spec.md (approved)
  - findings.md (populated)
  - task_plan.md (active)
  - progress.md

Next step: Run /spec-workflow:implement-plan --plan {slug} to start building.
```

---

## Guidelines

- Plan files go in the plan root at absolute paths. NEVER write plan files to the current working directory.
