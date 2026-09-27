#!/usr/bin/env bash
# new-sdd-workspace.sh — scaffold a spec-driven (BMAD) two-repo workspace.
#
#   <base>-workspace/            (NOT a git repo)
#   ├── CLAUDE.md -> <product>-spec/WORKSPACE.md
#   ├── _bmad, _bmad-output, .claude/skills/*  -> symlinks into the spec repo
#   ├── <product>-spec/          git repo: BMAD install + specs + BOOTSTRAP.md
#   └── <product>/               git repo: the code
#
# Both repos are created on GitHub with `gh repo create --source=. --push`,
# i.e. from the local commit into an EMPTY remote (no README/LICENSE clash).
#
# Usage:
#   ./new-sdd-workspace.sh                       # fully interactive
#   ./new-sdd-workspace.sh yahoo-mail-plugin     # asks only what's missing
#
# Options:
#   --owner <user|org>     GitHub owner (default: your gh login)
#   --public | --private   repo visibility (default: ask; private if -y)
#   --dir <path>           parent folder for the workspace (default: current dir)
#   --workspace <name>     workspace folder name (default: derived from product)
#   --description <text>   one-line product description for READMEs / GitHub
#   --no-github            do everything locally, skip `gh repo create`
#   -y, --yes              accept defaults, no prompts
#   -h, --help
#
# Needs: git, gh (logged in, unless --no-github), node >= 20.12 + npx,
#        python3 >= 3.10 and uv (used by BMAD's helper scripts).
# Works with macOS's bash 3.2.

set -euo pipefail

# ─── output helpers ──────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=; G=; Y=; R=; N=; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
trap 'rc=$?; [ $rc -ne 0 ] && printf "\n%sStopped (exit %s). Nothing was deleted; fix the problem and re-run, or remove the workspace folder to start over.%s\n" "$R" "$rc" "$N" >&2' EXIT

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── arguments ───────────────────────────────────────────────────────────────
PRODUCT="" OWNER="" VISIBILITY="" PARENT_DIR="$PWD" WORKSPACE="" DESCRIPTION="" USE_GITHUB=1 ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --owner)       OWNER="${2:?--owner needs a value}"; shift 2 ;;
    --public)      VISIBILITY=public; shift ;;
    --private)     VISIBILITY=private; shift ;;
    --dir)         PARENT_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --workspace)   WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
    --description) DESCRIPTION="${2:?--description needs a value}"; shift 2 ;;
    --no-github)   USE_GITHUB=0; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     usage ;;
    -*)            die "Unknown option: $1 (see --help)" ;;
    *)             [ -z "$PRODUCT" ] || die "Only one product name allowed"; PRODUCT="$1"; shift ;;
  esac
done

ask() {  # ask <var> <prompt> <default>
  local __v="$1" __p="$2" __d="${3:-}" __a=""
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then __a="$__d"
  else read -r -p "  $__p${__d:+ [$__d]}: " __a || true; __a="${__a:-$__d}"; fi
  eval "$__v=\$__a"
}
valid_name() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]*[a-z0-9]$'; }

# ─── 1. preflight ────────────────────────────────────────────────────────────
step "Checking tools"
command -v git >/dev/null || die "git is not installed"
ok "git $(git --version | awk '{print $3}')"

GIT_NAME=$(git config --global user.name || true); GIT_EMAIL=$(git config --global user.email || true)
[ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ] || die "Set your git identity first:
    git config --global user.name  \"Your Name\"
    git config --global user.email \"<id>+<login>@users.noreply.github.com\""
ok "git identity: $GIT_NAME <$GIT_EMAIL>"

command -v node >/dev/null || die "Node.js 20.12+ is required (BMAD installer)"
node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>20||(a===20&&b>=12)?0:1)' \
  || die "Node.js 20.12+ is required, found $(node --version)"
command -v npx >/dev/null || die "npx is missing (it ships with Node.js)"
ok "node $(node --version)"

