---
name: qa-ticket[obsolete]
description: >
  Fully automated QA validation for a Trello ticket. Fetches acceptance criteria,
  finds the associated PR(s) in self-service-web and/or dserve-backend, builds
  each project, starts local servers (eshop dev server + Admin Blazor app), runs
  Playwright E2E tests against each surface, supports cross-system tests (Admin
  action → eshop effect), and produces a static HTML dashboard with verdict
  (PASS / FAIL / NEEDS REVIEW) per AC item.
args:
  ticket: "Trello ticket number (4-digit integer, e.g. 4684)"
---

# QA Ticket Skill

You are an automated QA engineer. Your job: given a Trello ticket number, determine
conclusively whether the feature is ready to ship. You leave no ambiguity — every
acceptance criterion gets a PASS, FAIL, or NEEDS_REVIEW verdict with evidence.

## Step 1 — Parse ticket number

The `args.ticket` value may arrive as a raw number (`4684`), a URL, or a Trello card
short link. Extract the 4-digit (or more) integer:

```
ticket_num = args.ticket.match(/\d{4,}/)[0]
```

If no number found, stop and tell the user: "Please provide a Trello ticket number."

## Step 2 — Fetch Trello card

Use the Trello REST API. Credentials come from environment variables already set in
`.claude/settings.json`:

```bash
TRELLO_API_KEY=a0d72aeceb06a9829c7cef5a5934487a
TRELLO_TOKEN=<from env>
```

**Search for the card by number across all boards:**

```bash
curl -s "https://api.trello.com/1/search?query=${ticket_num}&idBoards=me&modelTypes=cards&cards_limit=5&card_fields=name,desc,shortUrl,idShort&key=${TRELLO_API_KEY}&token=${TRELLO_TOKEN}"
```

Match the card where `idShort == ticket_num`. Extract:
- `card.id` — for checklist fetch
- `card.name` — ticket title
- `card.desc` — may contain acceptance criteria in markdown
- `card.shortUrl` — for reporting

**Fetch checklists (acceptance criteria often live here):**

```bash
curl -s "https://api.trello.com/1/cards/${card_id}/checklists?key=${TRELLO_API_KEY}&token=${TRELLO_TOKEN}"
```

Parse all checklists. Look for ones named "Acceptance Criteria", "AC", "Definition of Done",
or similar. Collect all checklist items as structured AC items:

```json
[
  { "id": "ac-1", "text": "Color set in Admin is reflected in eshop", "checklist": "Acceptance Criteria" },
  { "id": "ac-2", "text": "Admin shows validation error for empty color", "checklist": "Acceptance Criteria" }
]
```

If the card description contains a markdown list with AC-like items (lines starting with
`- [ ]`, `- [x]`, or numbered items under an "Acceptance Criteria" heading), include those too.

If no AC found anywhere, note "No structured acceptance criteria found" and proceed with
a best-effort inference from the card title and description.

## Step 3 — Find the PR

Search GitHub for a PR referencing this ticket number. Check both repos in parallel:

```bash
# self-service-web
gh pr list --repo MaistoMyletojai/self-service-web --search "[${ticket_num}]" --state all --json number,title,headRefName,url,state

# dserve-backend
gh pr list --repo MaistoMyletojai/dserve-backend --search "[${ticket_num}]" --state all --json number,title,headRefName,url,state
```

Also try searching without brackets if the above returns empty:
```bash
gh pr list --repo MaistoMyletojai/self-service-web --search "${ticket_num}" --state all --json number,title,headRefName,url,state
gh pr list --repo MaistoMyletojai/dserve-backend --search "${ticket_num}" --state all --json number,title,headRefName,url,state
```

Collect all matching PRs. For each PR, note:
- `pr.number`, `pr.title`, `pr.headRefName` (branch name), `pr.url`, `pr.state`

If no PR found in either repo, report "No PR found for ticket #${ticket_num}. Cannot run build/test validation." and skip to Step 9 (dashboard with NEEDS_REVIEW for all AC).

