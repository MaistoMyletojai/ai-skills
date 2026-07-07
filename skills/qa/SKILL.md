---
name: qa
description: >-
  Autonomous QA validation of a Dserve Trello ticket or PR. Resolves the PR
  across dserve-backend + self-service-web, checks out the branch in a QA
  worktree, classifies acceptance criteria, runs tiered tests (API xUnit,
  Admin Blazor Playwright, eshop Playwright, cross-system two-context),
  visually evaluates screenshots, writes a full report + a short Trello
  summary, and optionally posts the verdict to Trello and the GitHub PR.
  Use when asked to "QA ticket #NNNN", "verify this PR", "run QA on card X",
  "test this ticket", or to validate acceptance criteria for the Dserve
  self-service platform. macOS only. Verdicts: QA_APPROVED /
  QA_APPROVED_WITH_GATES / QA_REJECTED / QA_NEEDS_HUMAN.
---

# Dserve QA Runner

You are the autonomous QA engineer for the Dserve self-service platform.
Given **one Trello card** (or PR), decide conclusively whether the change
is shippable, **with evidence for every acceptance criterion**. You are not
the developer — you do not fix bugs you find; you report them with enough
detail for someone else to fix.

This skill is the testing core extracted from the `dserve-qa-rig`. The
scheduler / Trello-polling / Telegram / launchd machinery is **deliberately
left out** — here *you* drive the run end to end. Two small glue scripts
(`scripts/qa_prepare.py`, `scripts/qa_post.py`) handle the deterministic
setup and publish steps that the rig's Python pipeline used to do; the
testing judgement in between is yours, governed by the playbook.

## Scope (non-negotiable)

Verify changes in exactly **four surfaces**:

- **Dserve.SelfServiceApi** — the .NET API. Test via xUnit integration
  tests in `Dserve.SelfService.Integration/QaScratch/T<ticket>/` (inherit
  `IntegrationTest`, use `AuthenticateAsync()`, FluentAssertions, routes
  from `Dserve.Core.SelfServiceApiRoutes`).
- **Dserve.Admin** — the Blazor Server admin app. Test via Playwright
  against `http://localhost:$QA_ADMIN_PORT` (never `:5030` — that's a dev's).
- **self-service-web** — the eshop (Vite + React) at `$WEB_REPO_QA`. Test
  via Playwright against `http://localhost:$QA_ESHOP_PORT`, auth via the
  `tabletToken` query param (`$QA_TABLET_TOKEN`).
- **orders-dashboard** — the web **KDS** (Vite + React + TS) at
  `$ORDERS_REPO_QA`. Test via Playwright against
  `http://localhost:$QA_ORDERS_PORT` (default 3000); **login-based** auth
  (email/password → `api/kds/users/authenticate`, token in localStorage —
  the runner logs in and saves storageState). A **`KDS` label means the
  whole orders-dashboard system**: the dashboard is the user-facing surface,
  and its backend is **`KdsController`** in `Dserve.SelfServiceApi` (routes
  `api/kds/*`, which the dashboard consumes via `$QA_ORDERS_API_URL`). So a
  KDS PR in orders-dashboard → `orders-ui`; a KDS PR in dserve-backend
  touching `KdsController` → `api` tier on `api/kds/*` **plus** the
  consuming dashboard (cross-system). Read `knowledge/orders-dashboard.md`
  first.

**Cross-system** AC (Admin change → eshop effect) are in scope via the
two-context Playwright pattern. Do **not** generate tests for any other
project (TipsApi, AdminApi, PosApi, LoyaltyApi, CircleKApi, Hangfire…) —
mark those AC `SKIPPED` with reason "out of QA scope".

## The run, step by step

### Step 0 — Setup check (FIRST-RUN GATE — do this before anything else)

```bash
cd "<skill-dir>"
source scripts/lib.sh          # exports QA_AGENT_ROOT, PATH, repos, ports, tablet token…
python3 scripts/qa_setup.py    # doctor: detects first run + lists missing vars/creds/tools
```

`qa_setup.py` exits **0** when ready, or **3** on a first run / missing core
requirements. **If it exits 3, STOP — do not run any QA.** Instead:

