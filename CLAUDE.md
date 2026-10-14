# spec-workflow — instructions for working on this repo

This repo is a Claude Code plugin and a single-plugin marketplace. People install it with:

```
/plugin marketplace add Phongtlam/spec-workflow
/plugin install spec-workflow@phongtlam
```

Every push to `main` reaches real users the next time they update, so treat each change as a release.

## Layout

| Path | What it is |
|---|---|
| `.claude-plugin/plugin.json` | Plugin manifest. Holds the version. |
| `.claude-plugin/marketplace.json` | Marketplace manifest (`phongtlam`), source `./` |
| `skills/<name>/SKILL.md` | One folder per skill, invoked as `/spec-workflow:<name>` |
| `agents/build-agent.md` | TDD subagent used by `implement-plan`, invoked as `spec-workflow:build-agent` |
| `scripts/plan-hook.sh` | Shared hook script used by the skill hooks |
| `dev/check.sh` | Pre-commit checks. Not used by the plugin at runtime. |
| `README.md` | User-facing docs |

## Required on every change

Do all of these before committing. A change is not done until each applies or was checked and does not.

1. **Update `README.md`** for anything a user would notice: a new or renamed skill (skills table), a new flag, config variable, dependency, external tool, or platform requirement.
2. **Update `skills/setup/SKILL.md` whenever setup changes.** Setup is how users get a working install, so it must cover everything a user needs. Update it when you add or change:
   - a config variable → setup asks for it (or explains the default) and saves it to the `env` block of `settings.json`
   - a required plugin → setup offers to install it, adding its marketplace first if missing (Step 3)
   - an optional plugin, MCP server or CLI tool (like `gh`) → setup checks and reports it
   - anything that replaces an older mechanism → setup offers to clean up the leftover (Step 5)
   - the final summary block in Step 6, so it lists the new item
3. **Keep README and setup in agreement.** Install commands, variable names, defaults and the dependency list must match in both.
4. **Bump `version` in `.claude-plugin/plugin.json`** whenever anything under `skills/`, `agents/`, `scripts/` or `.claude-plugin/` changes. Users only get updates when the version changes. Use semver: patch for fixes, minor for new skills or settings, major for breaking changes such as renaming a variable or skill.
5. **Run `dev/check.sh`** and fix every failure.
6. **Test from GitHub after pushing** when install, setup or dependencies changed (see Testing).

## Design rules

These were deliberate decisions. Don't undo them without the owner's say-so.

- **No personal paths.** Nothing may mention `/Users/...` or a specific person's folders. All plan files live under `SPEC_WORKFLOW_ROOT`.
- **The plan root is required.** Skills never fall back to a default folder, the working directory or the repo. When `SPEC_WORKFLOW_ROOT` is unset, they invoke `Skill("spec-workflow:setup")` and continue with the path it reports. Keep the root-resolution text consistent across skills.
- **Don't name things after Obsidian.** The root can be any folder. Obsidian is only an example (and `obsidian-plan-rag` is a real MCP server name).
- **No global "active plan".** Several plans can run at once. A skill finds its plan by `--plan <name>`, else by matching the current git repo against `repo:` or `workspace:` in the plan frontmatter, and asks when several match. Never reintroduce a pointer file such as `~/.claude/active-plan-path`.
- **No shared state files.** Anything a run needs to remember (like the `implement-plan` wake-lock PID) goes in that plan's folder, never in `~/.claude` or another global path, or parallel plans overwrite each other.
- **Config lives in the `env` block of `~/.claude/settings.json`**, never a shell profile (the desktop app and IDE extensions don't read `.zshrc`). Current variables:
  - `SPEC_WORKFLOW_ROOT` — required plan root folder
  - `SPEC_WORKFLOW_REVIEW_SKILL` — review skill(s) for `run-qa`, comma-separated; default `pr-review-toolkit:review-pr`
- **Namespace every reference** to this plugin's skills and agent: `/spec-workflow:spec`, `Skill("spec-workflow:resume-plan")`, `subagent_type: "spec-workflow:build-agent"`.
- **Never silently substitute.** If a configured skill or plugin is missing, stop and say which one, with the fix.
- **Ask before changing anything of the user's**: settings, installed plugins, or plan statuses and archives.
- **Quote `argument-hint`** in frontmatter. A value that starts with `[` is otherwise read as a YAML list and breaks the whole frontmatter.
- **Hooks call `scripts/plan-hook.sh`** through `$CLAUDE_PLUGIN_ROOT`, falling back to the newest copy in `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache`. Hook output must stay silent when no plan matches.

## Dependencies

Keep this table, setup Step 3/3b and the README in sync. `dev/check.sh` verifies that every plugin a skill calls appears in setup and the README.

| Dependency | Used by | Kind | Install |
|---|---|---|---|
| planning-with-files | `spec`, `decompose`, `resume-plan` | required plugin | `claude plugin marketplace add OthmanAdi/planning-with-files`, then `claude plugin install planning-with-files@planning-with-files` |
| ralph-loop | `implement-plan`, `run-qa` | required plugin | `claude plugin marketplace add anthropics/claude-plugins-official`, then `claude plugin install ralph-loop@claude-plugins-official` |
| pr-review-toolkit | `run-qa` (default review skill) | plugin, when the default is used | `claude plugin install pr-review-toolkit@claude-plugins-official` |
| `simplify` skill | `run-qa` | built into Claude Code | `claude update` if missing |
| Explore subagent | `spec` | built into Claude Code | — |
| `git` | all plan skills, hooks | CLI, required | — |
| `gh` | `audit-plans` | CLI, optional (falls back to `git log`) | — |
| Atlassian, Figma, Playwright, obsidian-plan-rag | `spec`, `implement-plan` | MCP servers, optional | — |

A fresh Claude config has no `claude-plugins-official` marketplace, and installing from it fails with a misleading "not found in marketplace" error. Always add the marketplace first.

## Testing

`dev/check.sh` covers manifests, frontmatter, README and setup coverage, forbidden references, the hook script and the version bump.

To test what a new user gets, install from GitHub into a throwaway config so nothing local is involved:

```bash
export CLAUDE_CONFIG_DIR="$(mktemp -d)"
claude plugin marketplace add Phongtlam/spec-workflow
claude plugin install spec-workflow@phongtlam
claude plugin details spec-workflow@phongtlam
```

For an existing install, run `claude plugin marketplace update phongtlam` and then `claude plugin update spec-workflow@phongtlam`. The result should report the new version.

To run a skill live without installing it, load the downloaded copy with `--plugin-dir <path>` in a normal, logged-in session.