## Step 4 — Determine scope

Analyze which repos have PRs and classify each AC item to understand what surfaces
need to be tested. This drives which servers to start and which test types to run.

**Scope flags:**
- `scope.web = true` — PR in `self-service-web`
- `scope.admin = true` — PR in `dserve-backend` (Admin Blazor app at `http://localhost:5030`)
- `scope.cross_system = true` — BOTH `scope.web` AND `scope.admin` are true

**Cross-system detection:** If both scopes are active, look at AC items for keywords that
suggest an Admin action should produce a visible effect in the eshop — e.g.:
- "color set in Admin", "setting changed in Admin", "edited in Admin", "configured in Admin"
- "appears in eshop", "reflected in shop", "visible in self-service", "applied to eshop"

Tag those AC items as `cross_system: true`. They require both servers running simultaneously
and a test that spans Admin action then verifies eshop effect.

**Scope matrix:**

| web PR | backend PR | Servers to start | Tests to run |
|--------|-----------|-----------------|--------------|
| yes    | no        | eshop dev server | Eshop Playwright |
| no     | yes       | Admin app        | Admin Playwright + API curl |
| yes    | yes       | Both in parallel | Eshop + Admin + Cross-system |

## Step 4b — Load eshop knowledge base (if scope.web)

Before writing any Playwright tests, read the knowledge files in this skill's `knowledge/` directory.
They contain confirmed selectors, flow patterns, API intercept recipes, and hard-won gotchas from
previous QA runs. Using them prevents repeating known mistakes.

**Read all four files when `scope.web = true`:**

1. `knowledge/eshop-selectors.md` — confirmed data-testids, class selectors, `page.evaluate()` patterns
2. `knowledge/eshop-flows.md` — navigation flows (categories first!), modal handling, Google Places steps, full delivery E2E reference
3. `knowledge/eshop-api-intercept.md` — request/response intercept patterns, known routes, timing notes
4. `knowledge/lessons-learned.md` — critical gotchas: test file location (`tests/specs/`), .env.local setup, .NET 8 issue, `__dirname` in ESM, screenshot directory creation

**Apply this knowledge when:**
- Deciding where to place generated test files → always `tests/specs/`
- Writing selectors → use confirmed testids before guessing
- Writing navigation steps → always click category before looking for products
- Writing Google Places steps → use `.pac-item`, wait 10s, select nth(1) for 2nd option
- Writing API intercept → use the passive listener pattern unless one-shot is clearer
- Checking for .NET 8 runtime before attempting Admin tests

**After each QA run, update the knowledge files** if you discovered:
- A new confirmed selector → append to `eshop-selectors.md`
- A new working flow pattern → append to `eshop-flows.md`
- A new API route or intercept trick → append to `eshop-api-intercept.md`
- A new gotcha or environment quirk → append to `lessons-learned.md`

This self-updating knowledge base is how the skill gets smarter with each run.

## Step 5 — Checkout PR branch

For each repo with a PR, save the current branch first, then checkout:

```bash
# self-service-web (if scope.web)
cd /Users/DSERVE/Documents/GitHub/self-service-web
WEB_PREV_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch origin
git checkout ${web_pr.headRefName}
git pull origin ${web_pr.headRefName}

# dserve-backend (if scope.admin)
cd /Users/DSERVE/Documents/GitHub/dserve-backend
BACKEND_PREV_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch origin
git checkout ${backend_pr.headRefName}
git pull origin ${backend_pr.headRefName}
```

## Step 6 — Build verification

Run builds. Fail fast per surface: if a build fails, mark its AC items as FAIL but
continue testing the other surface if it built successfully.

### Frontend (if scope.web)
```bash
cd /Users/DSERVE/Documents/GitHub/self-service-web
npm install --prefer-offline 2>&1 | tail -5
npm run build 2>&1 | tail -20
```

### Backend / Admin (if scope.admin)
```bash
cd /Users/DSERVE/Documents/GitHub/dserve-backend
dotnet build --no-restore 2>&1 | tail -20
```

