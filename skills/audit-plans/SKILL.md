---
name: audit-plans
description: "Audit all spec-workflow plans — verify completion against git/GitHub, add PR artifacts, and archive completed plans."
user-invocable: true
allowed-tools: Write Edit Read Glob Grep Bash AskUserQuestion Agent Skill
---

# Audit Plans — Verify, Document, and Archive Plans

**Plan root:** `${PLAN_ROOT}` (from the `SPEC_WORKFLOW_ROOT` environment variable — required, see Root Resolution)
**Plans folder:** `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`)
**Archive folder:** `${ARCHIVE_DIR}` (= `${PLAN_ROOT}/completed-plans`)

You are auditing all plans in the plan root. The goal is to find plans that are actually completed (PRs merged to main/master), confirm with the user, write delivery artifacts, and archive them.

## Root Resolution

Run `echo "$SPEC_WORKFLOW_ROOT"`.

- **Set:** use it as `PLAN_ROOT`. If that directory does not exist, stop with: "`SPEC_WORKFLOW_ROOT` points to `{path}`, which does not exist. Run `/spec-workflow:setup` to fix it."
- **Unset:** invoke `Skill("spec-workflow:setup")` and continue with the `SPEC_WORKFLOW_ROOT=` path it reports. If the user cancels setup, stop with: "spec-workflow needs a plan root folder. Run `/spec-workflow:setup` when ready."

This skill uses the GitHub CLI. If `gh auth status` fails, tell the user to install and log in to `gh`, and fall back to `git log` evidence only.

## Step 1: Discover All Plans

1. Use Glob to find all `task_plan.md` files: `${PLANS_DIR}/*/task_plan.md`
2. If none found, tell the user "No plans found." and stop.
3. Read the first 15 lines of each to extract:
   - `plan:` — plan name
   - `status:` — current status (completed, active, paused, etc.)
   - `repo:` — primary repository path
   - `related_repos:` — additional repos (if present)
   - `updated:` — last updated date
4. Also check if each plan folder already has an `artifacts.md` file (Glob: `{plan_folder}/artifacts.md`).

Categorize every plan into one of these buckets:
- **already-audited**: `status: completed` AND `artifacts.md` exists → skip entirely
- **needs-artifacts**: `status: completed` BUT no `artifacts.md` → needs PR lookup + artifacts file
- **audit-candidate**: `status: active` or `status: paused` → needs full audit

Several plans can be in progress at once, so there is no single active plan to skip. The audit protects in-progress work through evidence instead: a plan is only offered for completion when its PR is verified merged to the default branch, and every status change needs the user's confirmation. Plans still being built come back as `in progress` and are left untouched.

Present a summary table to the user:
```
| Plan | Status | Has artifacts.md | Action |
|------|--------|-------------------|--------|
| ... | completed | Yes | Skip (already audited) |
| ... | completed | No | Find PRs, write artifacts |
| ... | active | — | Audit for completion |
| ... | paused | — | Audit for completion |
```

If there are no audit-candidates and no needs-artifacts plans, say "All plans are up to date. Nothing to audit." and stop.

## Step 2: Audit Candidates via Parallel Agents

For each **audit-candidate** plan, dispatch an Agent (model: sonnet) to verify whether it's actually completed. Group plans by repo when possible to reduce redundant git operations.

Each agent MUST:
1. Read the full `task_plan.md` to understand all phases and completion status
2. Check if the repo exists locally: `ls {repo_path}`
3. If repo exists, search for merged PRs:
   - `cd {repo_path} && gh pr list --state merged --search "{search_terms}" --limit 5 --json number,title,url,mergedAt,baseRefName,state`
   - Also: `git log --oneline -20 --all --grep="{keyword}"`