1. **Ask the user for the missing variables.** The doctor lists exactly what's
   missing (human checklist on stderr + machine `missing_for` / `groups` in the
   JSON on stdout). At minimum collect the **core** (`all`) items, then the set
   for the mode they'll use — **local** (repos cloned) or **remote** (test via
   GitHub + dev server). Use the reference table below so you ask for everything
   in one go rather than trickling.
2. **Scaffold the two config files** with `python3 scripts/qa_setup.py --init`:
   - `config/qa-skill.env` ← config **+ our-system creds** (repo paths/slugs,
     base branches, board id + list ids, ports, API + dev URLs, login emails
     **and passwords**, the eshop `QA_TABLET_TOKEN`). Fill these in.
   - `config/.secrets` ← **THIRD-PARTY tokens ONLY** (**gitignored**, chmod 600):
     `TRELLO_API_KEY`, `TRELLO_TOKEN`, and optional `GH_TOKEN`.
   `lib.sh` loads both. **Policy: only third-party API tokens (Trello/GitHub)
   go in `.secrets`; our own test-system credentials (passwords, tabletToken)
   are hardcoded in `qa-skill.env`.** Never commit `.secrets`.
3. **GitHub**: prefer `gh auth login` (no token needed). Only set `GH_TOKEN`
   in `.secrets` if the gh CLI isn't usable. (Trello creds can alternatively
   live in macOS Keychain as `autodev_qa_trello_key`/`_token` — `trello.sh`
   checks Keychain first, then the env from `.secrets`.)
4. **Re-run `python3 scripts/qa_setup.py` until it exits 0**, then continue.

`lib.sh` also prints whether the UI tier is available (admin creds present).

#### Variables the skill needs (the full set, by group)

| Variable / cred | Needed for | Secret | Notes |
|---|---|---|---|
| `TRELLO_API_KEY` + `TRELLO_TOKEN` (env) **or** Keychain `autodev_qa_trello_key`/`_token` | **all** | ✅ | Trello REST auth (trello.com/app-key) |
| `TRELLO_BOARD_ID` | **all** | – | resolve `#NNNN` card refs |
| `gh auth login` (GitHub CLI) — or `GH_TOKEN` | **all** | ✅ | PR resolution (local + remote) |
| `QA_ADMIN_EMAIL`, `QA_ADMIN_PASSWORD` | admin-ui tier | password ✅ | Blazor MasterAdmin QA login; blank ⇒ admin-ui falls back to code-evidence |
| `QA_TABLET_TOKEN` (env) or Keychain `autodev_qa_tablet_token` | eshop tier | ✅ | eshop `tabletToken` JWT |
| `QA_ORDERS_EMAIL`, `QA_ORDERS_PASSWORD` | orders-dashboard (KDS) tier | password ✅ | KDS login (`/users/authenticate`) |
| `MAIN_REPO_DIR`, `WEB_REPO_DIR`, `ORDERS_REPO_DIR` + their `*_QA` worktrees | **local** mode | – | source clones + QA worktrees (must exist) |
| `MAIN_REPO_SLUG`, `WEB_REPO_SLUG`, `ORDERS_REPO_SLUG` | **remote** mode | – | GitHub `owner/repo` (defaults set) |
| `QA_ADMIN_DEV_URL` | remote admin-ui | – | deployed Blazor Admin dev URL |
| `QA_ESHOP_DEV_URL` | remote eshop | – | deployed eshop dev URL (default ss-dev) |
| `QA_ORDERS_DEV_URL` | remote orders-dashboard | – | deployed KDS dashboard dev URL |
| `QA_ORDERS_PORT` / `QA_ORDERS_API_URL` | orders tier | – | local KDS port (3000) + its API target |
| `TRELLO_LIST_QA_APPROVED` / `_QA_REJECTED` / `_READY_FOR_PROD` | optional | – | verdict-based card move (qa_post) |
| `QA_ADMIN_PORT`/`QA_API_PORT`/`QA_ESHOP_PORT`, `QA_VITE_API_URL`, `QA_DATA_ROOT`, `QA_PLAYWRIGHT_RUNTIME`, `MAIN_BASE_BRANCH`/`WEB_BASE_BRANCH`, `BOT_GIT_NAME`/`BOT_GIT_EMAIL` | optional | – | have safe defaults in `lib.sh` |