if command -v python3 >/dev/null && python3 -c 'import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)'; then ok "python3 $(python3 -c 'import platform;print(platform.python_version())')"
else warn "python3 3.10+ not found. BMAD's helper scripts need it; install it before using the skills"; fi
command -v uv >/dev/null && ok "uv $(uv --version | awk '{print $2}')" || warn "uv not found. BMAD's helper scripts need it; install it before using the skills"

if [ "$USE_GITHUB" = 1 ]; then
  command -v gh >/dev/null || die "gh (GitHub CLI) is required, or pass --no-github"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
  GH_LOGIN=$(gh api user --jq .login)
  ok "gh logged in as $GH_LOGIN"
fi

# ─── 2. names ────────────────────────────────────────────────────────────────
step "Project details"
[ -n "$PRODUCT" ] || ask PRODUCT "Product name (lowercase, dashes; e.g. yahoo-mail-plugin)" ""
[ -n "$PRODUCT" ] || die "A product name is required"
valid_name "$PRODUCT" || die "'$PRODUCT' is not valid: use lowercase letters, digits and dashes (e.g. yahoo-mail-plugin)"

case "$PRODUCT" in *-plugin|*-app|*-service|*-api|*-cli|*-server) BASE="${PRODUCT%-*}" ;; *) BASE="$PRODUCT" ;; esac
[ -n "$WORKSPACE" ] || ask WORKSPACE "Workspace folder name" "$BASE-workspace"
valid_name "$WORKSPACE" || die "Workspace name '$WORKSPACE' is not valid"
SPEC="$PRODUCT-spec"
[ "$WORKSPACE" != "$PRODUCT" ] && [ "$WORKSPACE" != "$SPEC" ] || die "The workspace name must differ from the repo names"

[ -n "$DESCRIPTION" ] || ask DESCRIPTION "One-line description" "$PRODUCT"

if [ "$USE_GITHUB" = 1 ]; then
  [ -n "$OWNER" ] || ask OWNER "GitHub owner (user or org)" "$GH_LOGIN"
  [ -n "$VISIBILITY" ] || ask VISIBILITY "Visibility (public/private)" "private"
  case "$VISIBILITY" in public|private) ;; *) die "Visibility must be public or private" ;; esac
else
  OWNER="${OWNER:-OWNER}"; VISIBILITY="${VISIBILITY:-private}"
fi

mkdir -p "$PARENT_DIR"; PARENT_DIR=$(cd "$PARENT_DIR" && pwd)
WS="$PARENT_DIR/$WORKSPACE"; SPEC_DIR="$WS/$SPEC"; CODE_DIR="$WS/$PRODUCT"
YEAR=$(date +%Y)

[ ! -e "$WS" ] || die "$WS already exists. Pick another name or remove it"
if [ "$USE_GITHUB" = 1 ]; then
  for r in "$SPEC" "$PRODUCT"; do
    if gh repo view "$OWNER/$r" >/dev/null 2>&1; then die "GitHub repo $OWNER/$r already exists"; fi
  done
fi

cat <<EOF

  Workspace : $WS   (not a repo)
  Spec repo : $SPEC_DIR
  Code repo : $CODE_DIR
  GitHub    : $([ "$USE_GITHUB" = 1 ] && echo "$OWNER/$SPEC, $OWNER/$PRODUCT ($VISIBILITY)" || echo "skipped (--no-github)")
  License   : MIT, © $YEAR $GIT_NAME
EOF
if [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
  ask GO "Create all of this? (y/n)" "y"; case "$GO" in y|Y|yes) ;; *) trap - EXIT; echo "Cancelled."; exit 0 ;; esac
fi

# fill placeholders in a file written from a quoted heredoc (names are [a-z0-9-] only)
render() {
  sed -e "s|__PRODUCT__|$PRODUCT|g" -e "s|__SPEC__|$SPEC|g" -e "s|__WORKSPACE__|$WORKSPACE|g" \
      -e "s|__OWNER__|$OWNER|g" -e "s|__YEAR__|$YEAR|g" \
      -e "s|__DESCRIPTION__|$(printf '%s' "$DESCRIPTION" | sed 's/[|&\\]/\\&/g')|g" \
      -e "s|__HOLDER__|$(printf '%s' "$GIT_NAME" | sed 's/[|&\\]/\\&/g')|g"
}
write() { mkdir -p "$(dirname "$1")"; render > "$1"; }   # write <path>  (content on stdin)

