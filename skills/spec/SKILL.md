---
name: spec
description: Research context (Jira, Figma, Confluence, codebase), write a spec.md with approval gate, and save findings.md to the plan root folder. Downstream skills (/spec-workflow:decompose, /spec-workflow:implement-plan) find the plan by repo or --plan.
argument-hint: "<plan-name> [--jira <ticket>] [--figma <url>] [--confluence <url>] [--repos <path1,path2>]"
user-invocable: true
allowed-tools: Write Edit Read Glob Grep Bash AskUserQuestion Agent
---

# Spec — Research + Synthesize + Approve

**Plan root:** `${PLAN_ROOT}` (from the `SPEC_WORKFLOW_ROOT` environment variable — required, see Root Resolution)
**Plans folder:** `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`)

Flow:
1. **Setup** — name, repo, folder (Steps 1-6)
2. **Context gathering** — Jira, Figma, Confluence, codebase (Steps 7-8)
3. **Spec gate** — write spec.md, lock in open questions one at a time, get user approval (Steps 9-10)

After approval, user runs `/spec-workflow:decompose` to break the spec into phases.

### Model Strategy

This skill is where the hard thinking happens — understanding the problem, synthesizing across multiple sources, and making architectural decisions. **Use Opus for all steps.** A better spec = simpler implementation = less total cost.

When launching Agent subagents (e.g., codebase exploration in Step 8d), use `model: "opus"` to ensure deep analysis of patterns, architecture, and potential pitfalls.


## Root Resolution

Every plan lives under one root folder, set by the `SPEC_WORKFLOW_ROOT` environment variable. Any directory works: a plain folder, a synced folder, or an Obsidian vault. Plans go in `${PLANS_DIR}` (= `${PLAN_ROOT}/plans`).

At the start of the skill, run `echo "$SPEC_WORKFLOW_ROOT"`.

- **Set:** use it as `PLAN_ROOT`. If that directory does not exist, stop with: "`SPEC_WORKFLOW_ROOT` points to `{path}`, which does not exist. Create it, or fix the value in the `env` block of `~/.claude/settings.json`." Create `${PLANS_DIR}` if it is missing.
- **Unset:** the root is required. Never fall back to a default, the working directory, or the repo. Invoke `Skill("spec-workflow:setup")`, which asks for a folder, creates it, and saves it to settings. Continue with the `SPEC_WORKFLOW_ROOT=` path it reports. If the user cancels setup, stop with: "spec-workflow needs a plan root folder. Run `/spec-workflow:setup` when ready."

---

## Shared Conventions

### Frontmatter Template