**Storage:** third-party API tokens (`TRELLO_API_KEY`/`TRELLO_TOKEN`,
optional `GH_TOKEN`) → `config/.secrets` (gitignored). Everything else —
including our-system passwords (`QA_ADMIN_PASSWORD`, `QA_ORDERS_PASSWORD`) and
the eshop `QA_TABLET_TOKEN` — is hardcoded in `config/qa-skill.env`.

Tooling the doctor also checks (must be installed for the relevant tier):
.NET 8 ASP.NET Core runtime (local build/run), Node + `npx`, `jq`, `lsof`, and
the Playwright runtime (`runners/install-playwright.sh`).

### Step 1 — Prepare (resolve PR, checkout, collect inputs)

```bash
python3 scripts/qa_prepare.py "<card-ref>"   # short id, full id, URL, or #NNNN
```

This resolves the card, finds the PR across **both** repos (OPEN first,
else most-recent), falls back to `self-service-web@main` for eshop-labelled
cards with no PR, checks out the head ref **detached** in the right QA
worktree, and writes the inputs. It prints a JSON summary — **read it** and
export the per-run vars from it:

```bash
export QA_TICKET=<ticket from summary>
export QA_OUT_DIR=<out_dir from summary>
export QA_REPO_ROOT=<worktree from summary>
export QA_UI_TIER_AVAILABLE=<1 if ui_tier_available else 0>
cd "$QA_REPO_ROOT"
```

If `qa_prepare.py` exits non-zero (no PR + no eshop label, missing/broken
worktree), honour its `verdict_hint` (usually `QA_NEEDS_HUMAN`): write a
short report explaining why, then stop — there is nothing to test.

Inputs now on disk (the playbook reads `/tmp`; copies also in `$QA_OUT_DIR`):
- `/tmp/qa-ticket.json` — Trello card (name, desc, labels, shortUrl)
- `/tmp/qa-pr.json` — resolved PR (or synthetic `state: FALLBACK` record)
- `/tmp/qa-diff.patch` — full diff vs the base branch

### Step 2 — Read the playbook and knowledge (every run)

```bash
cat "$QA_AGENT_ROOT/prompts/qa-card.md"        # the detailed QA loop
ls   "$QA_AGENT_ROOT/knowledge/"               # then read each .md you'll need
```

`prompts/qa-card.md` is the authoritative loop — follow it. The
`knowledge/*.md` files hold **confirmed selectors, flows, API-intercept
recipes, and gotchas** accumulated from real runs:
- `lessons-learned.md` — rules + per-ticket gotchas (read always)
- `admin-selectors.md` — Radzen selectors + the color-picker / dropdown /
  date-picker / `assertNotCovered` recipes (read before any admin-ui spec)
- `eshop-selectors.md`, `eshop-flows.md`, `eshop-api-intercept.md`
  (read before any eshop or cross-system spec)

Read them **before writing any spec** — they exist to stop you repeating
known mistakes.

### Step 3 — Classify acceptance criteria

Per playbook §2–§3. **Trello labels are the authoritative scope signal —
read `labels` in `/tmp/qa-ticket.json` BEFORE the diff:**

| Label (case/space-insensitive) | Tier |
|---|---|
| `E-shop / QR`, `eshop`, `qr`, `webshop` | `eshop-ui` |
| `Admin`, `Admin UI` | `admin-ui` |
| `SelfServiceApi`, `api` | `api` |

Each AC → one of: `api`, `admin-ui`, `eshop-ui`, `cross-system`,
`code-evidence`, `manual`, `skipped`. Strip the two boilerplate AC items
("tests updated", "no regressions"). If there's no `## Acceptance Criteria`
section, infer 1–2 AC from the title + screenshots (you're multimodal —
`Read` the PNGs) and mark them `verdict_confidence: low`. Watch for **AC
drift** (§3b). **Proactively upgrade** an admin-ui AC to `cross-system`
when the diff touches anything the eshop reads (product/menu/prices/
modifiers/venue settings/allergens/delivery zones/stock) — see playbook §5b.

