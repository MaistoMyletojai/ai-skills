# dserve-qa-runner (Claude skill)

The **testing core** of `dserve-qa-rig`, repackaged as a self-contained
Claude skill. It QA-validates one Dserve Trello ticket / PR end to end:
resolve the PR → check out the branch → classify acceptance criteria → run
tiered tests → evaluate screenshots → write a report → (optionally) post the
verdict to Trello + the GitHub PR.

The difference vs the rig: **you** (the model, via this skill) run a ticket
on demand. There is **no** scheduler, no Trello polling, no queue, no
Telegram bot, no launchd daemons — those orchestration layers were left
behind on purpose. Only the parts that affect *what gets tested and how
accurately* came across.

## What was extracted (and what wasn't)

| Carried over (testing logic) | Left behind (scheduled-job machinery) |
|---|---|
| `prompts/qa-card.md` — the 994-line QA playbook | `qa_rig/scheduler.py` — Trello poller |
| `knowledge/*.md` — selectors, flows, lessons (5 files) | `qa_rig/queue.py` — FIFO queue + PID lock |
| `runners/*.sh` — api / ui / eshop / cross-system + installer | `qa_rig/orchestrator.py` — Telegram bot |
| `templates/*.tmpl` — xUnit + Playwright scaffolds (5 files) | `qa_rig/progress.py` — Telegram progress msgs |
| `tools/{kc.sh,trello.sh}` — Keychain + Trello REST | `qa_rig/labels.py` — Ready→InProgress→Complete state machine |
| `scripts/qa_prepare.py` — PR resolve + checkout + inputs (from `pipeline.py` §0-4 + `helpers.py`) | `qa_rig/agent.py` — claude-CLI subprocess wrapper (the skill *is* the agent now) |
| `scripts/qa_post.py` — Trello/PR posting (from `pipeline.py` §6-10) | `launchd/*.plist`, `deploy.sh`, `scheduler/orchestrator` daemons |
| `scripts/qa_attach.py` — Trello-only evidence attach + duplicate-evidence guard | `qa_rig/dashboard.py` — run-history web UI |
| `scripts/lib.sh` — env setup (from `helpers.agent_env`) | `qa_rig/state.py` — last-SHA skip logic (a scheduler optimisation) |

Every accuracy/performance feature of the rig's QA path is preserved:
label-first scope routing, dual-repo PR resolution, eshop-master fallback,
detached-checkout worktree isolation, the full tier runners with port
preflight + guaranteed cleanup, the visual (multimodal) screenshot
evaluation, the report fallback chain, and the verdict ladder
(`QA_APPROVED` / `…_WITH_GATES` / `QA_REJECTED` / `QA_NEEDS_HUMAN`).

## Prerequisites (macOS)

- Python 3.11+, Node 20+ + npm, `gh` (authenticated: `gh auth login`),
  `jq`, `lsof` (built-in), `curl`.
- .NET 8 SDK **and** the `Microsoft.AspNetCore.App 8.x` runtime
  (`dotnet --list-runtimes`) — required for the API + Admin tiers.
- Repo clones + their QA worktrees (paths set in config) — for whichever
  surfaces you'll test:
  ```bash
  git -C "$MAIN_REPO_DIR"   worktree add "$MAIN_REPO_QA"   master  # dserve-backend (API + Admin)
  git -C "$WEB_REPO_DIR"    worktree add "$WEB_REPO_QA"    main    # self-service-web (eshop)
  git -C "$ORDERS_REPO_DIR" worktree add "$ORDERS_REPO_QA" main    # orders-dashboard (web KDS)
  ```
  React worktrees (`self-service-web`, `orders-dashboard`) need their own
  `npm install` before the first run (the tier runner tells you if missing).
- One-time Playwright runtime in the skill's own data root: run
  `runners/install-playwright.sh` (installs to `$QA_DATA_ROOT/playwright-runtime`,
  default `~/dserve-qa-skill-data/playwright-runtime`). Browsers are cached
  globally, so it's cheap. (Optionally set `QA_PLAYWRIGHT_RUNTIME` to reuse any
  existing Playwright runtime elsewhere.)

## Keychain (secrets never live in the env file)

`tools/trello.sh` and the eshop tier read these macOS Keychain entries
(the `_qa_` names, falling back to the dev-rig `autodev_*` names):

```bash
for s in autodev_qa_trello_key autodev_qa_trello_token autodev_qa_tablet_token; do
  security add-generic-password -U -s "$s" -a "$USER" -w '<value>'
done
```

- `autodev_qa_trello_key` / `autodev_qa_trello_token` — from
  <https://trello.com/app-key> (read+write on the board).