If either build fails, capture the last 50 lines as `build_error` for that scope.

## Step 7 — Start local servers

Start all required servers. When both are needed (cross-system scope), start them in parallel.
Track PIDs for cleanup in Step 13.

### 7a — Eshop dev server (if scope.web)

```bash
cd /Users/DSERVE/Documents/GitHub/self-service-web
VITE_API_URL=https://ss-dev.dserve.app npm run dev -- --port 5173 &
ESHOP_PID=$!
```

Poll until ready (timeout 60s):
```bash
timeout=60; elapsed=0
until curl -s http://localhost:5173 > /dev/null; do
  sleep 2; elapsed=$((elapsed+2))
  [ $elapsed -ge $timeout ] && echo "TIMEOUT" && break
done
```

### 7b — Admin Blazor app (if scope.admin)

**Pre-check: .NET 8 runtime required**

The Admin project targets `net8.0`. Before starting, verify the runtime is available:

```bash
dotnet --list-runtimes | grep "Microsoft.AspNetCore.App 8"
```

If .NET 8 is NOT listed:
- Mark all admin-scope AC items as NEEDS_REVIEW with reason:
  "Admin requires .NET 8 runtime. Installed: $(dotnet --version). Install: brew install dotnet@8"
- Skip to cleanup. Do NOT attempt to start the Admin app with roll-forward — it will start
  but blazor.server.js will return 404, making the UI unreachable in a browser.

If .NET 8 IS available, start the Admin app using the exact env vars from launchSettings.json:

```bash
cd /Users/DSERVE/Documents/GitHub/dserve-backend
DOTNET_ROLL_FORWARD=Disabled \
ASPNETCORE_HOSTPORT=5030 \
ASPNETCORE_ENVIRONMENT=Development \
ASPNETCORE_CONNECTIONSTRING="Server=tcp:dserve.cbv4zcks9dsh.eu-west-1.rds.amazonaws.com,1433;Initial Catalog=dserve2;Persist Security Info=False;User ID=dserve;Password=x9c8EBMJ6DHxjB1tcM;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=True;Connection Timeout=600;" \
dotnet run --project Dserve.Admin/ &
ADMIN_PID=$!
```

Poll until ready (timeout 90s — dotnet cold start is slower than Node):
```bash
timeout=90; elapsed=0
until curl -s http://localhost:5030 > /dev/null 2>&1; do
  sleep 3; elapsed=$((elapsed+3))
  [ $elapsed -ge $timeout ] && echo "TIMEOUT" && break
done
```

After server is up, verify Blazor assets load (not 404):
```bash
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5030/_framework/blazor.server.js)
if [ "$HTTP_STATUS" != "200" ]; then
  echo "BLAZOR_BROKEN: blazor.server.js returned $HTTP_STATUS — Admin UI unreachable"
  # Mark admin AC items NEEDS_REVIEW, continue with any eshop tests
fi
```

If Admin times out or Blazor assets missing: mark all admin-scope AC items as NEEDS_REVIEW with reason
"Admin server failed to start or Blazor assets unavailable — manual verification required." Continue eshop tests.

## Step 8 — Admin login (if scope.admin)

The Admin app requires authentication. Use Playwright to log in once and save the
session state for reuse across all Admin tests (avoids logging in per test).

```typescript
// /tmp/qa-admin-auth-${ticket_num}.ts
import { chromium } from '@playwright/test'

const ADMIN_URL = 'http://localhost:5030'

;(async () => {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  await page.goto(ADMIN_URL)
  await page.waitForLoadState('networkidle')

  // Fill login form — selectors may vary, try multiple fallbacks
  await page.fill(
    'input[type="email"], input[name="email"], input[placeholder*="email" i]',
    'kestutis@dserve.app'
  )
  await page.fill('input[type="password"]', 'Cigonas123')
  await page.click('button[type="submit"], button:has-text("Login"), button:has-text("Sign in")')
  await page.waitForNavigation({ waitUntil: 'networkidle' })

  // Save authenticated session for all subsequent tests
  await page.context().storageState({ path: '/tmp/qa-admin-state-${ticket_num}.json' })
  await browser.close()
})()
```

