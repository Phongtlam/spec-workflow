---
name: run-qa
description: "Run /simplify and then your configured review skill(s) in a Ralph loop, fixing issues each pass. The review skill comes from SPEC_WORKFLOW_REVIEW_SKILL (default: pr-review-toolkit:review-pr). Use as a final quality pass before opening a PR."
argument-hint: "[--max-iterations N] [--review <skill>[,<skill>...]]"
user-invocable: true
allowed-tools: Bash Read Edit Write Grep Glob Agent Skill
---

# Run QA — Simplify + Review Loop

Kicks off a Ralph loop that runs a cleanup pass and then one or more review passes, fixing issues at each step. `/spec-workflow:implement-plan` already reviews each phase; this is an optional whole-branch pass before a PR.

## Step 1: Resolve the Review Skills

Use the first of these that is set:

1. `--review <skill>[,<skill>...]` in `$ARGUMENTS`
2. `echo "$SPEC_WORKFLOW_REVIEW_SKILL"` — set in the `env` block of `~/.claude/settings.json`, next to `SPEC_WORKFLOW_ROOT`
3. The default: `pr-review-toolkit:review-pr`

Split on commas and trim spaces. Each entry is a skill name as it appears in the available skills list, e.g. `pr-review-toolkit:review-pr` or `code-review:code-review`. A leading `/` is allowed and ignored.

**Check every entry exists** in this session's available skills. If any is missing, stop and say which one, then:

- If it is the default, offer the fix: `claude plugin marketplace add anthropics/claude-plugins-official` (only if that marketplace is missing) and `claude plugin install pr-review-toolkit@claude-plugins-official`, then a restart. Or run `/spec-workflow:setup` to choose a different review skill.
- Otherwise, say the setting names a skill that is not installed and suggest installing it or changing `SPEC_WORKFLOW_REVIEW_SKILL`.

Do not silently substitute a different review skill.

## Step 2: Run the Loop

Parse `--max-iterations N` from `$ARGUMENTS` (default `3`).

Build the pass list: `/simplify`, then each review skill in order (as `/<skill>`). Invoke ralph-loop with no completion promise, so it runs all N iterations:

```
Skill("ralph-loop:ralph-loop", args="run /simplify, then /{review skill 1}, then /{review skill 2}. Fix all issues found in each pass. --max-iterations {N}")
```

With one review skill, the args are `run /simplify, then /{review skill}. Fix all issues found in each pass. --max-iterations {N}`.

Each iteration runs the full pipeline. Without `--completion-promise`, Ralph loop always runs exactly `--max-iterations` iterations.

## Step 3: Report

After the loop, summarize per pass: issues found, issues fixed, anything left unfixed with the reason. Name the review skills that ran.

## Critical Rule

When synthesizing findings from review agents into a summary, **never downgrade severity**. If a reviewer says "HIGH RISK", "important" or "blocking" with supporting evidence, treat it at that severity and fix it. Downgrading valid findings during synthesis causes real issues to slip through to PR review.
