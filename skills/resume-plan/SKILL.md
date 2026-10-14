---
name: resume-plan
description: List all plans in the plan root folder and resume one. Loads full context from task_plan.md, findings.md, and progress.md, then activates planning hooks for the session.
argument-hint: "[plan-name]"
user-invocable: true
allowed-tools: Write Edit Read Glob Grep Bash AskUserQuestion Skill
hooks:
  UserPromptSubmit:
    - hooks:
        - type: command
          command: "S=\"$CLAUDE_PLUGIN_ROOT/scripts/plan-hook.sh\"; [ -f \"$S\" ] || S=$(ls -t \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/*/spec-workflow/*/scripts/plan-hook.sh 2>/dev/null | head -1); [ -f \"$S\" ] && sh \"$S\" prompt; true"
  PreToolUse:
    - matcher: "Write|Edit|Bash|Read|Glob|Grep"
      hooks:
        - type: command
          command: "S=\"$CLAUDE_PLUGIN_ROOT/scripts/plan-hook.sh\"; [ -f \"$S\" ] || S=$(ls -t \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/*/spec-workflow/*/scripts/plan-hook.sh 2>/dev/null | head -1); [ -f \"$S\" ] && sh \"$S\" pre; true"
  PostToolUse:
    - matcher: "Write|Edit"
      hooks:
        - type: command
          command: "S=\"$CLAUDE_PLUGIN_ROOT/scripts/plan-hook.sh\"; [ -f \"$S\" ] || S=$(ls -t \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/*/spec-workflow/*/scripts/plan-hook.sh 2>/dev/null | head -1); [ -f \"$S\" ] && sh \"$S\" post; true"
  Stop:
    - hooks:
        - type: command
          command: "S=\"$CLAUDE_PLUGIN_ROOT/scripts/plan-hook.sh\"; [ -f \"$S\" ] || S=$(ls -t \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/*/spec-workflow/*/scripts/plan-hook.sh 2>/dev/null | head -1); [ -f \"$S\" ] && sh \"$S\" stop; true"
---

# Resume Plan — Load Existing Plan from the Plan Root

**Plan root:** `${PLAN_ROOT}` (from the `SPEC_WORKFLOW_ROOT` environment variable — required, see Root Resolution)
**Plans folder:** `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`)

You are helping the user resume an existing plan from the plan root. This skill handles plan selection and context loading, then delegates to the `planning-with-files` plugin methodology for ongoing work.

## Root Resolution

Every plan lives under one root folder, set by the `SPEC_WORKFLOW_ROOT` environment variable. Any directory works: a plain folder, a synced folder, or an Obsidian vault. Plans go in `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`).

At the start of the skill, run `echo "$SPEC_WORKFLOW_ROOT"`.

- **Set:** use it as `PLAN_ROOT`. If that directory does not exist, stop with: "`SPEC_WORKFLOW_ROOT` points to `{path}`, which does not exist. Create it, or fix the value in the `env` block of `~/.claude/settings.json`." Create `${PLANS_DIR}` if it is missing.
- **Unset:** the root is required. Never fall back to a default, the working directory, or the repo. Invoke `Skill("spec-workflow:setup")`, which asks for a folder, creates it, and saves it to settings. Continue with the `SPEC_WORKFLOW_ROOT=` path it reports. If the user cancels setup, stop with: "spec-workflow needs a plan root folder. Run `/spec-workflow:setup` when ready."

## Steps

1. **Check if a plan name was provided.** If `$ARGUMENTS` is provided, try to match it (case-insensitive, partial match OK) to an existing plan folder slug under the plans folder. If exactly one match, skip to step 4 with that plan. If multiple matches, show them and ask user to pick.

   If the chosen folder has no `task_plan.md`, the plan is still at the spec stage and cannot be resumed here. Stop with: "**{plan}** has a spec but no task plan yet." plus the next step: `/spec-workflow:spec {slug}` if `spec.md` is `status: draft`, or `/spec-workflow:decompose --plan {slug}` if it is `status: approved`.

2. **Find all plans.** Use Glob to find all `task_plan.md` files matching `${PLANS_DIR}/*/task_plan.md`. If none exist, tell the user "No plans found. Use /spec-workflow:spec to create one." and stop.

3. **Present plans for selection.** For each plan folder found, read the first 15 lines of task_plan.md to extract:
   - Plan name: from `plan:` frontmatter field, or from the `# Task Plan:` heading, or from the folder name
   - Status: from `status:` frontmatter field, or inferred from phase statuses
   - Repo: from `repo:` frontmatter field, or "unknown"
   - Updated: from `updated:` frontmatter field

   Also get the current repo (`git rev-parse --show-toplevel`) to flag plans whose `repo:` or `workspace:` matches it.

   Sort by updated date (newest first). Present using AskUserQuestion with options formatted as:
   ```
   [{status}] {plan name} — repo: {repo basename} (updated: {date})
   ```
   Prefix plans for the current repo with "[this repo]" and list them first. Show up to 10 plans.

4. **Plans are independent.** Never pause or modify other plans — several can be active at once.

5. **Activate the plan.** If its task_plan.md frontmatter `status` is not `active`, set `status: active` and `updated` to today. If the plan's `repo:` differs from the current repo, tell the user the plan hooks key off the repo, so they should run the session from `{repo}` (or its worktree) for context to load automatically.

6. **Add frontmatter if missing (legacy plans).** If the plan files lack YAML frontmatter (no `---` at line 1), add it now:
   - Infer plan name from the folder name (expand slug: hyphens to spaces, title case)
   - Set `repo` to empty string and mention the user can update it
   - Set `created` to today (we don't know the original date)
   - Set `type` appropriately for each file (`task_plan`, `findings`, `progress`)
   - Set `tags` appropriately (`plan` + type)
   - Preserve ALL existing content below the new frontmatter block

7. **Load full plan context.** Read all three files and present a summary:

   **Goal:** {goal from task_plan.md}
   **Status:** Phase {N} of {total} — {current phase name}

   **Completed phases:**
   - Phase 1: {name} [x]

   **Current phase:**
   - Phase 3: {name} [>] — {open tasks}

   **Remaining:**
   - Phase 4: {name} [ ]

   **Key findings:** {count} entries in findings.md
   **Errors logged:** {count} in error tables

8. **Add a new session entry to progress.md.** Append a new session block:
   ```markdown

   ## Session: {today's date}

   ### Resuming from Phase {N}: {phase name}
   - **Status:** in_progress
   - **Started:** {today's date}
   - Actions taken:
     -
   - Files created/modified:
     -
   ```
   Update the `updated` date in progress.md frontmatter.

9. **Set the stage.** Ask the user: "What would you like to work on next?" and suggest the current phase's open tasks as starting points. From this point on, follow the `planning-with-files` plugin methodology for all planning work — write all files to the plan root using absolute paths.

## Guidelines

- Get the user back into flow quickly — load context and ask what's next.
- If a plan has `status: completed`, show it with a "[completed]" indicator in the picker. If the user selects a completed plan, confirm before resuming: "This plan is marked as completed. Resume it anyway?" If they decline, return to the picker.
- When adding frontmatter to legacy plans, preserve all existing content below the frontmatter block.
- Always update the `updated` frontmatter date when modifying plan files.
- After resuming, the `planning-with-files` methodology applies (2-Action Rule, Read Before Decide, Update After Act, 3-Strike Protocol, etc.) — but files live in the plan root, not CWD.
