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
| `setup` | One-time setup: picks your root folder, saves it to settings, installs the required plugins, and reports optional MCP servers. |

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

So you can run plans in different repos in parallel, or in one repo using `implement-plan`'s worktree option. The hooks that inject the current phase into each prompt use the same repo lookup.

## Platform notes

- `implement-plan` keeps a Mac awake with `caffeinate` during a run. Elsewhere it skips that step.
- Hook scripts need a POSIX shell, `git`, `sed` and `grep`.

## License

MIT