- `autodev_qa_tablet_token` — the eshop `tabletToken` JWT (from a logged-in
  staging tablet's localStorage). If `/api/qr/*` returns 401 later, re-add it.

## Setup

First run is gated by a doctor that tells you exactly what's missing:

```bash
source scripts/lib.sh
python3 scripts/qa_setup.py            # lists every required/optional var + creds + tools
python3 scripts/qa_setup.py --init     # scaffold config/qa-skill.env + config/.secrets
$EDITOR config/qa-skill.env            # config + our-system creds (paths, board id, URLs, logins+passwords, tabletToken)
$EDITOR config/.secrets                # THIRD-PARTY tokens only (gitignored): Trello + optional GitHub
python3 scripts/qa_setup.py            # re-run until it exits 0 (ready)
```

Config is split in two — both loaded by `lib.sh`:
- **`config/qa-skill.env`** — config **+ our-system creds**: repo paths/slugs,
  board id + list ids, ports, API/dev URLs, login emails **and passwords**, and
  the eshop `QA_TABLET_TOKEN`.
- **`config/.secrets`** — **THIRD-PARTY tokens ONLY**, **gitignored** (chmod 600):
  `TRELLO_API_KEY`, `TRELLO_TOKEN`, optional `GH_TOKEN`.

Policy: only third-party API tokens (Trello/GitHub) go in `.secrets`; our own
test-system credentials are hardcoded in `qa-skill.env`.

It exits **3** until the **core** requirements are present (Trello key+token,
`TRELLO_BOARD_ID`, `gh auth login`) plus the variables for the mode you'll use
(local repos, or remote/dev). When invoked through Claude, the skill runs this
automatically and **asks you for every missing variable on first run**.

GitHub: prefer `gh auth login` (no token needed). Trello creds may alternatively
live in the macOS Keychain (`autodev_qa_trello_key`/`_token`) — `trello.sh`
checks Keychain first, then `.secrets`. Leave `QA_ADMIN_EMAIL` blank to skip the
live Admin UI tier (admin-ui AC then fall back to code-evidence).

## Usage

Ask Claude with the skill available: **"QA ticket #4893"**, **"verify the PR
for card <url>"**, **"run QA on #4948, local only"**. Claude then:

```bash
source scripts/lib.sh                          # env
python3 scripts/qa_prepare.py 4893             # resolve + checkout + inputs → JSON summary
# … export QA_TICKET / QA_OUT_DIR / QA_REPO_ROOT / QA_UI_TIER_AVAILABLE, cd worktree …
# … read playbook + knowledge, write & run tier specs, evaluate screenshots …
# … Write qa-report.md + qa-trello-summary.md + qa-telemetry.json …
python3 scripts/qa_post.py 4893 --dry-run      # preview
python3 scripts/qa_post.py 4893                # post to Trello + PR (omit for local-only)
```

**Trello-only:** to attach the report + screenshots + summary to the card
*without* touching the PR, use `qa_attach.py`. It refuses (exit 2) if the
card already has QA evidence — re-run with `--confirm` once the user agrees:

```bash
python3 scripts/qa_attach.py 4893              # attach; asks before duplicating existing QA evidence
python3 scripts/qa_attach.py 4893 --confirm    # add another round after confirmation
```

### Remote mode (no local repos — test via GitHub + dev server)

For users who don't keep the repos cloned. Resolves the PR + diff from
GitHub and runs the UI tier against the deployed dev server — no local
checkout, no locally-started servers.

```bash
source scripts/lib.sh
python3 scripts/qa_prepare.py 4893 --remote     # PR + diff from GitHub, no worktree
tools/gh_file.sh "$MAIN_REPO_SLUG" path/to/File.razor <head-sha>   # source recon, no clone
"$QA_AGENT_ROOT/runners/ui-tier-remote.sh"   "$QA_OUT_DIR/playwright"   # Admin on $QA_ADMIN_DEV_URL
"$QA_AGENT_ROOT/runners/eshop-tier-remote.sh" "$QA_OUT_DIR/playwright"  # eshop on $QA_ESHOP_DEV_URL
python3 scripts/qa_attach.py 4893               # publish (same as local mode)
```

Requires `MAIN_REPO_SLUG`/`WEB_REPO_SLUG` (defaults set), `QA_ADMIN_DEV_URL`
(set it), `QA_ESHOP_DEV_URL` (defaults to ss-dev), `gh auth login`, admin
creds, and the tablet token. **Limitations vs local mode:** no local build →
back-end/API AC become **code-evidence** (no live xUnit); and the dev server
shows what is **deployed** — for an open, undeployed PR a missing feature is
`NEEDS_HUMAN` ("not deployed yet"), not `FAIL`. Remote runs therefore tend to
land at `QA_APPROVED_WITH_GATES` / `QA_NEEDS_HUMAN`.

### Manual one-shot (without the model driving)

You can run the deterministic halves yourself:

```bash
source scripts/lib.sh
python3 scripts/qa_prepare.py 4893             # sets up the worktree + inputs
#   → then do the testing by hand / let Claude take over …
python3 scripts/qa_post.py 4893 --dry-run      # see what would be published
```

## Outputs (per run, under `$QA_DATA_ROOT/runs/<ticket>/`)

```
qa-ticket.json  qa-pr.json  qa-diff.patch     # inputs (also in /tmp)
qa-report.md            → GitHub PR comment
qa-trello-summary.md    → Trello card comment
qa-telemetry.json       → structured counts + verdict
screenshots/*.png       → attached to the Trello card
api-results.trx · ui-results.json · eshop-results.json · cross-system-results.json
```

## Notes

- **macOS only** — `kc.sh` uses the `security` Keychain CLI.
- The worktree is reset (`git reset --hard` + `clean -fd`) at the start of
  every run, so generated scratch tests never accumulate or get committed.
- Knowledge is **append-only** — when QA learns a new selector/gotcha it's
  added to `knowledge/*.md`, which is how this skill compounds accuracy.
- To install as a live skill, copy this folder into a `.claude/skills/`
  directory (e.g. `cp -r qa-skill ~/.claude/skills/dserve-qa-runner`).