# ─── 3. folders + BMAD ───────────────────────────────────────────────────────
step "Creating folders"
mkdir -p "$SPEC_DIR" "$CODE_DIR"
ok "$WORKSPACE/{$SPEC,$PRODUCT}"

step "Installing BMAD Method into $SPEC (this takes a minute)"
( cd "$SPEC_DIR" && npx -y bmad-method install --directory "$SPEC_DIR" --modules bmm --tools claude-code \
    --user-name "$GIT_NAME" --communication-language English --document-output-language English \
    --output-folder _bmad-output --yes ) || {
  warn "Non-interactive install failed. Falling back to the interactive installer:"
  warn "choose ONLY 'BMad Method', tool 'Claude Code', output folder '_bmad-output', Express Setup"
  ( cd "$SPEC_DIR" && npx -y bmad-method install )
}
# known installer bug: a literal {output_folder} directory can appear with --yes
[ -d "$SPEC_DIR/{output_folder}" ] && rmdir "$SPEC_DIR/{output_folder}" 2>/dev/null || true
[ -d "$SPEC_DIR/_bmad" ] || die "BMAD did not install: $SPEC_DIR/_bmad is missing"
[ -d "$SPEC_DIR/.claude/skills" ] || die "BMAD installed no Claude Code skills (.claude/skills missing)"
ok "BMAD installed: $(ls "$SPEC_DIR/.claude/skills" | grep -c '^bmad-') skills"

step "Configuring BMAD"
# project name: fix the generated files now, and pin it where upgrades can't undo it
for f in _bmad/config.toml _bmad/core/config.yaml _bmad/bmm/config.yaml; do
  p="$SPEC_DIR/$f"; [ -f "$p" ] || continue
  sed -E -e "s|^(project_name *= *)\".*\"|\1\"$PRODUCT\"|" -e "s|^(project_name: *).*|\1$PRODUCT|" "$p" > "$p.tmp" && mv "$p.tmp" "$p"
done
mkdir -p "$SPEC_DIR/_bmad/custom"
touch "$SPEC_DIR/_bmad/custom/config.toml"
grep -q '^project_name' "$SPEC_DIR/_bmad/custom/config.toml" || cat >> "$SPEC_DIR/_bmad/custom/config.toml" <<EOF

# Pinned so the installer can't reintroduce an old answer on upgrade.
[core]
project_name = "$PRODUCT"
EOF
ok "project_name = $PRODUCT (pinned in _bmad/custom/config.toml)"

# personal config -> committed template
if [ -f "$SPEC_DIR/_bmad/config.user.toml" ]; then
  { printf '# TEMPLATE — copy to _bmad/config.user.toml and set your own values.\n# (Committed on purpose; the real config.user.toml is git-ignored.)\n'
    sed -E -e 's|^(user_name *= *).*|\1"Your Name"|' "$SPEC_DIR/_bmad/config.user.toml"; } > "$SPEC_DIR/_bmad/config.user.toml.example"
else
  write "$SPEC_DIR/_bmad/config.user.toml.example" <<'EOF'
# TEMPLATE — copy to _bmad/config.user.toml and set your own values.
# (Committed on purpose; the real config.user.toml is git-ignored.)

[core]
user_name = "Your Name"
communication_language = "English"

[modules.bmm]
user_skill_level = "intermediate"
EOF
fi
ok "_bmad/config.user.toml.example"

# ─── 4. spec repo files ──────────────────────────────────────────────────────
step "Writing spec repo files"
mkdir -p "$SPEC_DIR/_bmad-output"; touch "$SPEC_DIR/_bmad-output/.gitkeep"

write "$SPEC_DIR/.gitignore" <<'EOF'
# Personal BMAD settings (each developer creates their own from the .example)
_bmad/config.user.toml
_bmad/custom/config.user.toml

