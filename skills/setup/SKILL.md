---
name: setup
description: Set up spec-workflow — choose the plan root folder (SPEC_WORKFLOW_ROOT), save it to Claude settings, check required plugins (planning-with-files, ralph-loop), and report optional MCP servers. Run once after installing, or when another spec-workflow skill reports the root is not configured.
argument-hint: "[root-folder-path]"
user-invocable: true
allowed-tools: Read Write Edit Bash AskUserQuestion
---

# Setup — Configure spec-workflow

Gets a new user from "plugin installed" to "ready to run `/spec-workflow:spec`". Safe to re-run: each step checks the current state first and only changes what is missing. Ask before every change to the user's settings or plugins.

`SETTINGS` = `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` (resolve the path with `echo`).

---

## Step 1: Plan Root Folder

Every plan lives under one root folder, `SPEC_WORKFLOW_ROOT`. Plans go in `$SPEC_WORKFLOW_ROOT/plans/<plan-slug>/`.

1. Find the current value, in order:
   - a path passed in `$ARGUMENTS`
   - `echo "$SPEC_WORKFLOW_ROOT"` (already set for this session)
   - the `env.SPEC_WORKFLOW_ROOT` key in `SETTINGS` (set, but Claude Code was not restarted since)
2. **Already set and the directory exists** → report it and keep it. Do not ask.
3. **Not set** → ask with AskUserQuestion: "Where should spec-workflow keep your plans?" Options:
   - `~/spec-workflow` (Recommended) — a plain folder
   - the value of `$OBSIDIAN_VAULT_PATH`, only if that variable is set (label it "Your Obsidian vault")
   - the user can type any other absolute path, such as an Obsidian vault or a synced folder
4. Expand `~` to an absolute path. If the folder does not exist, create it. Create its `plans/` subfolder.
5. **Set but the directory is missing** → ask whether to create it or choose a different folder.

## Step 2: Save to Settings

Skip if `SETTINGS` already has `env.SPEC_WORKFLOW_ROOT` equal to the chosen path.

Read `SETTINGS` (it may not exist). Add or update `"SPEC_WORKFLOW_ROOT": "<absolute path>"` inside its `env` object, preserving every other key and value exactly. If the file does not exist, create it as `{ "env": { "SPEC_WORKFLOW_ROOT": "<absolute path>" } }`. Confirm the result is valid JSON (`python3 -m json.tool "$SETTINGS" >/dev/null` if python3 exists).

Use `settings.json`, never a shell profile: the desktop app and IDE extensions do not read `.zshrc`.

## Step 3: Required Plugins

`decompose` uses planning-with-files; `implement-plan` uses ralph-loop for recovery. Check what is installed:

```bash
claude plugin list 2>/dev/null
```

If that command fails, read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json` instead.

For each missing plugin, ask once (one AskUserQuestion listing all missing plugins) whether to install them now. On yes, check `claude plugin marketplace list` and add each marketplace that is not listed, then install:

| Plugin | Marketplace to add if missing | Install |
|---|---|---|
| planning-with-files | `claude plugin marketplace add OthmanAdi/planning-with-files` | `claude plugin install planning-with-files@planning-with-files` |
| ralph-loop | `claude plugin marketplace add anthropics/claude-plugins-official` | `claude plugin install ralph-loop@claude-plugins-official` |

Always add the marketplace first when it is missing: a fresh Claude config may not include `claude-plugins-official`, and the install error then says "not found in marketplace" rather than naming the missing marketplace.

On no, print the commands so the user can run them later. Report failures with their output; do not retry blindly.

## Step 4: Optional MCP Servers

Look at the tools available in this session and report which of these are connected. Do not install anything.

| Server | Used for | Look for tools named like |
|---|---|---|
| Atlassian | `--jira`, `--confluence` context in `/spec-workflow:spec` | `getJiraIssue`, `getConfluencePage` |
| Figma | design values and visual comparison | `get_design_context`, `get_screenshot` |
| Playwright | implementation screenshots | `browser_navigate`, `browser_take_screenshot` |
| obsidian-plan-rag | lessons from past plans | `similar_plans`, `repo_memory` |

Everything works without them; each skill skips what is missing.

## Step 5: Leftovers from Older Setups

- If `~/.claude/active-plan-path` exists: it is no longer used (plans are found by repo or `--plan`). Ask whether to delete it.
- If `OBSIDIAN_VAULT_PATH` is set and was not chosen as the root, mention that spec-workflow no longer reads it.

## Step 6: Verify and Summarize

1. Confirm the root is writable: `touch "$ROOT/plans/.spec-workflow-check" && rm "$ROOT/plans/.spec-workflow-check"`.
2. Confirm `git` is installed (`git --version`).
3. Check the GitHub CLI with `gh auth status`. It is optional: only `/spec-workflow:audit-plans` uses it to verify merged PRs. If it is missing or logged out, say so and continue.
4. Present:

```
spec-workflow is set up.

Plan root:   {path}  (saved to {SETTINGS})
Plugins:     planning-with-files {✓|missing}, ralph-loop {✓|missing}
Optional:    Atlassian {✓|–}, Figma {✓|–}, Playwright {✓|–}, plan RAG {✓|–}, gh {✓|–}

Next: restart Claude Code so hooks see SPEC_WORKFLOW_ROOT, then run
/spec-workflow:spec <plan-name> from inside the repo you want to work on.
```

Skip the restart line if the root was already set in this session's environment before setup ran.

When another spec-workflow skill invoked this one, end with the root path on its own line (`SPEC_WORKFLOW_ROOT={path}`) so the caller can continue with it in this session.
