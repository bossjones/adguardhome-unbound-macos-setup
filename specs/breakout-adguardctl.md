# Plan: Break `adguardctl` out into its own repo (`bossjones/adguardctl`)

## Context

`adguardctl` — an async-first Python CLI for managing an AdGuard Home instance — currently lives as a subproject at `tools/adguardctl/` inside the `adguardhome-unbound-macos-setup` repo. Its own README already says *"This lives under `tools/adguardctl` for now and will be split into its own repository later."* This plan performs that split: create a public GitHub repo `bossjones/adguardctl`, initialize it with a README, then port the existing project onto a feature branch. The tool is essentially self-contained (no imports or scripts reach outside `tools/adguardctl/`), so extraction is mostly mechanical: copy the tracked files, fix three parent-repo references, and re-home the CI workflow at the repo root.

## Objective

A public `github.com/bossjones/adguardctl` repo whose `main` has an initial README commit, with a feature branch containing the fully-ported project (52 tracked files), a working root-level CI workflow, an MIT LICENSE, the design doc copied in, a merged `.gitignore` (that ignores the Claude agent-hook `logs/` output), and all parent-repo references fixed — cloned locally at `~/dev/bossjones/adguardctl`, ready to open a PR.

## Solution Approach

1. Create the remote repo public + `--add-readme` via `gh` (gives `main` an initial README commit).
2. Clone to `~/dev/bossjones/adguardctl`, create feature branch `feature/port-adguardctl`.
3. Copy the **git-tracked** payload from `tools/adguardctl/` using `git ls-files` (avoids dragging `.venv/`, caches, `logs/`, `__pycache__`, `.claude/data/`, and other untracked runtime junk).
4. Fix the three parent-repo references (README link, README prose, CI workflow paths).
5. Add the extraction-specific files: MIT LICENSE, merged `.gitignore`, copied design doc.
6. Commit on the branch, push, open a PR.

Extraction is a **fresh copy** (no git history port) — matches the user's "initialize with README.md then begin porting it over" framing.

## Relevant Files

Source (read-only, in current repo `adguardhome-unbound-macos-setup`):
- `tools/adguardctl/**` — the 52-file payload. Enumerate with `git ls-files tools/adguardctl`.
- `tools/adguardctl/README.md` — has the breaking link (line 101) and stale prose (lines 12-13, 18).
- `tools/adguardctl/.gitignore` — the clean, project-scoped base for the merged ignore.
- `.gitignore` (repo root) — source of the Claude-hook / `logs/` / macOS ignore entries to merge in.
- `.github/workflows/adguardctl.yml` — CI to re-home at the new repo root (drop `working-directory` + `paths:` filters).
- `specs/adguardctl.md` — 6.5 KB design doc to copy into the new repo (fixes the README link).

### New files (in `~/dev/bossjones/adguardctl`)
- `LICENSE` — MIT, author "Malcolm Jones", year 2026.
- `.gitignore` — merged (local project ignores + Claude-hook/logs/macOS entries).
- `docs/design.md` — copy of `specs/adguardctl.md`.
- `.github/workflows/ci.yml` — re-homed workflow (renamed from `adguardctl.yml`).
- Everything else copied verbatim from `tools/adguardctl/`.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom. Steps run from the current repo `/Users/bossjones/dev/bossjones/adguardhome-unbound-macos-setup` unless noted.

### 1. Create the remote repo
- Confirm `gh auth status` shows account `bossjones` with `repo` + `workflow` scopes (already verified: it does — `workflow` scope is required to push the `.github/workflows/` file).
- `gh repo create bossjones/adguardctl --public --description "Async-first CLI for managing an AdGuard Home instance" --add-readme`
- `--add-readme` seeds `main` with an initial `README.md` commit, satisfying "initialize it with a README.md".

### 2. Clone locally and branch
- `git clone git@github.com:bossjones/adguardctl.git ~/dev/bossjones/adguardctl`
- `cd ~/dev/bossjones/adguardctl && git switch -c feature/port-adguardctl`

### 3. Copy the tracked payload
- From the source repo, enumerate tracked files: `git -C <source-repo> ls-files tools/adguardctl`.
- Copy each into `~/dev/bossjones/adguardctl`, **stripping the `tools/adguardctl/` prefix** so files land at the new repo root (e.g. `tools/adguardctl/src/adguardctl/api.py` → `~/dev/bossjones/adguardctl/src/adguardctl/api.py`).
- Suggested mechanism (preserves subdirs, copies only tracked files):
  ```bash
  cd <source-repo>
  git ls-files tools/adguardctl | while read -r f; do
    dest="$HOME/dev/bossjones/adguardctl/${f#tools/adguardctl/}"
    mkdir -p "$(dirname "$dest")"
    cp "$f" "$dest"
  done
  ```
