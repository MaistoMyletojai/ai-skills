# DSERVE AI Skills

Company-wide Claude Code skills, managed via the `d-ai` CLI.

## Install the CLI

```bash
npm install -g https://github.com/MaistoMyletojai/ai-skills.git
```

That's it. `d-ai` is now available globally.

## Usage

```bash
d-ai sync               # pull latest + install all skills
d-ai sync qa-ticket     # pull latest + install one skill
d-ai list               # show available skills and install status
d-ai status             # show what's installed (no network)
d-ai help               # full usage
```

## Update CLI itself

```bash
npm install -g https://github.com/MaistoMyletojai/ai-skills.git
```

## How it works

- Skills are installed to `~/.claude/skills/` — Claude Code's global skill directory
- Repo cached at `~/.d-ai/repo/`, updated on every `sync`
- Restart Claude Code after syncing to pick up new skills

## Skills

| Skill | Description |
|---|---|
| `qa-ticket` | Automated QA for a Trello ticket. Fetches AC, finds PRs, builds projects, runs Playwright E2E tests, produces HTML dashboard. |

## Adding a new skill

1. Create `skills/<skill-name>/SKILL.md`
2. Add supporting files (e.g. `knowledge/`)
3. Update the table above
4. Open a PR — merged = available to everyone on next `d-ai sync`