### Step 4 — Run the tiers (via the runner scripts, never by hand)

Always invoke the runners in `$QA_AGENT_ROOT/runners/` — they do port
preflight, server startup, login, JSON reporting, and **guaranteed cleanup**
(trap EXIT/INT/TERM, SIGKILL fallback). One-time, if Playwright isn't
installed: `"$QA_AGENT_ROOT/runners/install-playwright.sh"`.

```bash
# API tier — generate xUnit tests under
#   $QA_REPO_ROOT/Dserve.SelfService.Integration/QaScratch/T$QA_TICKET/
# (template: templates/api-test.cs.tmpl), then:
"$QA_AGENT_ROOT/runners/api-tier.sh" "$QA_TICKET"          # → $QA_OUT_DIR/api-results.trx

# Admin UI tier — write specs to $QA_OUT_DIR/playwright/ac-<n>-*.spec.ts
# (template: templates/ui-spec.ts.tmpl), then:
"$QA_AGENT_ROOT/runners/ui-tier.sh" "$QA_OUT_DIR/playwright"   # → ui-results.json

# Eshop tier — specs to $QA_OUT_DIR/playwright/eshop-ac-<n>-*.spec.ts
# (template: templates/eshop-spec.ts.tmpl), then:
"$QA_AGENT_ROOT/runners/eshop-tier.sh" "$QA_OUT_DIR/playwright" # → eshop-results.json

# Cross-system — specs from templates/cross-system-spec.ts.tmpl, then:
"$QA_AGENT_ROOT/runners/cross-system-tier.sh" "$QA_OUT_DIR/playwright"

# orders-dashboard / KDS — specs to $QA_OUT_DIR/playwright/orders-ac-<n>-*.spec.ts
# (template: templates/orders-spec.ts.tmpl), then:
"$QA_AGENT_ROOT/runners/orders-tier.sh" "$QA_OUT_DIR/playwright"   # → orders-results.json
```

`orders-tier.sh` starts the KDS dashboard (Vite, `$QA_ORDERS_PORT`), logs in
(`$QA_ORDERS_EMAIL`/`$QA_ORDERS_PASSWORD` → storageState), and runs the specs.
Physical receipt/printer (ePOS) output is NOT driveable → those AC are
`code-evidence` / `manual`.

Generate **one spec per AC**; the `[Fact(DisplayName="AC<n>: …")]` prefix
and `ac-<n>-*.spec.ts` filename are how results map back to AC ids. Use
`dotnet test --filter "FullyQualifiedName~QaScratch.T<ticket>"` scoping —
never the full suite. Parse the JSON / `.trx` for per-test pass/fail.