- This will overwrite the seeded `README.md` from Step 1 with the real one (intended).
- The copied `.gitignore` (from `tools/adguardctl/.gitignore`) is the base for Step 6; leave it for now.
- **Preserve the uv src-layout.** This is a `uv_build` project with a `src/` layout — the package lives at `src/adguardctl/`, declared implicitly by uv's build backend. The prefix-strip lands `tools/adguardctl/src/adguardctl/**` at `~/dev/bossjones/adguardctl/src/adguardctl/**`, i.e. the package stays under `src/`, NOT hoisted to the repo root. `pyproject.toml`, `uv.lock`, `.python-version`, `justfile`, and `tests/` land at the repo root alongside `src/`. Do not flatten `src/`.
- Verify the src-layout after copy:
  ```bash
  cd ~/dev/bossjones/adguardctl
  test -f src/adguardctl/__init__.py && test -f src/adguardctl/cli/app.py \
    && test -f pyproject.toml && test -f uv.lock && test -f .python-version \
    && test ! -d adguardctl && echo "src-layout OK"
  ```
  (`test ! -d adguardctl` guards against accidentally hoisting the package to the root.)
- Verify NO runtime junk came along: `.venv/`, `.coverage`, `.pytest_cache/`, `.ruff_cache/`, `.claude/`, `logs/`, `__pycache__/`, stray `docker/adguardhome/logs/`, `tests/fixtures/logs/` must be absent (using `git ls-files` guarantees this, but confirm).

### 4. Fix parent-repo references in README.md
In `~/dev/bossjones/adguardctl/README.md`:
- Remove the blockquote at lines 12-13: *"This lives under `tools/adguardctl` for now and will be split into its own repository later."*
- Line 18: delete `cd tools/adguardctl` (the reader is already at the repo root after cloning).
- Line 101: change `See [\`specs/adguardctl.md\`](../../specs/adguardctl.md)` → `See [\`docs/design.md\`](docs/design.md)` (points at the copied doc from Step 5).

### 5. Copy the design doc
- Copy `<source-repo>/specs/adguardctl.md` → `~/dev/bossjones/adguardctl/docs/design.md`.
- (Matches the fixed README link. `docs/design.md` chosen over `specs/` since it is repo-level design documentation, not a project-management spec.)

### 6. Merge the .gitignore
- Base: the copied `tools/adguardctl/.gitignore` (Python/uv ignores, tool caches, `docker/adguardhome/work/`, `.claude/data/`).
- Append a curated block from the source repo's **root** `.gitignore` covering the Claude-agent-hook and environment noise the user explicitly wants ignored — de-duplicated, and WITHOUT the unrelated other-project fragments (screencropnet, task-manager, lunar-claude, datasets, notebooks). Specifically add:
  ```gitignore
  # macOS / editors
  .DS_Store

  # Claude Code agent-hook output (session data, TTS, hook logs)
  .claude/settings.local.json
  logs/
  docker/adguardhome/logs/
  tests/fixtures/logs/

  # Local tooling / MCP
  .mcp.json
  .mcp.json.backup
  mise.local.toml
  ```
- Rationale: the `logs/` dir and `docker/adguardhome/logs/` + `tests/fixtures/logs/` are currently only untracked because the *parent* root `.gitignore` covered them; the standalone repo must ignore them itself. The local `.gitignore` already handles `.claude/data/`.

### 7. Re-home the CI workflow
- Move copied `.github/workflows/adguardctl.yml` → `.github/workflows/ci.yml` in the new repo.
- Edit it to work at the repo root:
  - Delete the `paths:` filters under both `push` and `pull_request` (lines 6-8, 11-13) — everything in the standalone repo is adguardctl, so path-filtering no longer makes sense. Keep `branches: [main]`.
  - Delete the `defaults: run: working-directory: tools/adguardctl` block (lines 18-20).
  - Optionally rename the top-level `name: adguardctl` → `name: CI`.
  - Everything else (uv sync, ruff, ty, codespell, pytest, the compose integration job) stays — all commands already run relative to the working dir, which is now the repo root.

### 8. Add MIT LICENSE
- Create `~/dev/bossjones/adguardctl/LICENSE` with the standard MIT license text, `Copyright (c) 2026 Malcolm Jones`.

### 9. Local validation (before committing)
- `cd ~/dev/bossjones/adguardctl`
- `uv sync` — recreates `.venv` from the copied `uv.lock` (proves the lockfile + manifest are intact).
- `just check` (or the underlying `uv run ruff format --check . && uv run ruff check . && uv run ty check && uv run pytest -m "not slow"`) — the same gate CI runs.
- Confirm `uv run adguardctl --help` prints the command groups.