Run via:
```bash
cd /Users/DSERVE/Documents/GitHub/self-service-web
npx ts-node /tmp/qa-admin-auth-${ticket_num}.ts 2>&1
```

If login fails, mark all admin + cross-system AC items as NEEDS_REVIEW:
"Admin login failed — check credentials or login page selectors."

## Step 9 — Generate and run Playwright tests

Write all tests to temp files. Never commit them to any repo.

### 9a — Check for existing ticket-specific tests

```bash
find /Users/DSERVE/Documents/GitHub/self-service-web/e2e \
     /Users/DSERVE/Documents/GitHub/dserve-backend -name "*.spec.ts" 2>/dev/null \
  | xargs grep -l "${ticket_num}" 2>/dev/null
```

If found, run them first and merge their results before generating new ones.

### 9b — Eshop tests (if scope.web)

```typescript
// /tmp/qa-eshop-${ticket_num}.spec.ts
import { test, expect } from '@playwright/test'

const ESHOP_URL = 'http://localhost:5173'

test.describe('Ticket #${ticket_num} — Eshop: ${ticket_title}', () => {
  test.beforeEach(async ({ page }) => {
    const token = process.env.QA_TABLET_TOKEN || ''
    await page.goto(`${ESHOP_URL}/?tabletToken=${token}`)
    await page.waitForLoadState('networkidle')
  })

  // One test per eshop-scoped AC item — generated from AC text
})
```

### 9c — Admin tests (if scope.admin)

```typescript
// /tmp/qa-admin-${ticket_num}.spec.ts
import { test, expect } from '@playwright/test'

const ADMIN_URL = 'http://localhost:5030'

// Reuse the authenticated session saved in Step 8
test.use({ storageState: '/tmp/qa-admin-state-${ticket_num}.json' })

test.describe('Ticket #${ticket_num} — Admin: ${ticket_title}', () => {
  // One test per admin-scoped AC item
  // Session already authenticated — no per-test login needed
})
```

### 9d — Cross-system tests (if scope.cross_system)

For AC items tagged `cross_system: true` (Admin change should appear in eshop):

```typescript
// /tmp/qa-cross-${ticket_num}.spec.ts
import { test, expect, chromium } from '@playwright/test'

const ADMIN_URL = 'http://localhost:5030'
const ESHOP_URL  = 'http://localhost:5173'

test.describe('Ticket #${ticket_num} — Cross-system: ${ticket_title}', () => {
  test('Admin change is reflected in eshop', async () => {
    // 1. Open Admin with saved auth state
    const browser = await chromium.launch()
    const adminContext = await browser.newContext({
      storageState: '/tmp/qa-admin-state-${ticket_num}.json'
    })
    const adminPage = await adminContext.newPage()
    await adminPage.goto(ADMIN_URL)
    await adminPage.waitForLoadState('networkidle')

    // 2. Open Eshop simultaneously
    const eshopContext = await browser.newContext()
    const eshopPage = await eshopContext.newPage()
    const token = process.env.QA_TABLET_TOKEN || ''
    await eshopPage.goto(`${ESHOP_URL}/?tabletToken=${token}`)
    await eshopPage.waitForLoadState('networkidle')

    // 3. Make the change in Admin (generated from AC text)
    // Example: await adminPage.fill('[data-field="primary-color"]', '#FF5500')
    //          await adminPage.click('button:has-text("Save")')
    //          await adminPage.waitForResponse(r => r.url().includes('/api/settings'))

    // 4. Reload eshop and assert the change is reflected
    // Example: await eshopPage.reload()
    //          await eshopPage.waitForLoadState('networkidle')
    //          await expect(eshopPage.locator('.btn-primary')).toHaveCSS('background-color', 'rgb(255, 85, 0)')

    await browser.close()
  })
})
```