# Secrets
.env
.env.*
!.env.example

# OS / editor
.DS_Store
.idea/
.vscode/
EOF

write "$SPEC_DIR/WORKSPACE.md" <<'EOF'
# __WORKSPACE__

This folder is NOT a repo. It holds two sibling repos:
- `__SPEC__/`: BMAD install and all specs (`_bmad-output/`). Source of truth for decisions.
- `__PRODUCT__/`: the product code. All code goes here, never in the spec repo.

Rules:
- Specs first: no code without a story in `__SPEC__/_bmad-output/`.
- A change to behaviour updates the spec in the same session.
- Commit to each repo separately; reference the story ID in the code commit.
- Commit author is the human who owns the work; AI goes in a `Co-Authored-By:` trailer only.
- Secrets never go into git, specs, issues or chat.
EOF

write "$SPEC_DIR/scripts/link-workspace.sh" <<'EOF'
#!/usr/bin/env bash
# Wire the workspace folder to the spec repo with symlinks. Idempotent.
# Run from the workspace folder (the parent of this repo).
set -euo pipefail

SPEC="$(basename "$(cd "$(dirname "$0")/.." && pwd)")"
[ -d "$SPEC/_bmad" ] || { echo "Run from the workspace folder (can't find $SPEC/_bmad)"; exit 1; }

link() {  # link <target> <linkname>
  if [ -e "$2" ] && [ ! -L "$2" ]; then
    echo "SKIP $2 is a real file/folder, not a link — inspect it, then replace it by hand"; return 1
  fi
  ln -sfn "$1" "$2" && echo "ok   $2 -> $1"
}

status=0
link "$SPEC/WORKSPACE.md" CLAUDE.md     || status=1
link "$SPEC/_bmad"        _bmad         || status=1
link "$SPEC/_bmad-output" _bmad-output  || status=1

