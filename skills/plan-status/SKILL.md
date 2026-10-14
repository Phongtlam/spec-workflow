---
name: plan-status
description: Show the status of the plan for the current repo, or browse all plans in the plan root folder. Displays current phase, progress, and any errors.
argument-hint: "[plan-name]"
user-invocable: true
allowed-tools: Read Glob Bash AskUserQuestion Skill
---

# Plan Status — Check Planning Progress

**Plan root:** `${PLAN_ROOT}` (from the `SPEC_WORKFLOW_ROOT` environment variable — required, see Root Resolution)
**Plans folder:** `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`)

You are checking the status of plans stored in the plan root. This is a read-only skill.

## Root Resolution

Run `echo "$SPEC_WORKFLOW_ROOT"`.

- **Set:** use it as `PLAN_ROOT`. If that directory does not exist, stop with: "`SPEC_WORKFLOW_ROOT` points to `{path}`, which does not exist. Run `/spec-workflow:setup` to fix it."
- **Unset:** invoke `Skill("spec-workflow:setup")` and continue with the `SPEC_WORKFLOW_ROOT=` path it reports. If the user cancels setup, stop with: "spec-workflow needs a plan root folder. Run `/spec-workflow:setup` when ready."

## Steps

1. **Pick the plan to show.** Several plans can be open at once, so there is no single active plan.
   - If `$ARGUMENTS` names a plan, match it against folder slugs in `${PLANS_DIR}` (case-insensitive, partial match OK). One match → step 3. Several → AskUserQuestion to pick.
   - Otherwise get the current repo (`git rev-parse --show-toplevel`, else the working directory) and find plans whose `task_plan.md` frontmatter has `repo:` or `workspace:` equal to it and `status` other than `completed`. One match → step 3. Several → AskUserQuestion to pick one, listing name, status and updated date.
   - No match → step 2.

2. **List all plans.** Glob `${PLANS_DIR}/*/task_plan.md`. For each, read the first 15 lines to extract plan name, status, repo and updated date. Sort by updated date (newest first).

   Also glob `${PLANS_DIR}/*/spec.md` for folders without a `task_plan.md` and list them as `spec only — run /spec-workflow:decompose`.

   If there are no plans at all, say "No plans found. Use /spec-workflow:spec to create one." and stop.

   If there are multiple plans, use AskUserQuestion to let the user pick one to view in detail.

3. **Show plan status.** Read the plan's task_plan.md fully. Count total phases (`### Phase` headings), completed phases (`**Status:** complete`), and in-progress phases (`**Status:** in_progress`). Also count error table rows.

   Display a compact summary:

   ```
   Plan: {plan name}
   Repo: {repo path}{  (worktree: {workspace}) if set}
   Status: {status from frontmatter}
   Progress: Phase {current} of {total}

     [x] Phase 1: {name}
     [x] Phase 2: {name}
     [>] Phase 3: {name}  <-- current
     [ ] Phase 4: {name}
     [ ] Phase 5: {name}

   Errors logged: {count}
   Last updated: {date from frontmatter}
   Plan directory: {absolute path}
   ```

   Use `[x]` for complete, `[>]` for in_progress, `[ ]` for pending.

   If other open plans exist for the same repo, add one line: `Also open in this repo: {names}`.

4. **Offer next actions.** After showing status, mention available commands:
   - `/spec-workflow:implement-plan --plan {slug}` to keep building
   - `/spec-workflow:resume-plan {slug}` to load this plan's full context into the session
   - `/spec-workflow:spec` to create a new plan

## Guidelines

- This is a **read-only** skill — it never modifies plan files.
- Keep output compact and scannable. This answers "where am I?" quickly.
- If a plan has no frontmatter (legacy plan), extract what you can from the markdown content (headings, phase statuses).
- Handle gracefully if plan files are missing (e.g., only task_plan.md exists, no progress.md).
- If the plan has `status: completed`, show it clearly so the user knows there's nothing to resume.
