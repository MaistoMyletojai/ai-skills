# DSERVE AI Skills

Company-wide Claude Code skills.

## Install

```bash
git clone git@github.com:MaistoMyletojai/ai-skills.git
cd ai-skills
chmod +x install.sh
./install.sh              # all skills
./install.sh qa-ticket    # one skill
```

## Update

```bash
git pull && ./install.sh
```

## Skills

| Skill | Description |
|---|---|
| `qa-ticket` | Automated QA validation for a Trello ticket. Fetches AC, finds PRs, builds projects, runs Playwright E2E tests, produces HTML dashboard. |

## Adding a new skill

1. Create `skills/<skill-name>/SKILL.md`
2. Add any supporting files (e.g. `knowledge/`)
3. Update the table above
4. Open a PR