All plan files use this structure (get today's date via `date +%Y-%m-%d`):

```yaml
---
plan: "{Plan Name}"
type: {type}
repo: {repo path or ""}
related_repos: []
created: {today}
updated: {today}
{extra fields}
tags:
  - plan
  - {tag}
---
```

The `related_repos` field is optional. Include it when the plan spans multiple repos. `repo` is always the primary repo. `related_repos` captures secondary repos for cross-repo context.

| File | `type` | Extra fields | `tag` |
|------|--------|-------------|-------|
| spec.md | spec | `status: draft` | spec |
| findings.md | findings | — | findings |

### MCP Error Policy

All MCP calls (Jira, Figma, Confluence) are optional. If any MCP server is unavailable or a call fails, log "{Service} unavailable, skipping" and continue. Never block the workflow on MCP failures.

### Plan RAG Policy

If the `obsidian-plan-rag` MCP server is available, use it opportunistically. Start with `refresh_index` or `index_status` when freshness matters, then call `similar_plans` using the plan name, user description, Jira summary, and repo keywords. Prefer completed plans first when looking for reusable patterns. Record useful returned snippets in `findings.md` under a **Prior Plan Memory** subsection with source file paths and line ranges.

If the MCP server is unavailable, log "Plan RAG unavailable, skipping" in findings and continue. Do not shell out to duplicate DB logic inside this skill.

## Recursive Quality Policy

Use bounded generator-evaluator loops for generated planning artifacts. The pattern is:

1. Generate the draft artifact.
2. Evaluate it against the stage rubric.
3. Revise only the weaknesses found by the evaluator.
4. Repeat until the artifact meets the threshold or the iteration limit is reached.

Defaults: max 2 quality iterations per artifact, score each rubric axis 0-2, require at least 10/12 total and no axis scored 0. Prefer concrete criteria over subjective "better/worse" feedback. The evaluator can be the same model with a fresh pass over the artifact, but it must produce structured findings. Ask the user only when the evaluator finds a scope, product, or safety decision that cannot be inferred from provided context.

### Template Loading

**Load planning-with-files templates once** at the start of Step 8, before any research:

```bash
ls -t ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/planning-with-files/*/skills/planning-with-files/templates/*.md
```

Read the `findings.md` template — if several cached versions match, use the first (newest) copy of each. Strip HTML comments (`<!-- ... -->`). If the glob matches zero files, use the section headings described in Step 8e as a fallback structure.

---

## Step 1: Note Other Open Plans

Plans are independent — several can be open at once, even in the same repo. Never pause or modify another plan.

A plan is **open** when it has no `task_plan.md` yet (spec stage), or its `task_plan.md` `status` is not `completed`. `spec.md` status never means finished.

If `$ARGUMENTS` is empty and the current repo already has open plans (matching `repo:` or `workspace:` in `spec.md` or `task_plan.md`), ask with AskUserQuestion: "This repo has open plans: **{names}**. Start a new spec, or continue one of them?" If they choose to continue one, follow **Continuing an Existing Plan** (Step 5) for it and stop. Otherwise continue to Step 2.

---

## Step 2: Determine Plan Name and Parse Flags

Parse `$ARGUMENTS` for the plan name and optional flags:

| Flag | Purpose |
|------|---------|
| `--jira <ticket>` | Jira ticket key (e.g., DEV-1234) |
| `--figma <url>` | Figma design URL |
| `--confluence <url>` | Confluence page URL |
| `--repos <path1,path2,...>` | Comma-separated list of related repo paths |

Everything not a flag is the plan name.

If `$ARGUMENTS` is empty, skip flag parsing and ask the user for a plan name with AskUserQuestion.

---

## Step 3: Determine Repo Path

Run `git rev-parse --show-toplevel 2>/dev/null`. If detected, use as the primary `repo` path and confirm with the user. If not, ask: "What repo/project is this plan for? (path or 'none')"

If `--repos` was provided, split on commas and store as `related_repos`. Validate each path exists. If any path is invalid, warn and skip it.

---

## Step 4: Generate Folder Slug

Lowercase the plan name, replace spaces/underscores with hyphens, remove special characters, collapse multiple hyphens, limit to 50 chars, trim trailing hyphens.

**Guard**: If the resulting slug is empty, ask the user for a different name.

---

## Step 5: Check if Plan Folder Already Exists

If `${PLANS_DIR}/{slug}/` exists:
- If `spec.md` exists inside: enter **update mode** — "A spec already exists for this plan. Re-research and update it, or resume from where you left off?" Re-research → continue to Step 7 (will overwrite spec.md + findings.md). Resume → follow **Continuing an Existing Plan** below.
- If no spec.md: ask "A plan folder exists but has no spec. Continue creating the spec here?"

**Continuing an Existing Plan** — pick the next step from the plan's stage:
- `task_plan.md` exists → invoke `Skill("spec-workflow:resume-plan")` with the plan's slug and stop.
- `spec.md` is `status: draft` → set `{PLAN_DIR}` to that folder, read `spec.md` and `findings.md`, and continue at Step 9c (open questions), then Step 10.
- `spec.md` is `status: approved` → stop with: "This spec is approved. Run `/spec-workflow:decompose --plan {slug}` to break it into phases."

---

## Step 6: Create Plan Directory

```bash
mkdir -p "${PLANS_DIR}/{slug}"
```

---

## Step 7: Interactive Context Collection

**Fast-path**: If at least one flag (`--jira`, `--figma`, `--confluence`) was provided AND a plan name exists, skip the AskUserQuestion and proceed directly to Step 8.

**Otherwise**, use AskUserQuestion:

> Setting up spec for **"{Plan Name}"** in repo `{repo path}`.
>
> What context do you have? Provide any combination:
> - **Jira ticket** (e.g., DEV-1234)
> - **Figma URL** (design link)
> - **Confluence page** (spec/doc URL)
> - **Description** of what you want to build

If flags were already parsed, list them as "Already collected: {list}" and ask only for additional context.

After the user responds, parse for Jira keys (`[A-Z]+-\d+`), Figma URLs (`figma.com/`), Confluence URLs (`atlassian.net/wiki/`), and remaining text as description.

---

## Step 8: Research

Load templates first (see "Template Loading" in Shared Conventions above).

### 8.0. Prior Plan Memory

Before external research, query the plan RAG if available:

1. Call `similar_plans` with a compact text packet: plan name, user description, Jira summary if known, repo basename, and important domain keywords.
2. For the top relevant completed or active plans, call `get_plan_context` only when the search snippet is clearly useful.
3. Add concise findings to `findings.md` with citations like `{filePath}:{sourceLineStart}-{sourceLineEnd}`.
4. Use prior memory as context, not authority. Current Jira/Figma/code evidence wins when sources conflict.

### Resolve Atlassian cloudId (if Jira or Confluence context provided)

Before calling any Atlassian MCP tool, resolve the cloudId: try passing the site hostname (e.g., `site.atlassian.net`) as `cloudId`. If that fails, call `mcp__atlassian__getAccessibleAtlassianResources()` to get the list.

### 8a-8d: Parallel Fetches

Steps 8a, 8b, 8c, and 8d are fully independent. **Execute ALL applicable fetches simultaneously in a single tool-call block.**

**8a. Jira** (if ticket provided): Fetch via Atlassian MCP (`getJiraIssue`, request markdown format). Extract summary, description, acceptance criteria, linked issues, labels.

**8b. Figma** (if URL provided): Extract design context for the spec. Implementation should NOT need to rediscover Figma requirements.

**Tier 1 — Direct context (if URL has `node-id`):**
- Extract `fileKey` and `nodeId` from the URL.
- Call `get_design_context` with both.
- If successful, also call `search_design_system` with component-relevant keywords.

**Tier 2 — Design system search (if no `node-id` OR Tier 1 failed):**
- Call `search_design_system` with keywords derived from the plan name and Jira summary.
- Call `get_libraries` on the fileKey to identify which libraries are in use.

**Circuit breaker — after exhausting applicable tiers, move on.** Do NOT retry with root node IDs (`0:1`, `0:0`), random node guesses, or `get_metadata` on files without node IDs.

**Extract concrete values** for each component or screen discovered:
- Colors (hex/rgb, mapped to tokens), Spacing (px), Typography (family, size, weight, line-height), Border (radius, width, color), Shadows, Sizes, States (hover, focus, disabled, error)

Record under **Design System Findings** → **Extracted Values** in findings.md.

**8c. Confluence** (if URL provided): Fetch via Atlassian MCP (`getConfluencePage`, request markdown format). Capture spec content, requirements, architecture notes.

**8d. Codebase** (if repo detected): Launch an Agent (subagent_type: Explore) to search the repo for patterns relevant to the plan — existing components, test patterns, routing, API patterns, key files.

### 8e. Write findings.md

Using the findings.md template loaded earlier, populate sections:
- **Requirements**: From Jira AC, user description, Confluence spec
- **Research Findings**: From codebase exploration — existing patterns, relevant files, tech stack
- **Design System Findings**: From Figma — component names, token names, variant states, library sources. Include **Extracted Values** subsection with concrete design values.
- **Technical Decisions**: Obvious architecture choices (leave empty if too early)
- **Resources**: Jira URL, Figma URL, Confluence URL, key file paths

Prepend frontmatter (see Shared Conventions) and write to `{PLAN_DIR}/findings.md`.

---

## Step 9: Write spec.md

Synthesize research into a concise spec. Prepend frontmatter (see Shared Conventions, `status: draft`). Write to `{PLAN_DIR}/spec.md`.

### Spec Structure

| Section | Content | Source |
|---------|---------|--------|
| **Objective** | What (1 sentence) + Why (1 sentence) | Jira summary + user description + Confluence |
| **Success Criteria** | 3-5 measurable outcomes | Jira AC, user goals, Figma completeness |
| **Boundaries** | Always Do / Needs Approval / Never Do | Codebase conventions + user constraints |
| **Open Questions** | Unresolved decisions | Research gaps, ambiguous requirements |
| **Dependencies** | External blockers | Jira linked issues, missing APIs, pending design |
| **Key Decisions** | Table: Decision, Options, Chosen, Rationale | Research trade-offs; mark "TBD" where user input needed |

---

## Step 9b: Spec Quality Loop

Before showing the spec to the user, run the Recursive Quality Policy against `{PLAN_DIR}/spec.md`.

Rubric:

| Axis | Check |
|------|-------|
| Objective clarity | The what and why are clear, scoped, and not overloaded. |
| Source coverage | Jira, Figma, Confluence, codebase, and user description are represented when available. |
| Verifiability | Success criteria are measurable enough to drive tests or targeted checks. |
| Boundaries | Always Do / Needs Approval / Never Do are explicit and actionable. |
| Decision quality | Key decisions have options, chosen direction, and rationale; true unknowns remain open questions. |
| Implementation readiness | A downstream decomposer can identify likely phases, risks, and dependencies without re-researching. |

If the score is below 10/12 or any axis is 0, revise `{PLAN_DIR}/spec.md` in place and re-evaluate, up to 2 iterations. Keep the final spec concise. If the threshold is still not met after 2 iterations, proceed to Step 10 but include the unresolved quality gaps in the approval-gate summary so the user can decide whether to revise or approve.

---

## Step 9c: Lock In Open Questions (one at a time)

Before the approval gate, resolve every item in **Open Questions** and every `TBD` in **Key Decisions** with the user. Skip this step only if both are empty.

1. Collect the list. Order by impact: questions that change scope or architecture first, cosmetic/detail questions last. Tell the user: "{N} open questions to lock in before approval."
2. Ask **exactly one question per AskUserQuestion call** — never batch multiple questions into one call. For each question:
   - Give 1-2 sentences of context (why it matters, what research found).
   - Offer 2-4 concrete options; put the recommended option first with "(Recommended)" appended to its label and a one-line rationale in its description.
   - Header: `Q{i}/{N}`.
3. After each answer, immediately update `{PLAN_DIR}/spec.md`:
   - Remove the question from **Open Questions**.
   - Record it in **Key Decisions** (Decision, Options, Chosen = user's answer, Rationale = user's reason or the recommendation rationale). Replace any matching `TBD`.
   - Propagate the answer into affected sections (Success Criteria, Boundaries, Dependencies).
4. If an answer makes later questions moot, drop them. If it raises a new question, append it to the queue and update N.
5. If the user answers "defer" / "decide later", keep it in **Open Questions** marked `(deferred by user)` and move on.

Do not proceed to Step 10 until the queue is empty (every question answered or explicitly deferred).

---

## Step 10: Spec Review Gate

Read back `{PLAN_DIR}/spec.md` and display its content inline. Use AskUserQuestion with 3 options:

- **"Approve — finalize"** → Update spec.md frontmatter `status: approved` and `updated:` date. Continue to Step 11.
- **"Revise — I have feedback"** → Ask follow-up: "What changes?" Rewrite spec.md incorporating feedback. If the rewrite introduces new open questions or `TBD`s, run Step 9c on them. Loop back.
- **"Add more context"** → Ask what to add. Process new inputs through Step 8 (parallel fetches for new items only). **Merge** new findings into existing findings.md (append, don't overwrite). Rewrite spec.md with enriched context. Loop back.

**Bound**: After 3 revisions, offer: "Would you like to approve the current spec, or edit spec.md directly at `{PLAN_DIR}/spec.md`?"

---

## Step 11: Finish

Present summary:

```
Spec created: **{Plan Name}**
Location: {PLAN_DIR}/

Files:
  - spec.md (approved)
  - findings.md (populated)

Next step: Run /spec-workflow:decompose --plan {slug} to break this spec into implementation phases.
```

---

## Guidelines

- Plan files go in the plan root at absolute paths. NEVER write plan files to the current working directory.
- Always update the `updated` frontmatter date when modifying plan files.
- If the plan root is an Obsidian vault, the frontmatter also enables Dataview queries like `TABLE plan, status FROM #plan WHERE repo CONTAINS "auth"`.
- `/spec-workflow:decompose` and `/spec-workflow:implement-plan` find this plan by its `repo:` frontmatter or by `--plan {slug}`, so `repo` must be set whenever a repo exists.