**Key principle:** The Admin write must go through the real API (not mocked) so the
eshop fetches the updated value on reload. Test the full database round-trip.

### 9e — AC item to test mapping guide

| AC describes... | Test approach |
|----------------|--------------|
| UI element visible | `expect(page.getByRole(...)).toBeVisible()` |
| Button / form behavior | `await page.click(...)` then assert state |
| Value displayed | `expect(page.getByText(...)).toContainText(...)` |
| Color / CSS applied | `expect(locator).toHaveCSS('property', 'value')` |
| Admin setting appears in eshop | Cross-system test (9d) |
| API call is made | `page.route()` intercept, assert request body |
| Navigation | `expect(page.url()).toContain(...)` |
| Form validation | Submit empty → assert error message visible |
| Subjective UX / pixel-perfect design | NEEDS_REVIEW — manual check |

### 9f — UI Scenario Browsing (REQUIRED for any new UI element)

**This step is mandatory when the PR adds or modifies any visible UI component** (button, overlay, modal, floating element, banner, badge, drawer, tooltip, etc.).

The goal is to catch integration bugs that AC-level tests miss — like a floating button hidden behind a modal, a z-index conflict, or a component that breaks when other overlays are simultaneously open.

**Lesson learned from ticket #4684:** A screen-dimmer lamp button passed all AC tests but was hidden by the product modal on mobile — only caught by manual testing. This step makes that class of bug impossible to miss.

#### Step 9f-1 — Z-index audit (run first, takes 30 seconds)

Before writing any test, audit all z-index values to understand the stacking tiers in play:

```bash
grep -r "z-index\|zIndex" /Users/DSERVE/Documents/GitHub/self-service-web/src \
  --include="*.tsx" --include="*.ts" --include="*.css" \
  | grep -v node_modules \
  | grep -oP "(z-index|zIndex)[\s:"']+\K[0-9]+" \
  | sort -n | uniq -c | sort -rn | head -20
```

If the new element's z-index is **lower than any overlay that can appear at the same time** → that is a bug. Mark the relevant AC as FAIL immediately.

#### Step 9f-2 — Eshop UI scenario matrix

For every new visible UI element, walk through ALL of the following app states and assert the element is:
1. **Visible** — `isVisible()` returns true
2. **Not covered** — `elementFromPoint()` at its centre point returns the element (or its child), not a foreign overlay
3. **Functional** — `click()` succeeds and triggers the expected side-effect

```typescript
// Reusable helper — paste into every eshop spec that touches a persistent UI element
async function assertNotCovered(page: Page, selector: string, label: string) {
  const loc = page.locator(selector).first()
  await expect(loc, `${label}: should be visible`).toBeVisible()

  const box = await loc.boundingBox()
  if (!box) return

  const cx = Math.round(box.x + box.width / 2)
  const cy = Math.round(box.y + box.height / 2)

  const covered = await page.evaluate(
    ([x, y, sel]: [number, number, string]) => {
      const target = document.querySelector(sel)
      const top    = document.elementFromPoint(x, y)
      if (!target || !top) return false
      return !target.contains(top) && top !== target
    },
    [cx, cy, selector] as [number, number, string]
  )

  expect(covered, `${label}: covered by another layer — z-index conflict`).toBe(false)
}
```

**Scenarios to run for every new persistent UI element (desktop + mobile):**

| # | Scenario | Why it matters |
|---|----------|---------------|
| 1 | Home page loaded | Base state |
| 2 | Category clicked — product list visible | Route change |
| 3 | **Product tapped → product detail modal/drawer open** | Most common z-index trap |
| 4 | **Cart icon tapped → cart drawer open** | Another common overlay |
| 5 | Proceed to checkout screen | Deep flow state |
| 6 | Search input focused → results dropdown shown | Dropdown stacking |
| 7 | Page scrolled 50% (fixed/sticky elements) | Scroll position |
| 8 | After route navigation back (element re-mounts) | Lifecycle |
| 9 | API error toast shown | Toast z-index conflict |
| 10 | **Mobile (390×844): product modal open** | ← caught #4684 bug |
| 11 | **Mobile (390×844): cart drawer open** | Mobile overlay stack |
| 12 | **Mobile (390×844): checkout screen** | Full mobile flow |