### 10. Commit, push, open PR
- `git add -A`
- Commit (conventional): `feat: import adguardctl from adguardhome-unbound-macos-setup` with a body noting the source and the reference fixes. Include the standard Co-Authored-By / Claude-Session trailers.
- `git push -u origin feature/port-adguardctl`
- `gh pr create --repo bossjones/adguardctl --base main --head feature/port-adguardctl --title "Port adguardctl into its own repo" --body "..."` (body describes the extraction; include the 🤖 Generated-with footer).

## Testing Strategy

The port is verified by reproducing the project's own CI gate locally in the new repo (Step 9):
- **`uv sync`** proves `pyproject.toml` + `uv.lock` + `.python-version` survived the copy and resolve standalone.
- **`ruff format --check` / `ruff check` / `ty check` / `codespell`** prove no source file was corrupted or partially copied.
- **`pytest -m "not slow"`** (mocked-HTTP unit tests, `fail_under = 85` coverage gate) proves the package imports and behaves — this is the strongest single signal that extraction is clean, since all imports are intra-package.
- **`adguardctl --help`** smoke-tests the installed entrypoint (`adguardctl.cli.app:main`).
- After push, **GitHub Actions** re-runs the same gate on Ubuntu, confirming the re-homed workflow triggers and passes at the repo root. Integration tests (compose-based, `-m integration`) remain manual/scheduled as before.

## Acceptance Criteria

- `gh repo view bossjones/adguardctl` shows a **public** repo; `main` has an initial README commit.
- Repo cloned at `~/dev/bossjones/adguardctl`; branch `feature/port-adguardctl` checked out.
- All 52 tracked files from `tools/adguardctl/` present at the repo root (prefix stripped); no `.venv/`, caches, `logs/`, `__pycache__/`, or `.claude/data/` committed.
- **uv src-layout preserved:** the package sits at `src/adguardctl/` (not hoisted to the repo root), with `pyproject.toml`/`uv.lock`/`.python-version`/`justfile`/`tests/` at the root — and `uv sync` builds it without a "package not found" / build-backend error.
- `README.md` has no `tools/adguardctl` prose, no `cd tools/adguardctl`, and its design link resolves to `docs/design.md` (which exists).
- `.github/workflows/ci.yml` exists at the repo root with no `working-directory`/`paths` filters; no leftover `.github/workflows/adguardctl.yml`.
- `LICENSE` (MIT, Malcolm Jones, 2026) and merged `.gitignore` (ignoring `logs/`, `.claude/`, `.DS_Store`, etc.) present.
- `uv sync` and `just check` pass locally; `uv run adguardctl --help` works.
- A PR is open against `bossjones/adguardctl:main`, and its CI run is green (or running).

## Validation Commands

Run in the new repo `~/dev/bossjones/adguardctl` unless noted:
- `gh repo view bossjones/adguardctl --json visibility,defaultBranchRef` — confirm public + main exists.
- `git -C <source-repo> ls-files tools/adguardctl | wc -l` vs. `git ls-files | grep -vE '^(LICENSE|docs/design.md)$' | wc -l` — payload count sanity check.
- `test -f docs/design.md && grep -q 'docs/design.md' README.md && ! grep -q 'tools/adguardctl' README.md` — reference fixes applied.
- `test -f .github/workflows/ci.yml && ! test -f .github/workflows/adguardctl.yml && ! grep -q 'working-directory' .github/workflows/ci.yml` — workflow re-homed.
- `grep -q 'logs/' .gitignore && grep -q 'MIT' LICENSE` — gitignore + license present.
- `uv sync` — lockfile resolves.
- `uv run ruff format --check . && uv run ruff check . && uv run ty check && uv run codespell src tests && uv run pytest -m "not slow"` — full CI gate.
- `uv run adguardctl --help` — entrypoint smoke test.
- `gh pr view --repo bossjones/adguardctl` — PR exists; `gh run list --repo bossjones/adguardctl` — CI status.

## Notes

- **Decisions confirmed with user:** merge root + local `.gitignore` (keep the Claude-hook `logs/` ignores); MIT license; copy the design doc in and fix the link.
- **Auth:** `gh` is authenticated as `bossjones` with `repo` + `workflow` scopes — sufficient to create the repo and push the workflow file. Git protocol is SSH.
- **Fresh copy, no history:** extraction does not preserve `tools/adguardctl/` git history (matches the user's "initialize then port" framing). If history preservation is later desired, `git subtree split` / `git filter-repo` would be the alternative — out of scope here.
- **No changes to the source repo** beyond writing this plan. Removing `tools/adguardctl/` from the original repo (and updating its CLAUDE.md / workflows) is intentionally NOT part of this plan — that is a follow-up decommission once the new repo is verified.
- **`uv` and `just`** must be installed locally for Step 9 validation (they already are — this project was developed with them).