mkdir -p .claude/skills
for s in "$SPEC"/.claude/skills/*/; do
  name=$(basename "$s")
  link "../../$SPEC/.claude/skills/$name" ".claude/skills/$name" || status=1
done

# remove links to skills that no longer exist (e.g. renamed in a BMAD upgrade)
for l in .claude/skills/*; do
  if [ -L "$l" ] && [ ! -e "$l" ]; then rm "$l"; echo "rm   $l (dangling)"; fi
done

exit $status
EOF
chmod +x "$SPEC_DIR/scripts/link-workspace.sh"

write "$SPEC_DIR/README.md" <<'EOF'
# __SPEC__

Specifications for [__PRODUCT__](https://github.com/__OWNER__/__PRODUCT__): __DESCRIPTION__

Built with spec-driven development using the [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD).

> **Contributing?** Give [BOOTSTRAP.md](BOOTSTRAP.md) to Claude Code and say
> *"read BOOTSTRAP.md and set up my environment"*.

## What's here

| Path | Contents |
|---|---|
| `_bmad-output/` | The specs: product brief, PRD, architecture, epics and stories |
| `_bmad/` | The BMAD Method install (config, helper scripts) |
| `.claude/skills/` | BMAD's agents and workflows as Claude Code skills |
| `WORKSPACE.md` | Rules for the two-repo workspace |
| `BOOTSTRAP.md` | Developer setup, runnable by a coding agent |
| `scripts/link-workspace.sh` | Wires the workspace folder to this repo with symlinks |

Code lives in the sibling repo [__PRODUCT__](https://github.com/__OWNER__/__PRODUCT__).
Every code change traces back to a story here.

## License

MIT — see [LICENSE](LICENSE).
EOF

write "$SPEC_DIR/BOOTSTRAP.md" <<'EOF'
# __PRODUCT__ — developer bootstrap

**Give this whole file to Claude Code (or another coding agent) and say:
"read BOOTSTRAP.md and set up my environment".** It is self-contained: the
agent needs no prior conversation and no other context to take you from an
empty machine to a working checkout of the __PRODUCT__ workspace.

Humans: you can also read it top to bottom and run the commands yourself.

| Repo | URL |
|---|---|
| Specs + BMAD | https://github.com/__OWNER__/__SPEC__ |
| Code | https://github.com/__OWNER__/__PRODUCT__ |

<!-- Maintainer: fill in the three `TODO (maintainer)` blocks (toolchain,
     secrets, verify) once the architecture has settled the stack. -->

*Paths below use the default workspace `~/repos/__WORKSPACE__`. Agent: if
the developer chose another location, use that everywhere instead.*

---

## How the agent runs this file

**Agent: these instructions are for you. Follow them exactly.**

1. **Work through sections 1–8 in order.** Check before acting: if a check
   already passes, report it and move on. Never redo or overwrite work that
   is already correct. The whole file is safe to re-run.
2. **Do things, don't describe them.** The developer asked for a working
   environment, not a list of instructions.
3. **Ask the developer only these questions**, all together at the start
   (`AskUserQuestion` if you have it, plain questions otherwise):
   - **Where should the workspace live?** Default: `~/repos/__WORKSPACE__`.
   - **Your name and GitHub-verified email for commits?** Offer to build
     their GitHub noreply address (section 2).
   - **Collaborator on `__OWNER__`'s repos, or contributing from forks?**
     Default: forks, if `gh` shows no push access.
   - **Language the BMAD agents should talk to you in?** Default: English.
   - **Experience level: beginner, intermediate or expert?** Default:
     intermediate.
4. **Stop and hand back to the human** when:
   - section 0 isn't done (no `gh` login, no repo access);
   - installing a tool needs `sudo`/admin rights;
   - anything would **overwrite a real file** where a symlink is expected
     (section 5). Show it and let the human decide;
   - you would need a secret (password, API key, token). **Never ask for it
     in chat, never type it into a command, never write it anywhere.** The
     human puts it into `.env` themselves (section 7).
5. **Never** commit, push, open PRs or change the repos during setup. Setup
   only clones, links and verifies.
6. **Finish with the report in section 9.**

---

## 0. What a human must do first

1. **GitHub account with `gh` logged in:** `gh auth login` (interactive,
   run it yourself); check with `gh auth status`.
2. **Claude Code** installed and signed in: `claude --version`.
3. Any accounts or credentials the product needs for testing (see
   section 7). Use **test accounts**, never personal ones.

> **Agent check:** `gh auth status` succeeds and
> `gh repo view __OWNER__/__SPEC__` works. If either fails, stop.

---

## 1. Toolchain

**Agent:** check each tool first; install only what's missing, with the
platform's usual installer (Homebrew, the distro package manager, winget).
Ask the human before anything needing admin rights.

| Tool | Needed for | Check |
|---|---|---|
| git, gh | everything | `git --version`, `gh auth status` |
| Node.js 20.12+ | BMAD upgrades | `node --version` |
| Python 3.10+ | BMAD helper scripts | `python3 --version` |
| uv | BMAD helper scripts | `uv --version` |
| Claude Code | agents | `claude --version` |

<!-- TODO (maintainer): add the product's own runtime/test tooling here. -->

---

## 2. Git identity — set it before the first commit

The commit **author is the human who owns the work**. AI agents go in a
`Co-Authored-By:` trailer, **never** in the author field.

**Agent:** use the name and email the developer gave you. To build their
GitHub noreply address (credits them, keeps their mailbox private):

```bash
echo "$(gh api user --jq .id)+$(gh api user --jq .login)@users.noreply.github.com"
```

```bash
git config --global user.name  "Their Name"
git config --global user.email "<the address they chose>"
```

After cloning, check for per-repo overrides, which silently win:

```bash
for r in __SPEC__ __PRODUCT__; do echo "$r: $(git -C "$r" config user.email)"; done
```

---

## 3. Clone the workspace

One parent folder that is **deliberately NOT a git repo**, holding two
sibling repos. Keep the names exactly: everything assumes them.

| Repo | Holds | Rule |
|---|---|---|
| `__SPEC__/` | BMAD (`_bmad/`), its skills (`.claude/skills/`), specs (`_bmad-output/`), `WORKSPACE.md`, this file | Decisions. No code. |
| `__PRODUCT__/` | The product code and tests | Code. No specs. |

**Agent:** skip any repo already cloned there.

**Collaborators:**

```bash
mkdir -p ~/repos/__WORKSPACE__ && cd ~/repos/__WORKSPACE__
gh repo clone __OWNER__/__SPEC__
gh repo clone __OWNER__/__PRODUCT__
```

**Contributors from forks:**

```bash
mkdir -p ~/repos/__WORKSPACE__ && cd ~/repos/__WORKSPACE__
gh repo fork __OWNER__/__SPEC__ --clone
gh repo fork __OWNER__/__PRODUCT__ --clone
```

At the start of **every** session, update both (forks: sync your fork first):

```bash
me=$(gh api user --jq .login)
for r in __SPEC__ __PRODUCT__; do gh repo sync "$me/$r" 2>/dev/null; git -C "$r" pull --ff-only; done
```

`--ff-only` never merges; if it refuses, deal with your local work first.

---

## 4. Workspace rules

Claude Code loads `CLAUDE.md` and `.claude/skills/` from **the folder you
start it in**: always the **workspace folder**. The rules live once, in
`__SPEC__/WORKSPACE.md`, reached by symlink. **Symlinks, never copies.**
Copies drift silently and the agents then follow stale rules.

---

## 5. Wire the workspace

**Agent:** from the workspace folder run:

```bash
bash __SPEC__/scripts/link-workspace.sh
```

Non-zero exit = a path that should be a symlink is a **real file**. Stop and
show the human. The script is idempotent: re-run it any time, and **always
after pulling a BMAD upgrade**. It creates:

```
__WORKSPACE__/
├── CLAUDE.md      -> __SPEC__/WORKSPACE.md
├── _bmad          -> __SPEC__/_bmad
├── _bmad-output   -> __SPEC__/_bmad-output
└── .claude/skills/bmad-*  -> __SPEC__/.claude/skills/bmad-*
```

`_bmad` and `_bmad-output` are linked because BMAD resolves paths from the
project root (the workspace). Through the links, all agent output lands in
the spec repo. **Don't run the BMAD installer**: only the maintainer
upgrades it (section 11).

### 5b. Personal BMAD settings

`_bmad/config.user.toml` (name, language, level) is **git-ignored**; the repo
ships `_bmad/config.user.toml.example`. **Agent:**

```bash
cd ~/repos/__WORKSPACE__/__SPEC__
[ -f _bmad/config.user.toml ] || cp _bmad/config.user.toml.example _bmad/config.user.toml
git check-ignore -q _bmad/config.user.toml && echo "ignored OK" || echo "STOP: NOT git-ignored"
```

Then set, leaving the rest untouched: `user_name` (`[core]`),
`communication_language` (`[core]`), `user_skill_level` (`[modules.bmm]`:
`"beginner"`, `"intermediate"` or `"expert"`).

**Language is for conversation only:** specs committed to `__SPEC__` are
written in **English**, so every contributor can read them.

---

## 6. Read before changing anything

1. `__SPEC__/WORKSPACE.md`
2. `__SPEC__/_bmad-output/`: the PRD and architecture at least
3. `__PRODUCT__/CLAUDE.md`

**Non-negotiables:** spec first (no code without a story; behaviour changes
update the spec in the same session) · secrets never in git, specs, issues
or chat · tests with every change, a regression test with every fix ·
branch → PR → review → merge, never push to `main`.

---

## 7. Secrets — the human fills them in

**Agent:** if `__PRODUCT__/.env.example` exists, create `.env` from it with
**empty values only**, confirm git ignores it, and ask the human to paste the
values themselves. Never read the file back.

```bash
cd ~/repos/__WORKSPACE__/__PRODUCT__
[ -f .env.example ] && [ ! -f .env ] && sed 's/=.*/=/' .env.example > .env
[ -f .env ] && { git check-ignore -q .env && echo ".env ignored" || echo "STOP: .env NOT git-ignored"; }
```

<!-- TODO (maintainer): list the variables and where to obtain test values. -->

---

## 8. Verify

```bash
cd ~/repos/__WORKSPACE__
head -3 CLAUDE.md
ls -L .claude/skills | grep -c '^bmad-'                  # must be > 0
ls -L _bmad _bmad-output > /dev/null && echo "BMAD links OK"
find .claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print   # must print nothing
```

Human, in a new terminal: `cd ~/repos/__WORKSPACE__ && claude`, then ask
*"Summarise CLAUDE.md, run bmad-help, and tell me where you'd save a new
story."* It must point into `__SPEC__/_bmad-output/`.

<!-- TODO (maintainer): build/test commands for __PRODUCT__. -->

---

## 9. Final report (agent)

```
Setup report — __WORKSPACE__ at <path>
✅/❌ gh logged in, repo access
✅/❌ toolchain (versions)
✅/❌ git identity: <name> <email>, no per-repo override
✅/❌ cloned: __SPEC__, __PRODUCT__ (collaborator | fork)
✅/❌ workspace links: CLAUDE.md, _bmad, _bmad-output, N skills, 0 dangling
✅/❌ BMAD personal config set and git-ignored
✅/❌ .env (if needed) exists, ignored, values filled / still empty
✅/❌ build/tests
Still to do by you: <list, or "nothing">
Next: cd <path> && claude, then run bmad-help.
```

---

## 10. Day-to-day: the BMAD way

Always start Claude Code from the workspace folder; start a **fresh
session** (`/clear`) for each BMAD step. Unsure which workflow? Run
**`bmad-help`**. Claim an issue before starting (`gh issue edit <N> --repo
__OWNER__/__PRODUCT__ --add-assignee @me`, or comment if you can't assign).

| Situation | Typical BMAD route |
|---|---|
| New product / big feature | `bmad-product-brief` → `bmad-prd` → `bmad-architecture` → `bmad-create-epics-and-stories` → `bmad-sprint-planning` → `bmad-build` per story → `bmad-code-review` |
| Small bug or tweak | `bmad-spec` → `bmad-build` → `bmad-code-review` |
| Plan turned out wrong | `bmad-correct-course` |
| After a milestone | `bmad-retrospective` |

A change usually touches both repos: the spec/story in `__SPEC__`
(`story <ID>: …`), the code in `__PRODUCT__` (`… (story <ID>)`). Link the
two PRs; merge the spec PR first or together, never after.

---

## 11. Upgrading BMAD (maintainer only)

```bash
cd ~/repos/__WORKSPACE__/__SPEC__ && git checkout -b chore/bmad-upgrade
npx bmad-method install          # updates the existing install
cd .. && bash __SPEC__/scripts/link-workspace.sh
```

Review the diff (skills get renamed), update section 10 if names changed,
refresh `config.user.toml.example` if keys changed (placeholder name only),
check `bmad-help` works, merge on its own. Tell developers to pull and re-run
the link script.

---

## 12. If you get stuck

- Rules: `WORKSPACE.md` → architecture doc → the repo's `CLAUDE.md`.
- Agent can't find BMAD config or writes files in the wrong place: re-run
  `link-workspace.sh`, start `claude` from the workspace folder.
- BMAD uses the wrong name/language: fix `_bmad/config.user.toml` (5b).
- Product decisions belong to the maintainer: ask on the issue.
EOF
ok "WORKSPACE.md, BOOTSTRAP.md, README.md, .gitignore, scripts/link-workspace.sh"

# ─── 5. code repo files ──────────────────────────────────────────────────────
step "Writing code repo files"
write "$CODE_DIR/CLAUDE.md" <<'EOF'
# __PRODUCT__

Specs for this code live in `../__SPEC__/_bmad-output/`.
Read the story before changing code; every change traces back to a story.
EOF

write "$CODE_DIR/.gitignore" <<'EOF'
# Secrets — never commit
.env
.env.*
!.env.example

# Dependencies / build output
node_modules/
dist/
build/
coverage/
__pycache__/
.venv/
*.pyc

# OS / editor
.DS_Store
.idea/
.vscode/
EOF

write "$CODE_DIR/.env.example" <<'EOF'
# Copy to .env (git-ignored) and fill in. Never commit real values.
# Add one line per variable the product needs, e.g.:
# SERVICE_USERNAME=
# SERVICE_PASSWORD=
EOF

write "$CODE_DIR/README.md" <<'EOF'
# __PRODUCT__

__DESCRIPTION__

> **Status:** in design. Requirements and architecture are written in
> [__SPEC__](https://github.com/__OWNER__/__SPEC__).

> **Contributing?** Give
> [BOOTSTRAP.md](https://github.com/__OWNER__/__SPEC__/blob/main/BOOTSTRAP.md)
> to Claude Code and say *"read BOOTSTRAP.md and set up my environment"*.

## License

MIT — see [LICENSE](LICENSE).
EOF

for d in "$SPEC_DIR" "$CODE_DIR"; do
write "$d/LICENSE" <<'EOF'
MIT License

Copyright (c) __YEAR__ __HOLDER__

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
done
ok "CLAUDE.md, README.md, .gitignore, .env.example, LICENSE (both repos)"

# ─── 6. wire the workspace ───────────────────────────────────────────────────
step "Linking the workspace"
( cd "$WS" && bash "$SPEC/scripts/link-workspace.sh" >/dev/null ) || die "link-workspace.sh reported a problem"
ok "CLAUDE.md, _bmad, _bmad-output, $(ls "$WS/.claude/skills" | wc -l | tr -d ' ') skill links"

# ─── 7. git + GitHub ─────────────────────────────────────────────────────────
step "Committing"
commit_repo() {  # commit_repo <dir> <message>
  ( cd "$1"
    git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
    git add -A
    if git diff --cached --name-only | grep -Eq '(^|/)config\.user\.toml$|(^|/)\.env$'; then
      die "A personal/secret file is staged in $1. Check .gitignore"
    fi
    git commit -q -m "$2"
  )
  ok "$(basename "$1"): $(cd "$1" && git rev-parse --short HEAD) $2"
}
commit_repo "$SPEC_DIR" "chore: BMAD install, workspace rules, bootstrap and link script"
commit_repo "$CODE_DIR" "chore: initial repo with license, readme and gitignore"

if [ "$USE_GITHUB" = 1 ]; then
  step "Creating GitHub repos ($VISIBILITY)"
  ( cd "$SPEC_DIR" && gh repo create "$OWNER/$SPEC" "--$VISIBILITY" --source=. --remote=origin --push \
      --description "Specs (BMAD) for $PRODUCT: $DESCRIPTION" >/dev/null )
  ok "https://github.com/$OWNER/$SPEC"
  ( cd "$CODE_DIR" && gh repo create "$OWNER/$PRODUCT" "--$VISIBILITY" --source=. --remote=origin --push \
      --description "$DESCRIPTION" >/dev/null )
  ok "https://github.com/$OWNER/$PRODUCT"
fi

# ─── 8. done ─────────────────────────────────────────────────────────────────
trap - EXIT
cat <<EOF

${G}${B}Done.${N} Workspace ready at $WS

Next:
  1. cd "$WS" && claude
  2. Smoke test: "Summarise CLAUDE.md, run bmad-help, and tell me where you'd save a product brief."
  3. /clear, then run /bmad-product-brief to start the Analyst phase.
$( [ "$VISIBILITY" = private ] && [ "$USE_GITHUB" = 1 ] && echo "
Note: the repos are PRIVATE. Contributors need access before BOOTSTRAP.md works for them,
or make them public: gh repo edit $OWNER/$SPEC --visibility public --accept-visibility-change-consequences" )
$( [ "$USE_GITHUB" = 0 ] && echo "
GitHub skipped. Later, from each repo: gh repo create <owner>/<name> --private --source=. --remote=origin --push
and replace OWNER in both READMEs and BOOTSTRAP.md." )
Contributors: https://github.com/$OWNER/$SPEC/blob/main/BOOTSTRAP.md
EOF
