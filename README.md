# DSERVE AI Skills

Company-wide Claude Code skills, managed via the `d-ai` CLI.

## Install the CLI

```bash
npm install -g https://github.com/MaistoMyletojai/ai-skills.git
```

## Commands

```bash
d-ai install <skill>   # install a skill
d-ai install -a        # install all skills
d-ai sync              # pull latest and update already-installed skills
d-ai remove <skill>    # uninstall a skill
d-ai list              # browse available skills in the repo
d-ai status            # check what is installed locally (no network)
d-ai help              # full usage
```

## Update the CLI

```bash
npm install -g https://github.com/MaistoMyletojai/ai-skills.git
```

## How it works

- Skills are installed to `~/.claude/skills/` — Claude Code's global skill directory
- The repo is cached at `~/.d-ai/repo/`
- `sync` only updates skills you have already installed — it won't install new ones automatically
- Restart Claude Code after installing or syncing to pick up changes

## Available skills

| Skill | Description |
|---|---|
| `qa-ticket` | Automated QA for a Trello ticket. Fetches AC, finds PRs, builds projects, runs Playwright E2E tests, produces an HTML dashboard. |

## Adding a new skill

1. Create `skills/<skill-name>/SKILL.md`
2. Add any supporting files (e.g. `knowledge/`)
3. Update the table above
4. Open a PR — once merged, everyone gets it via `d-ai install <skill>` or `d-ai sync`
