---
name: boss-git-commit
description: Use when the user asks to commit changes, create a commit, or says "commit". Stages files and creates a conventional commit with co-author trailer.
argument-hint: [optional message override]
allowed-tools: Bash(git *)
disable-model-invocation: true
---

# Boss Git Commit

Create a well-crafted conventional commit from the current working tree changes.

## Steps

### 1. Gather context (run in parallel)

```bash
# Working tree state — never use -uall
git status

# Full diff of what will be committed (staged + unstaged)
git diff
git diff --cached

# Recent commit style
git log --oneline -10
```

### 2. Decide what to stage

- Stage specific files by name. Prefer `git add <file>...` over `git add -A` or `git add .`.
- NEVER stage files that likely contain secrets (`.env`, credentials, tokens, private keys).
- If secrets are detected, warn the user and skip those files.
- If there are no changes at all (clean tree), tell the user and stop.

### 3. Write the commit message

Follow the **Conventional Commits** specification (`type(scope): description`).

**Type selection:**

| Type | When |
|------|------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Formatting, whitespace (no logic change) |
| `refactor` | Code restructuring (no behavior change) |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `ci` | CI/CD configuration |
| `chore` | Build, tooling, dependencies, config |
| `revert` | Reverting a previous commit |

**Rules:**
- Subject line: imperative mood, lowercase, no period, under 72 chars.
- If `$ARGUMENTS` is provided, use it as the subject (still apply conventional prefix if missing).
- Body: explain **why**, not what. The diff shows the what.
- Keep body to 1-3 sentences max. Omit if the subject is self-explanatory.
- Always end with the co-author trailer.

**Format (use HEREDOC for correct formatting):**

```bash
git commit -m "$(cat <<'EOF'
type(scope): imperative subject under 72 chars

Optional body explaining why this change was made.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 4. Verify

After committing, run `git status` to confirm the commit succeeded and the tree is clean (or only expected files remain).

### 5. Report

Tell the user:
- The commit hash and subject line
- What was staged
- Do NOT push unless explicitly asked

## Things to NEVER do

- Never amend a previous commit unless the user explicitly asks for `--amend`.
- Never push. Only commit locally.
- Never use `--no-verify` or skip hooks.
- Never run `git add -A` or `git add .` without reviewing what would be staged first.
- Never create an empty commit if there are no changes.
- Never include the line number prefix from Read tool output in commit messages.