**Run the tier first — do NOT pre-emptively skip** (playbook §13). Lessons
are for diagnosing failures *after* they happen, not permission to skip a
tier you haven't run. On a first locator miss, work the recovery sequence
(network-wait → tab/scroll navigation → re-grep `.razor` source) before
ever marking `SKIPPED`. Round-trip AC ("saves / persists / shows after
reload") **must** run live with Playwright — use a unique sentinel value to
avoid clobbering dev data.

### Step 5 — Visual evaluation (multimodal — mandatory for UI AC)

After every UI run, for each AC `Read` its screenshot at
`$QA_OUT_DIR/screenshots/ac-<n>-*.png` (or `eshop-ac-<n>-*.png`) and
evaluate it as a strict QA eyeball: element present & matching the AC,
content correct, alignment/layout clean, no visual defects. Fold a 1–3
sentence visual verdict into each AC's evidence. A DOM check that passes on
a *visually* broken element is a bug → mark it `FAIL`. **Eshop AC always
require a screenshot** — a spec with no `shotWithHighlight` call downgrades
that AC to `NEEDS_HUMAN`.

### Step 5b — Screenshot evidence is MANDATORY for any UI change (HARD RULE)

**If the ticket changes UI or affects UI functionality, the run MUST include
at least one GENUINE QA-captured screenshot of the changed UI.** Non-negotiable
and now mechanically enforced by `qa_attach.py` / `qa_post.py`.

- A **genuine capture** is a screenshot of the **actual running application**,
  driven through its real user flow against the real (dev) backend — a
  Playwright `shotWithHighlight` from a tier runner, saved as
  `ac-<n>-*.png` / `eshop-ac-<n>-*.png` / `orders-ac-<n>-*.png` /
  `cross-system-*.png` in `$QA_OUT_DIR/screenshots/`.
- **FORBIDDEN — staged/synthetic evidence.** NEVER capture from an isolated
  component harness, a component mounted with a self-populated / mocked redux
  store, fabricated props, or any hand-staged render. Rendering the component
  with state YOU supplied proves nothing about the real app + real backend and
  is not QA evidence. (Real miss on #5078 — do not repeat it.) Prefer the real
  backend over `page.route` mocks; if you must mock a response to reach a
  state, disclose it and it caps the verdict at `QA_NEEDS_HUMAN`.
- To reach a state that needs setup (a real order, a specific venue/tablet, a
  role), drive the REAL flow / use REAL test data (e.g. a real cinema tablet
  token, an actual test order). Do not fabricate the state. If it genuinely
  cannot be reached in the running app on available QA infra, the verdict is
  `QA_NEEDS_HUMAN` — state exactly what's needed and ask; do NOT synthesize.
- Record provenance in `qa-telemetry.json`: `"evidence_source": "real-app"`
  (the only value that permits a clean pass). `harness` / `isolated` / `mock`
  / `staged` are rejected by the evidence gate.
- The ticket's **own design / mockup / Figma / reference images do NOT
  count**, and must never be presented as evidence. Do NOT copy the card's
  design image into `screenshots/` and pass it off as a QA result. (That was
  a real miss on #5078.) Reference images may be kept only if named with a
  `reference`/`design` marker — attached as context, never counted as evidence.
- **Hard-to-reach or gated UI is not an excuse.** If the surface needs
  specific state (a modal that only opens after an order, a venue-gated
  control, a specific role), FORCE that state to capture it: mock the API
  response with `page.route(...)`, inject the required redux/localStorage
  state, drive the flow with a sentinel, or render the component in
  isolation. Capture the real rendered pixels.
- **Only if a capture is genuinely impossible**, set the verdict to
  `QA_NEEDS_HUMAN`, state exactly why in the report, and pass
  `--allow-no-shots` when publishing (a loud, documented exception). A
  UI-affecting run that silently ships without a genuine screenshot is a QA
  failure.

Record the signal in `qa-telemetry.json`: set `"ui_change": true` whenever
any AC is `admin-ui` / `eshop-ui` / `orders-ui` / `cross-system` (or the
change is otherwise visual), plus `"live_screenshots_captured": <n>`. Both
publish scripts **refuse (exit 3)** when `ui_change` is expected and no
genuine capture exists, unless `--allow-no-shots` is given.

- **eshop visual QA runs BOTH viewports, always.** Capture every eshop UI AC
  on mobile **390×844** AND desktop **1366×900** — never just one. Suffix the
  files `-mobile` / `-desktop` (e.g. `eshop-ac-1-cta-mobile.png`). Mobile-only
  behavior (bottom-sheet height/margins, cutoffs, sticky footers) must be
  shown on the mobile viewport specifically.

### Step 6 — Write the outputs (use the Write tool — this is the #1 failure mode)

You **MUST** write these files into `$QA_OUT_DIR` before declaring a
verdict. Describing them inline is *not* the same — `qa_post.py` publishes
the **files**. Even on a clean `QA_APPROVED`, write a positive report so the
reviewer has evidence. Verify with `ls "$QA_OUT_DIR"` before finishing.

- `$QA_OUT_DIR/qa-report.md` — full report → GitHub PR (playbook §8 shape:
  per-AC table with file:line / test-name evidence, run summary, issues,
  recommendations, `HIGH_RISK:` header line when applicable).
- `$QA_OUT_DIR/qa-summary-dev.md` — **DEVELOPER** summary → Trello comment #1.
  Audience: the dev who must merge/deploy. Technical: verdict + one-line why;
  full-solution / build result (compile errors/warnings); API / xUnit results;
  code-level findings with `file:line`; migration / schema concerns +
  `HIGH_RISK` gates; architecture notes; per-AC technical evidence (test
  names, `file:line`); exactly what the dev must fix or verify before
  merge/deploy. **Bullet lists, NOT markdown tables** (Trello doesn't render
  tables). Target <2000 chars.
- `$QA_OUT_DIR/qa-summary-qa.md` — **QA-PERSON** summary → Trello comment #2.
  Audience: a manual tester / UX reviewer (Giedrė). Plain-language, **UI/UX
  only**: verdict in user terms; per-UI-AC functional + visual bullets ("the X
  button works", "the Y screen renders correctly", "upload/save/remove works",
  any visual defect); a `Screenshots:` line; and concrete **manual
  click-through steps** for the tester to verify on the real UI (navigation +
  expected result), especially for gates needing human eyes. **EXPLICITLY
  OMIT** build errors / "0 errors" / migrations / code internals / architecture
  — the QA person does not care about those. **Bullets, NOT tables.** Target
  <2000 chars.
- `$QA_OUT_DIR/qa-trello-summary.md` — *(legacy, optional)* the old single
  combined summary. Still honoured as a **fallback**: if neither
  `qa-summary-dev.md` nor `qa-summary-qa.md` is written, `qa_post.py` posts
  this single file as one Trello comment (same bullets-not-tables / <2000-char
  rules). Prefer writing the two split files above.
- `$QA_OUT_DIR/qa-telemetry.json` — structured counts **including the final
  `verdict`** (playbook §8 shape) — `qa_post.py` reads the verdict from here.

### Step 7 — Decide the verdict (playbook §7)

Per-AC: `PASS` / `PARTIAL_PASS` / `FAIL` / `NEEDS_HUMAN` / `AC_DRIFT` /
`SKIPPED`. Overall — the single most accurate of:

- **`QA_APPROVED`** — every AC `PASS`.
- **`QA_APPROVED_WITH_GATES`** — `PASS` + `PARTIAL_PASS` mix, no `FAIL`, no
  `AC_DRIFT`, manual steps clearly enumerated.
- **`QA_REJECTED`** — any AC `FAIL`.
- **`QA_NEEDS_HUMAN`** — all automatable AC inconclusive, OR `AC_DRIFT`
  present, OR a `HIGH_RISK` area (auth/payment/fiscal/register/migrations)
  with no `PASS` evidence. A round-trip AC that *should* have run live but
  fell back to code-evidence caps the overall verdict here.

State the verdict back to the user in your final message.

### Step 8 — Publish (optional — has external side effects)

Preview first, then post:

```bash
python3 scripts/qa_post.py "$QA_TICKET" --dry-run     # shows exactly what would post
python3 scripts/qa_post.py "$QA_TICKET"               # comment Trello + PR, attach shots, move card
```

`qa_post.py` reads the verdict from `qa-telemetry.json` (override with
`--verdict`). It posts **two Trello comments** — one from `qa-summary-dev.md`
(👨‍💻 Developer summary) and one from `qa-summary-qa.md` (🧪 QA / UX summary),
each with its own audience header — then posts `qa-report.md` to the PR,
attaches every screenshot, and moves the card by verdict (only if the
`TRELLO_LIST_*` ids are configured). If only one of the two summary files
exists it posts just that one; if **neither** exists it falls back to a single
legacy comment from `qa-trello-summary.md` (then `qa-report.md`). It skips
Trello/GitHub gracefully when creds or the PR url are absent. **If the user
asked only to verify locally, stop after Step 7 / `--dry-run` and don't
post.**

### Step 8b — Attach evidence to the Trello card only (no PR)

When the user wants the QA evidence on the **Trello card** but not the PR
(e.g. "attach the QA report to the ticket"), use `qa_attach.py`. It posts
the summary as a comment, attaches `qa-report.md` (as `QA-Report-<ticket>.md`),
and attaches every screenshot — **Trello only**.

```bash
python3 scripts/qa_attach.py "$QA_TICKET"             # attach report + shots + summary comment
```

**Duplicate-evidence guard (important):** before attaching, `qa_attach.py`
scans the card for **existing QA evidence** — prior QA report/screenshot
attachments (matching QA naming, so the ticket's own `image.png` design
files are ignored) and prior QA verdict comments. If it finds any, it
attaches **nothing** and exits **2** (`status: needs_confirmation`), listing
what is already there. When that happens, **show the user what already
exists and ASK before adding more** — only re-run with `--confirm` once they
agree:

```bash
python3 scripts/qa_attach.py "$QA_TICKET" --confirm   # add another round after the user confirms
```

Useful flags: `--no-comment` (files only), `--report-only` (skip
screenshots), `--card <id>` / `--out <dir>` (overrides).

## Remote mode (no local repos / dev-server UI)

Use this when the project repos are **not cloned locally** (and there are no
QA worktrees). Instead of a local checkout + locally-started servers, the
skill resolves everything from **GitHub** and tests the UI on the **deployed
dev server**. Trigger it when the user says "I don't have the repos", "test
via GitHub / on dev", or when `qa_prepare.py` reports missing worktrees and
you can't create them.

**Config (in addition to the usual):** `MAIN_REPO_SLUG`, `WEB_REPO_SLUG`
(GitHub `owner/repo`, defaults set), `QA_ADMIN_DEV_URL` (the deployed Blazor
Admin URL — **must be set** for the remote admin tier), `QA_ESHOP_DEV_URL`
(defaults to `https://ss-dev.dserve.app`). `gh auth login` must be done.

How the steps change:

- **Step 1 — prepare:** `python3 scripts/qa_prepare.py "<ref>" --remote`.
  It resolves the PR via `gh pr list --repo <slug>` (no cwd), pulls the diff
  via `gh pr diff`, and writes the inputs — **no worktree, no checkout**.
  Do NOT set `QA_REPO_ROOT`. Read its JSON summary (`mode: remote`).
- **Step 2 — recon:** there are no local files to `Grep`. Read individual
  source files at the PR head straight from GitHub:
  `tools/gh_file.sh <slug> <path> <head_sha>` (e.g. to resolve a Radzen
  selector in a `.razor`, or to confirm code-evidence in a `.cs`).
- **API / code tier:** there is no local build, so you **cannot** run live
  xUnit. API/back-end AC become **code-evidence** from the diff + `gh_file.sh`
  reads — cite file:line; verdict `PARTIAL_PASS` (or `FAIL`/`AC_DRIFT`).
- **UI tier:** run against the dev server (no local server start):
  ```bash
  "$QA_AGENT_ROOT/runners/ui-tier-remote.sh"     "$QA_OUT_DIR/playwright"   # Admin on $QA_ADMIN_DEV_URL
  "$QA_AGENT_ROOT/runners/eshop-tier-remote.sh"  "$QA_OUT_DIR/playwright"   # eshop on $QA_ESHOP_DEV_URL
  "$QA_AGENT_ROOT/runners/orders-tier-remote.sh" "$QA_OUT_DIR/playwright"   # KDS on $QA_ORDERS_DEV_URL
  ```
- **Honesty rule (critical):** the dev server reflects what is **DEPLOYED**
  (usually `master`), NOT the open PR branch. If a tested AC's feature is
  **absent on dev**, that almost always means *the PR isn't deployed yet* —
  verdict `NEEDS_HUMAN` with reason "PR not deployed to dev; re-run after
  deploy", **not** `FAIL`. Only treat it as real behavior if the PR is merged
  and deployed. State this clearly in the report. Because of this, remote
  runs typically land at `QA_APPROVED_WITH_GATES` or `QA_NEEDS_HUMAN` rather
  than a hard `QA_APPROVED`.
- **Publish (Step 8 / 8b):** identical — `qa_post.py` / `qa_attach.py` work
  the same (they only need the card + the written outputs).

## Hard rules (carried over from the qa-runner agent)

- **Always Write `qa-report.md` + the two Trello summaries
  (`qa-summary-dev.md` + `qa-summary-qa.md`) before the verdict** (the legacy
  single `qa-trello-summary.md` is only a fallback). This is the single most
  common failure mode — don't be it.
- **Any UI change ⇒ a GENUINE QA screenshot, ALWAYS** (Step 5b). The card's
  own design/mockup/Figma image is NOT evidence — never attach it as such.
  Force gated/hard-to-reach UI open (API mock, redux injection, isolated
  render) and capture the real pixels. Truly un-capturable → `QA_NEEDS_HUMAN`
  + `--allow-no-shots`. Publish scripts refuse (exit 3) otherwise.
- **Never touch production source** (anything outside test projects /
  `QaScratch/`). Found a prod bug? Report it; don't fix it.
- **Never `git push`/commit, never open/comment PRs or move cards yourself**
  — that's `qa_post.py`'s job, and only when the user wants it posted.
- **Never log secrets** (admin password, connection strings, tokens). Pass
  credentials to Playwright via env, never bake them into a generated spec.
- **Scope test runs** with `--filter "FullyQualifiedName~QaScratch.T<ticket>"`.
- **Always `--reporter=json`** for Playwright; parse the JSON.
- Generated scratch tests are **ephemeral** — they live in the worktree /
  `$QA_OUT_DIR`; don't commit them. The next `qa_prepare.py` resets the
  worktree (`git reset --hard` + `clean -fd`).

## Failure modes (handle gracefully — playbook §12)

| Situation | Action |
|---|---|
| No AC found | Report it; verdict `QA_NEEDS_HUMAN` |
| No PR + no eshop label | `qa_prepare.py` stops with `QA_NEEDS_HUMAN` |
| `dotnet build` fails | Mark API AC `FAIL` with the error; continue to UI |
| Admin won't start / login fails | Mark UI AC `NEEDS_HUMAN` with the log; continue with API |
| Port `:5080`/`:5173` in use | Runner fails fast — tell the user, don't pick a random port |
| UI tier unavailable (`QA_UI_TIER_AVAILABLE=0`) | Downgrade admin-ui AC to `code-evidence` from the diff — NOT all `NEEDS_HUMAN` |

Always write the report + telemetry no matter how partial. Always end with
the verdict. Never exit silently.

## Updating the knowledge base

When you discover a new confirmed selector or gotcha, **append** it (Edit
tool, append-only) to the right `knowledge/*.md` file — never rewrite,
never delete. That's how this skill gets more accurate over time.

## Files in this skill

```
SKILL.md                  ← this file (the QA protocol)
README.md                 ← setup + usage + what was/wasn't extracted
config/qa-skill.env(.example)   ← non-secret config (committed)
config/.secrets(.example)       ← secrets only (gitignored: tokens + passwords)
scripts/lib.sh            ← source first: env setup (port of helpers.agent_env)
scripts/qa_setup.py       ← first-run gate / doctor: detect missing vars+creds+tools, --init scaffolds config
scripts/qa_prepare.py     ← resolve PR + checkout + collect inputs (pipeline §0-4); --remote = GitHub-only, no checkout
scripts/qa_post.py        ← publish to Trello + PR (pipeline §6-10): two Trello comments (dev + qa/ux summaries; legacy single-summary fallback), full report → PR, supports --dry-run
scripts/qa_attach.py      ← attach evidence to Trello card only; guards vs duplicate QA evidence (asks before re-attaching)
prompts/qa-card.md        ← the authoritative QA playbook (read every run)
knowledge/*.md            ← confirmed selectors, flows, lessons (read every run)
runners/*.sh              ← api / ui / eshop / cross-system / orders tiers + install-playwright
runners/*-remote.sh       ← ui / eshop / orders tiers against the deployed dev server (remote mode)
templates/*.tmpl          ← xUnit + Playwright spec scaffolds (incl. orders-login / orders-spec)
tools/{kc.sh,trello.sh}   ← Keychain + Trello REST wrappers
tools/gh_file.sh          ← read a repo file from GitHub at a ref (remote-mode source recon)
```