Run each scenario in a fresh Playwright context. Call `assertNotCovered` after each state transition.

#### Step 9f-3 — Admin UI scenario matrix (if scope.admin)

For any new Admin UI element, walk through:

| # | Scenario |
|---|----------|
| 1 | Dashboard / root page |
| 2 | Entity grid page (e.g. /organizations, /products) |
| 3 | Row context menu open ("..." → popup) |
| 4 | Edit dialog open (via context menu → Edit) |
| 5 | Nested dialog open inside edit (e.g. Setup Telegram, color picker) |
| 6 | Delete confirmation dialog open |
| 7 | Form validation errors shown |

Assert the new element is visible and not covered in each state.

#### Step 9f-4 — Screenshot every scenario

```typescript
await page.screenshot({
  path: `/tmp/qa-${ticket_num}-scenario-${scenarioIndex}-${scenarioName.replace(/\s+/g, '-')}.png`,
  fullPage: false
})
```

After all tests, copy screenshots to `workspace/qa-results/${ticket_num}/screenshots/` and add entries to `result.json.screenshots[]` with `acId` set to the relevant AC.

#### Step 9f-5 — Console error scan

Attach error listeners before navigating to catch JS exceptions introduced by the PR:

```typescript
const jsErrors: string[] = []
page.on('pageerror', err => jsErrors.push(err.message))
page.on('console', msg => {
  if (msg.type() === 'error') jsErrors.push(msg.text())
})

// ... run all scenarios ...

// After all scenarios, check errors
const newErrors = jsErrors.filter(e => /* exclude known pre-existing errors */ true)
if (newErrors.length) {
  // Mark related AC as FAIL with error text as evidence
}
```

#### Scenario verdict rules

| Finding | Verdict for the AC |
|---------|--------------------|
| All scenarios: visible and not covered | PASS |
| Covered in ≥1 scenario (z-index conflict) | **FAIL** — name the scenario and the covering element |
| Missing on some routes (not mounted globally) | **FAIL** — list the routes |
| Visible but click has no effect | **FAIL** |
| Works desktop but fails mobile viewport | **FAIL** |
| New JS console errors from PR code | **FAIL** |
| Pre-existing console errors (reproduce on master) | Note in evidence only |

### 9g — Run all generated tests

```bash
cd /Users/DSERVE/Documents/GitHub/self-service-web

# Eshop
npx playwright test /tmp/qa-eshop-${ticket_num}.spec.ts \
  --reporter=json --output=workspace/qa-results/${ticket_num}/eshop-output \
  2>&1 > /tmp/qa-eshop-results-${ticket_num}.json

# Admin
npx playwright test /tmp/qa-admin-${ticket_num}.spec.ts \
  --reporter=json --output=workspace/qa-results/${ticket_num}/admin-output \
  2>&1 > /tmp/qa-admin-results-${ticket_num}.json

# Cross-system (if applicable)
npx playwright test /tmp/qa-cross-${ticket_num}.spec.ts \
  --reporter=json --output=workspace/qa-results/${ticket_num}/cross-output \
  2>&1 > /tmp/qa-cross-results-${ticket_num}.json
```

Merge all JSON results. Parse each: `suites[].specs[]` with `.ok`, `.status`, `.error`.

### 9h — API-level checks (pure backend AC items)

For AC items about API responses (no UI), use curl against the real dev API:

```bash
curl -s "https://ss-dev.dserve.app/api/settings" \
  -H "Authorization: Bearer ${TEST_TABLET_TOKEN}" | jq '.fieldName'
```

## Step 10 — Evaluate AC items

For each AC item, assign a verdict:

```
PASS         — Test ran and passed / API check confirmed
FAIL         — Test ran and failed (include error + line)
NEEDS_REVIEW — Subjective / visual / server failed / cross-system inconclusive
SKIPPED      — No PR in scope for this AC item
```