4. **CRITICAL: Verify the PR is on the default branch.** For each candidate PR:
   - `gh pr view {PR_NUMBER} --json mergedAt,baseRefName,state,mergeCommit`
   - OR: `git log main --oneline --grep="{PR_TITLE_OR_KEYWORD}" -5` (use `master` if `main` doesn't exist)
   - The PR must show `state: MERGED` AND `baseRefName: main` or `master`
5. Return a structured report:
   ```
   Plan: {name}
   Phases: {completed}/{total}
   PR: #{number} — {title}
   PR URL: {url}
   Merged: {date}
   Base branch: {main/master}
   Merge verified: {Yes — commit {hash} found on default branch / No — PR not merged}
   Key commits: {hash} {description}, ...
   Recommendation: {completed / in progress / paused / abandoned}
   Reasoning: {one line}
   ```

**Agent prompt template:**
```
Audit this spec-workflow plan to determine if it should be marked "completed".

Plan folder: {plan_folder_path}
Repo: {repo_path}
Related repos: {related_repos or "none"}

1. Read the full task_plan.md
2. Check if repo exists, search for merged PRs
3. If related_repos are listed, also search those repos for PRs related to this plan
4. VERIFY the PR landed on main/master: run `gh pr view NNN --json mergedAt,baseRefName,state,mergeCommit` and confirm baseRefName is main or master
5. Check git log on default branch for the merge commit

Return a structured report with: plan name, phases total/completed, PR info (number, title, URL, merge date, base branch) for ALL repos, merge verification, key commits, recommendation (completed/in progress/paused/abandoned), one-line reasoning. Use "in progress" when phases are incomplete and there is recent work (commits or an open PR) but nothing merged to the default branch yet.
```

## Step 3: Find PRs for Needs-Artifacts Plans

For plans that are already `status: completed` but missing `artifacts.md`, also dispatch agents to find their PRs. Same verification requirements — confirm PRs are on main/master.

If the plan already has a `## Delivery` section inline in task_plan.md, the agent should extract that data instead of searching git.

## Step 4: Present Findings and Confirm Completions

After all agents return, present the results to the user:

```
## Audit Results

| Plan | Phases | PR | Merged | Verified on main | Recommendation |
|------|--------|----|--------|-------------------|----------------|
| ... | 7/7 | #158 | 2026-04-13 | Yes | completed |
| ... | 2/5 | none | — | — | in progress |
```

For plans recommended as **completed** with verified merges, use AskUserQuestion (multiSelect) to confirm:
- Question: "These plans have verified merged PRs on main/master. Which ones should be marked completed?"
- Options: one per plan, labeled as `{plan name} — PR #{number} merged {date}`

Plans where the PR is NOT verified on main/master: flag as "PR not on default branch — review manually" and do NOT include in the confirmation list.

Plans the user doesn't select stay as-is.

## Step 5: Write artifacts.md

For each confirmed plan (from Step 4) and each needs-artifacts plan (from Step 3):

Create `artifacts.md` in the plan folder:

```markdown
---
plan: "{plan name}"
type: artifacts
created: {today's date YYYY-MM-DD}
tags:
  - plan
  - artifacts
---

# Delivery Artifacts

| Item | Details |
|------|---------|
| PR | [#{number} — {title}]({url}) |
| Merged | {YYYY-MM-DD} |
| Base branch | {main/master} |
| Merge verified | Yes — commit {hash} found on default branch |
| Key commits | `{hash}` {description} |
| | `{hash}` {description} |
```

If the plan has multiple PRs, list them all in the table.

**Migration:** If the plan's task_plan.md already contains a `## Delivery` section:
1. Extract the data from it into the new artifacts.md
2. Remove the `## Delivery` section from task_plan.md (use Edit to delete it)

## Step 6: Confirm and Update Plan Statuses

**Do NOT silently flip statuses.** Present a final confirmation:

Use AskUserQuestion: "Ready to mark these plans as completed. Confirm?" with multiSelect listing each plan and its evidence:
- `{plan name} — PR #{number} verified on {main/master}`

For each plan the user confirms:
- Read task_plan.md
- Update frontmatter: `status: completed` and `updated: {today}`

For plans the user does NOT confirm: leave status unchanged.

For plans where merge was NOT verified: do NOT offer them for status change. Instead note: "Skipped — PR not verified on default branch. Review manually."

## Step 7: Archive Completed Plans

After all artifacts are written and statuses updated:

1. Collect ALL plans now marked `status: completed` (both newly confirmed and previously completed).
2. Present the list and use AskUserQuestion: "Move these completed plans to `${ARCHIVE_DIR}/`?"
   - Options: "Yes, move all", "Let me pick which ones", "No, keep them in plans/"
3. If "Let me pick": use AskUserQuestion with multiSelect listing each plan.
4. If confirmed:
   - `mkdir -p "${ARCHIVE_DIR}"`
   - `mv "{plan_folder}" "${ARCHIVE_DIR}/{folder_name}"`
5. Report what was moved.

## Edge Cases

- **Repo doesn't exist locally**: Note "repo unavailable — unable to verify merge" in artifacts. Still allow user to confirm completion manually if they know the work is done.
- **No PRs found**: Search `git log` for relevant commits. If found, use commit info in artifacts. If nothing found, note "No PR or commits found" and recommend "paused" or "abandoned".
- **Plan has `## Delivery` inline in task_plan.md**: Extract to artifacts.md, remove from task_plan.md.
- **Plan still being built** (incomplete phases, recent commits, nothing merged): recommend `in progress`, write nothing, change nothing.
- **All plans already audited**: "All plans are up to date. Nothing to audit." Stop.
- **PR exists but NOT merged to main/master** (e.g., merged to feature branch, or still open): Flag clearly — do NOT recommend as completed.
- **Multiple PRs for one plan**: Include all in artifacts.md table.
- **Agent can't determine default branch name**: Try both `main` and `master` — `git rev-parse --verify main 2>/dev/null || git rev-parse --verify master 2>/dev/null`.

## Guidelines

- Always verify against the actual default branch — never trust plan status alone.
- User confirmation is required at two points: (1) which plans to mark completed, (2) which plans to archive.
- Keep agent prompts focused — one clear task per agent, structured output format.
- Use sonnet model for agents to balance speed and cost.
- Absolute paths everywhere — no relative paths.
- Today's date for all timestamps: use the current date at runtime.
