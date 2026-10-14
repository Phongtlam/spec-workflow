# spec-workflow

A Claude Code plugin for spec-driven development. It researches and writes a spec, breaks it into phases, then builds each phase with a TDD subagent and parallel review. All plan files live in one root folder you choose, not in the repo.

```
/spec-workflow:spec  →  /spec-workflow:decompose  →  /spec-workflow:implement-plan
   spec.md                task_plan.md                  code, commits,
   findings.md            progress.md                   updated progress
```

| Skill | What it does |
|---|---|
| `spec` | Gathers context (Jira, Figma, Confluence, codebase), writes `spec.md` + `findings.md`, walks you through open questions one at a time, and waits for your approval. |
| `decompose` | Turns an approved spec into vertical-slice phases in `task_plan.md`. |
| `implement-plan` | Runs every phase unattended: a Sonnet build agent does RED-GREEN-REFACTOR per slice, then three parallel reviewers (correctness, architecture, security) check the result. Optional Figma visual comparison. |
| `resume-plan` | Lists plans in the root folder and reloads one into the session. |
| `plan-status` | Read-only "where am I?" view of the plan for the current repo, or any plan by name. |
| `audit-plans` | Checks open plans against GitHub, marks the ones whose PRs merged to main as completed (with your confirmation), writes delivery notes, and archives them. |
| `run-qa` | Optional final pass before a PR: `/simplify`, then your chosen review skill(s), fixing issues each round. Repeats 3 times by default. |
| `setup` | One-time setup: picks your root folder and review skill, saves them to settings, installs the required plugins, and reports optional MCP servers. |

## Install

```
/plugin marketplace add Phongtlam/spec-workflow
/plugin install spec-workflow@phongtlam
```

Then run:

```
/spec-workflow:setup
```

Setup handles everything below for you and asks before changing anything. Restart Claude Code when it finishes. The rest of this section explains what it does, in case you'd rather do it by hand.

### Required plugins

`decompose` and `implement-plan` call skills from two other plugins:

```
/plugin marketplace add OthmanAdi/planning-with-files
/plugin install planning-with-files@planning-with-files
/plugin marketplace add anthropics/claude-plugins-official
/plugin install ralph-loop@claude-plugins-official
```

### Choose a root folder (required)

Every plan lives under one folder you pick. Any directory works: `~/spec-workflow`, a synced Dropbox or iCloud folder, or an Obsidian vault if you want to browse plans there. Plans go in `$SPEC_WORKFLOW_ROOT/plans/<plan-slug>/`.

Set it in the `env` block of `~/.claude/settings.json`:

```json
{
  "env": {
    "SPEC_WORKFLOW_ROOT": "/absolute/path/to/your/folder"
  }
}
```

The skills won't run without it. If it's unset when you run one, it starts `/spec-workflow:setup` first. Restart Claude Code afterwards so the plan-context hooks see it.

Use `settings.json` rather than your shell profile: the desktop app and IDE extensions don't read `.zshrc`.

### Choose a review skill for run-qa (optional)

`/spec-workflow:run-qa` runs `/simplify` and then a review skill. Pick the review skill with `SPEC_WORKFLOW_REVIEW_SKILL`, in the same `env` block:

```json
{
  "env": {
    "SPEC_WORKFLOW_ROOT": "/absolute/path/to/your/folder",
    "SPEC_WORKFLOW_REVIEW_SKILL": "code-review:code-review"
  }
}
```

- **Unset:** uses `pr-review-toolkit:review-pr`. Install it with `/plugin install pr-review-toolkit@claude-plugins-official`.
- **Any installed skill:** use the name as it appears in your skills list, e.g. `code-review:code-review` or one of your own.
- **Several:** separate them with commas, e.g. `pr-review-toolkit:review-pr,code-review:code-review`. They run in that order after `/simplify`.
- **For one run:** `/spec-workflow:run-qa --review <skill>` overrides the setting.

If a named skill isn't installed, run-qa stops and tells you, rather than quietly using another one.

### Optional MCP servers

Each one is used when present and skipped when not:

- **Atlassian** for `--jira` and `--confluence` context
- **Figma** for design values and visual comparison
- **Playwright** for implementation screenshots
- **obsidian-plan-rag** for pulling lessons from your past plans

## Running several plans at once

There is no global "active plan". A skill picks its plan in this order:

1. `--plan <name>` (partial match on the folder slug)
2. otherwise, the open plan whose `repo:` (or `workspace:`, for worktrees) matches the git repo the session is in
3. if more than one matches, it asks

So you can run plans in different repos in parallel, or in one repo using `implement-plan`'s worktree option. When another open plan is already using a repo's main checkout, `implement-plan` recommends a worktree, since two plans sharing one checkout would switch branches under each other. The hooks that inject the current phase into each prompt use the same repo lookup.

## Platform notes

- `implement-plan` keeps a Mac awake with `caffeinate` during a run. Elsewhere it skips that step.
- Hook scripts need a POSIX shell, `git`, `sed` and `grep`.
- `audit-plans` uses the GitHub CLI (`gh`) to verify merged PRs. Without it, it falls back to `git log`.

## License

MIT