**Overall verdict:**
- All PASS (or PASS + NEEDS_REVIEW only) → `OVERALL: READY_FOR_REVIEW`
- Any FAIL → `OVERALL: FAILING`
- No AC or no PR found → `OVERALL: INCOMPLETE_DATA`

## Step 11 — Save JSON result

Write to `/Users/DSERVE/claude-agent/workspace/qa-results/${ticket_num}/result.json`.

### ⚠️ STRICT FIELD NAME RULES — DO NOT DEVIATE

Every item in `acItems` MUST use EXACTLY these field names:
- `"id"` — e.g. `"ac-1"`
- `"text"` — the full AC text verbatim from Trello. NEVER use `"title"`, `"name"`, or `"description"` here.
- `"scope"` — `"eshop"` | `"admin"` | `"cross_system"` | `"api"`
- `"verdict"` — `"PASS"` | `"FAIL"` | `"NEEDS_REVIEW"` | `"SKIPPED"`. NEVER use `"status"`.
- `"evidence"` — the test output or code review finding. NEVER use `"notes"` or `"details"`.
- `"testTitle"` — optional, the Playwright test name or code review reference

Using any other field name (`title`, `status`, `notes`, `description`, `details`) will cause the
dashboard to render blank AC items. This has happened before — do not repeat the mistake.

```json
{
  "ticket": "${ticket_num}",
  "title": "${ticket_title}",
  "trelloUrl": "${card.shortUrl}",
  "evaluatedAt": "${ISO timestamp}",
  "scope": {
    "web": true,
    "admin": true,
    "cross_system": true
  },
  "branch": {
    "web": "${web_branch}",
    "backend": "${backend_branch}"
  },
  "prUrls": ["${web_pr_url}", "${backend_pr_url}"],
  "buildStatus": {
    "web": "PASS | FAIL | SKIPPED",
    "admin": "PASS | FAIL | SKIPPED"
  },
  "overallVerdict": "READY_FOR_REVIEW | FAILING | INCOMPLETE_DATA",
  "acItems": [
    {
      "id": "ac-1",
      "text": "Full acceptance criterion text copied verbatim from Trello",
      "scope": "eshop | admin | cross_system | api",
      "verdict": "PASS | FAIL | NEEDS_REVIEW | SKIPPED",
      "evidence": "Test output / API response / code review finding",
      "testTitle": "Playwright test name or code review reference"
    }
  ],
  "buildErrors": { "web": null, "admin": null },
  "playwrightSummary": {
    "eshop":  { "total": 2, "passed": 2, "failed": 0 },
    "admin":  { "total": 1, "passed": 1, "failed": 0 },
    "cross":  { "total": 1, "passed": 0, "failed": 1 }
  }
}
```

## Step 12 — Generate HTML dashboard

Write to `/Users/DSERVE/claude-agent/workspace/qa-results/dashboard.html`.

Read all existing result files first:
```bash
find /Users/DSERVE/claude-agent/workspace/qa-results -name "result.json" | sort
```

Generate a static dark-theme HTML page (`#0d1117` background, GitHub-style) with:
- Summary bar: total evaluated, pass count, fail count, needs-review count
- Ticket cards (newest first) as `<details>` elements showing:
  - Overall verdict badge (green/red/yellow) — this reflects AC verdicts, NOT build status
  - AC score pills: `3 PASS · 2 FAIL · 1 NEEDS_REVIEW` — prominent, shows actual AC counts
  - Build status — shown SEPARATELY under a `BUILD:` label with small neutral tags (`Web: PASS`, `Admin: SKIPPED`). Must NOT look like an AC verdict. Must NOT be a large green badge.
  - Scope badges: `[Eshop]` `[Admin]` `[Cross-system]` (only those active)
  - PR links, branches, evaluated timestamp
  - AC item list: each item shows `text` field as headline, verdict badge, `evidence`, `testTitle`

Output path after writing:
```
Dashboard: /Users/DSERVE/claude-agent/workspace/qa-results/dashboard.html
```

## Step 13 — Cleanup and report

1. Stop all servers:
   ```bash
   kill $ESHOP_PID 2>/dev/null || true
   kill $ADMIN_PID 2>/dev/null || true
   ```
2. Delete all temp files:
   ```bash
   rm -f /tmp/qa-eshop-${ticket_num}.spec.ts \
         /tmp/qa-admin-${ticket_num}.spec.ts \
         /tmp/qa-cross-${ticket_num}.spec.ts \
         /tmp/qa-admin-auth-${ticket_num}.ts \
         /tmp/qa-admin-state-${ticket_num}.json \
         /tmp/qa-eshop-results-${ticket_num}.json \
         /tmp/qa-admin-results-${ticket_num}.json \
         /tmp/qa-cross-results-${ticket_num}.json
   ```
3. Ask user: "Restore branches to ${WEB_PREV_BRANCH} / ${BACKEND_PREV_BRANCH}? (y/n)"

**Final reply format (keep under 2000 chars):**

```
QA Report — Ticket #4821: Admin color setting applies to eshop

Scope: Eshop + Admin + Cross-system
Overall: FAILING

Acceptance Criteria:
  PASS  ac-1: Admin color picker visible [Admin]
  PASS  ac-2: Color saves via API [Admin]
  FAIL  ac-3: Color reflected in eshop buttons [Cross-system]
              Expected rgb(255,85,0) got rgb(0,122,255) — eshop using default
  WARN  ac-4: Accessibility contrast check [NEEDS_REVIEW — manual]

PRs:
  self-service-web #801 (feature/4821-theme-colors)
  dserve-backend #312   (feature/4821-venue-settings)

Tests: Eshop 2/2 PASS | Admin 1/1 PASS | Cross 0/1 FAIL

Dashboard: workspace/qa-results/dashboard.html
```

## Environment Notes

- **Real API**: Always test against `https://ss-dev.dserve.app` — never mock
- **Eshop (local)**: `http://localhost:5173`
- **Admin (local)**: `http://localhost:5030` — `dotnet run --project Dserve.Admin/` in `dserve-backend`
- **Admin credentials**: `kestutis@dserve.app` / `Cigonas123` (dev env only)
- **Admin login**: Playwright session saved to `/tmp/qa-admin-state-${ticket_num}.json`
- **Tablet token**: `process.env.QA_TABLET_TOKEN` for eshop auth
- **Playwright**: `npx playwright --version` — if missing: `npx playwright install chromium`
- **gh CLI**: `gh auth status`
- **Repos**: `MaistoMyletojai/self-service-web` and `MaistoMyletojai/dserve-backend`
- **Admin .NET requirement**: net8.0 — check with `dotnet --list-runtimes | grep "AspNetCore.App 8"`. Install: `brew install dotnet@8`
- **No local DB needed**: Backend uses MongoDB Atlas remote

## Error Handling

| Situation | Action |
|-----------|--------|
| Trello API 401 | Report credential error — check TRELLO_API_KEY / TRELLO_TOKEN |
| Card not found | "No card found for #${ticket_num}. Check the number." |
| No PR found | Mark all AC SKIPPED. Report: "Feature may not be implemented yet." |
| Web build fails | Mark eshop AC FAIL. Continue Admin tests if in scope. |
| Admin build fails | Mark admin AC FAIL. Continue eshop tests if in scope. |
| Eshop server timeout | Mark eshop AC NEEDS_REVIEW. Run admin/API-only checks. |
| Admin server timeout | Mark admin AC NEEDS_REVIEW. Continue eshop tests if in scope. |
| Admin login fails | Mark admin + cross-system AC NEEDS_REVIEW. Eshop tests still run. |
| Playwright missing | Run `npx playwright install chromium` automatically, then retry. |
| gh not authenticated | Tell user: "Run: gh auth login" |
| Cross-system test inconclusive | Mark NEEDS_REVIEW with specific manual verification steps. |
