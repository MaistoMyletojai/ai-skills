# QA Card Playbook

Detailed loop for the `qa-runner` agent. Adapted from the open-source
qa-ticket skill (credit: dserve internal) and specialised for the
Dserve.SelfServiceApi + Dserve.Admin scope.

## 1. Inputs

The orchestrator places these on disk before invoking you:

- `/tmp/qa-ticket.json` — `{ id, idShort, name, desc, shortUrl, labels, idList, checklists }`
- `/tmp/qa-pr.json` — `{ number, url, headRefName, state, repository, files }`
- `/tmp/qa-diff.patch` — full diff of the PR head vs `origin/master`
- env vars:
  - `QA_OUT_DIR` — directory for all your outputs and scratch files
  - `QA_TICKET` — the ticket number as a string
  - `QA_API_PORT` (default `5070`), `QA_ADMIN_PORT` (default `5080`)
  - `QA_ADMIN_EMAIL`, `QA_ADMIN_PASSWORD` — Blazor login
  - `QA_REPO_ROOT` — absolute path to the dserve-backend QA worktree
    (you should already be `cd`'d there)

`QA_OUT_DIR` is your sandbox for everything per-run. Treat `/tmp` as
read-only for inputs; outputs go to `$QA_OUT_DIR`.

## 2. Parse acceptance criteria

AC live in **the card description**, not Trello checklists, in your
team's convention. The shape is:

```
## Acceptance Criteria
- [ ] Item one — verifiable statement
- [ ] Item two — another statement
- [ ] Unit / integration tests updated
- [ ] No regressions in related flows
```

Strip the last two boilerplate items (they're not testable AC — they're
process checkboxes). For each remaining item, assign a stable id
`ac-<n>` (1-based).

If no `## Acceptance Criteria` section exists, fall back to inferring AC
from the title + description prose. Mark all such AC `verdict_confidence: low`
in telemetry — the agent's interpretation may be wrong, so flag it.

If the card has **Trello checklists** in addition (rare in Dserve), merge
those items in.

## 3. Classify each AC

Each AC gets one of:

| tier            | use when AC describes…                                      |
|-----------------|-------------------------------------------------------------|
| `api`           | An endpoint response, side-effect on the DB, a service-layer behavior testable through the API |
| `admin-ui`      | A Blazor admin page, form, button, validation, list row     |
| `eshop-ui`      | A self-service-web (eshop) page, flow, modal, cart, checkout — runs via Playwright against the Vite dev server on `:5173` |
| `orders-ui`     | An orders-dashboard (web KDS) view — order board, kitchen workflow, location/order views. Playwright against the Vite dev server on `:$QA_ORDERS_PORT` (default 3000). Login-based; `orders-tier.sh` logs in + saves storageState. Physical receipt/ePOS printing is NOT driveable → `code-evidence`/`manual`. Read `knowledge/orders-dashboard.md` first |
| `cross-system`  | Admin write → effect visible in eshop (e.g. "color set in Admin shows in eshop", "menu change appears for customers"). Now SUPPORTED via two-context Playwright pattern — see `eshop-flows.md` Flow 7 |
| `code-evidence` | AC references external state the agent can't reach (live MDM device, third-party SaaS, real fiscal printer, prod-only data), BUT the implementation can be verified by reading the diff — confirm specific function calls / route changes / structural patterns that prove the code does what the AC says |
| `manual`        | Visual regression, pixel-perfect design, multi-device matrix, anything subjective |
| `skipped`       | Out of QA scope (other API, third-party only, infra-only) |

Decision rules — use **Trello labels FIRST**, then diff hints:

**Step A — Read the labels.** `/tmp/qa-ticket.json` has a `labels` array.
Each label has a `name`. Inspect those names BEFORE looking at the
diff:

| Trello label name (case-insensitive)        | Forces scope to    |
|---------------------------------------------|--------------------|
| `E-shop / QR`, `eshop`, `qr`, `webshop`     | `eshop-ui`         |
| `KDS`, `orders-dashboard`, `orders dashboard` | The **KDS / orders-dashboard system**. User-facing surface = **orders-dashboard** (`orders-ui`); its backend = **`KdsController`** in `Dserve.SelfServiceApi` (routes `api/kds/*`). So: a KDS PR in **orders-dashboard** → `orders-ui`. A KDS PR in **dserve-backend** that touches `KdsController` → `api` tier (xUnit on the `api/kds/*` endpoints) **and** verify the consuming orders-dashboard UI (`cross-system`, or `code-evidence` for propagation if the backend change isn't deployed). Don't treat a KDS ticket as backend-only — it's the dashboard system end-to-end |
| `Admin`, `Admin UI`                         | `admin-ui`         |
| `SelfServiceApi`, `Self Service API`, `api` | `api`              |

The label is the **authoritative signal** of intended scope. Even if
the PR diff is empty, missing, or unmappable, an `E-shop / QR` label
means this is an eshop card and the eshop tier is the right place to
verify. Don't override label-based scope with "the diff doesn't touch
self-service-web" reasoning — for a CSS fix that was already merged
and the branch was deleted, the diff isn't visible to you, but the
label still tells you which surface.

**Step B — Then use diff hints to refine:**

- If the diff touches `Dserve.SelfServiceApi/**` and AC describes API
  behavior → `api`.
- If diff touches `Dserve.Admin/**` and AC describes UI → `admin-ui`.
- If diff touches the **self-service-web repo** (source at `$WEB_REPO_DIR`,
  QA worktree at `$WEB_REPO_QA`) and AC describes eshop UI → `eshop-ui`. Read
  `knowledge/eshop-selectors.md`, `eshop-flows.md`,
  `eshop-api-intercept.md` before writing the spec.
- If BOTH `dserve-backend` AND `self-service-web` have changes AND the
  AC says "Admin change should appear in eshop" (or vice versa) →
  `cross-system`. Use the two-context Playwright pattern from
  `eshop-flows.md` Flow 7. Both servers run simultaneously (Admin on
  `:5080`, eshop on `:5173`).

**Step C — When there's NO PR + NO branch found:**

- If the card has an **eshop label** (`E-shop / QR` etc.), the
  orchestrator will already have checked out `main` in
  `$WEB_REPO_QA` for you. The diff at `/tmp/qa-diff.patch` will be
  empty — that's expected. You're verifying **current production
  behavior on `main`** against the AC, not a PR diff.

  Example: card title "Fix language button cutoff on iPhone" + empty
  diff → write a mobile-viewport (390×844) Playwright spec that
  asserts the language button is fully visible. PASS if currently
  fixed on main, FAIL with a screenshot if still broken.

- If the card has no eshop label and no PR was found, the
  orchestrator already short-circuited to `QA_NEEDS_HUMAN` before
  invoking you. You will not see this case.

**Step D — If the card description has NO AC section** (just a bug
report + screenshot, like "Fix language button cutoff on iphone"):

- Read the card title carefully — it usually states the intended fix.
- Read any attached screenshots via the `Read` tool (you're
  multimodal) — they show the bug state.
- Infer 1-2 AC items from the title + screenshot:
  - title "Fix language button cutoff on iPhone" + cutoff screenshot
    → infer `ac-1: Language button is fully visible at iPhone
    viewport (390×844), no text cutoff`.
- Mark these inferred AC with `verdict_confidence: low` in the report
  so the human knows the agent paraphrased.
- Proceed with verification as usual.
- **If AC binds to live external state** (e.g. "device SN `Y6DX9NFQ9G`
  appears", "the order from Mosyle tenant X resolves", "specific
  customer from prod") → `code-evidence`. The agent reads the diff,
  confirms structural correctness, and emits PARTIAL_PASS evidence.
- **If `QA_UI_TIER_AVAILABLE=0` env is set** (admin creds missing),
  downgrade every `admin-ui` AC to `code-evidence` and note the reason.
  Do NOT mark them all `NEEDS_HUMAN` — the diff still tells you most of
  what you need to know.
- If AC contains words like "looks", "design", "visual", "color
  matches mockup" → `manual`.
- When in doubt, prefer `code-evidence` over `manual` if you can read
  the diff, and `manual` over guessing if you can't.

Print `STAGE: classifying AC` before this step. After classification, print:
```
classified: api=N admin-ui=N code-evidence=N cross-system=N manual=N skipped=N
```

## 3b. AC drift detection

While classifying, watch for **AC ↔ implementation mismatches**: AC that
describe behavior the diff does not implement. Common shapes:

- AC says "list all X" but diff only adds a lookup-by-key
- AC says "add field Y" but diff adds field Z with similar semantics
- AC says "validate against Z" but diff has no validation logic
- AC describes a feature the PR genuinely doesn't address (scope mismatch)

When detected, emit verdict `AC_DRIFT` for that AC with evidence:
"AC asks for X, but diff shows Y in `<file>`. Either reword the AC to
match shipped behavior, or file a follow-up if X is genuinely required."

`AC_DRIFT` does NOT make the overall verdict `QA_REJECTED` — it's a
process flag, not a code defect. Aggregate it under `QA_NEEDS_HUMAN`
because a PM/dev needs to decide whether the AC or the implementation
is wrong.

## 4. API tier — generate xUnit tests

For each `api` AC:

1. Read 2-3 of the existing tests in `Dserve.SelfService.Integration/`
   that touch the same controller. Mirror their style exactly.
2. Identify the controller and the routes from `Dserve.Core.SelfServiceApiRoutes`.
3. Read the DTO shapes from `Dserve.Contracts.*` for any payloads.
4. Create the test file:
   `Dserve.SelfService.Integration/QaScratch/<TICKET>/AC<n>_<ShortName>Tests.cs`

   ```csharp
   using System.Net;
   using System.Threading.Tasks;
   using Dserve.Contracts.<Area>;
   using Dserve.Core.SelfServiceApiRoutes;
   using FluentAssertions;
   using Xunit;
   using static Dserve.Core.SelfServiceApiRoutes.SelfServiceApiRoutes;

   namespace Dserve.SelfService.Integration.QaScratch.T<TICKET>
   {
       public class AC<N>_<ShortName>Tests : IntegrationTest
       {
           [Fact(DisplayName = "AC<n>: <verbatim AC text, escaped>")]
           public async Task <Specific_Behavior>_<ExpectedOutcome>()
           {
               // arrange
               await AuthenticateAsync();

               // act
               var response = await TestClient.GetAsync(SelfServiceApiRoutes.<Base>);

               // assert
               response.StatusCode.Should().Be(HttpStatusCode.OK);
               // … specific assertions for this AC …
           }
       }
   }
   ```

   The `[Fact(DisplayName = "AC<n>: ...")]` is **important**: it lets us
   correlate xUnit output back to AC ids in step 7.

5. Write one `[Fact]` per AC (sometimes two if the AC has a clear
   happy-path + failure-mode). Keep them short — no fixture frameworks,
   no helpers beyond what's in `IntegrationTest` + `Common/TestData.cs`.

6. Build before running, to catch compile errors early:
   ```bash
   dotnet build Dserve.SelfService.Integration/Dserve.SelfService.Integration.csproj
   ```
   If build fails, mark all `api` AC `FAIL` with the build error as
   evidence — do not attempt to fix the build (production-code changes
   are out of your scope).

7. Run only your scratch tests:
   ```bash
   dotnet test Dserve.SelfService.Integration/Dserve.SelfService.Integration.csproj \
     --filter "FullyQualifiedName~QaScratch.T<TICKET>" \
     --logger "trx;LogFileName=$QA_OUT_DIR/api-results.trx" \
     --logger "console;verbosity=normal"
   ```
   Parse the `.trx` (XML) to get per-test pass/fail + error message.

## 5. Admin UI tier — Playwright

For each `admin-ui` AC:

1. Read all `*.md` files in `$QA_AGENT_ROOT/knowledge/` — they
   contain confirmed selectors and lessons-learned from previous runs.

2. **Source reconnaissance — MANDATORY before writing any UI spec.**
   The diff only shows the delta; the parent .razor files determine
   the actual selectors. For each `admin-ui` AC, before generating the
   spec:

   a. Identify the page(s) the AC targets. From the diff hunks, the
      URL in the card description, or from the AC wording itself
      ("Settings → Extra" → `Pages/Settings/`, "Dynamic Pricing" →
      `Pages/DynamicPricing/`).

   b. `Grep` for the actions the AC names (Edit, Delete, Save, Add,
      Find, Confirm, Cancel, etc.) in the relevant `.razor` files:
      ```
      Grep -rn "Edit\|RadzenButton.*Edit\|Icon=\"edit\"\|Icon=\"pencil\"" \
        Dserve.Admin/Pages/<area>/
      ```
      This tells you whether Edit is:
      - A text button (`<RadzenButton Text="Edit"`)
      - An icon-only button (`<RadzenButton Icon="edit"` or
        `<RadzenButton Icon="pencil"` — both common in Dserve.Admin)
      - A context menu item (`<RadzenMenuItem Text="Edit"`)
      - A raw icon click handler (`<RadzenIcon Icon="edit"
        @onclick=...`)
      - A row-action handler (`Click="@(args => Edit(args.Data))"` on
        a DataGrid row, no per-row button at all)

   c. For each interactive element you'll need (open, click, fill,
      assert), record the resolved selector. The mapping is:

      | Razor pattern                           | Playwright selector                                  |
      |-----------------------------------------|------------------------------------------------------|
      | `<RadzenButton Text="X"`                | `button:has-text("X")`                                |
      | `<RadzenButton Icon="x" />` (no text)   | `button.rz-button-icon-only:has(.rzi-x)` OR `button[title*="X" i]` |
      | `<RadzenIcon Icon="x" @onclick=…>`      | `i.rzi-x` (parent click)                              |
      | `<RadzenMenuItem Text="X"`              | `.rz-menuitem:has-text("X"), [role="menuitem"]:has-text("X")` |
      | `<RadzenTextBox Name="N"`               | `input[name="N"]`                                     |
      | `<RadzenDropDown` + popup labels        | open with `.rz-dropdown[name="N"]`, options match `.rz-dropdown-item:has-text("…")` |
      | DataGrid row action (no button)         | `tr.rz-data-row:has-text("<row-key>") >> hover ... ` then trigger the cell handler |

   d. If multiple selector shapes are plausible, write the spec to
      try them in order (`.first()` on a `,` union) — Playwright's
      auto-wait picks whichever resolves.

   e. If the recon turns up NO matching element in source, the AC
      may genuinely be untestable (the change is in a part of the UI
      the test user can't reach, OR the AC is misworded) — flag as
      `code-evidence` with the reason, NOT `SKIPPED`.

3. The runner `$QA_AGENT_ROOT/runners/ui-tier.sh` handles
   starting the Admin app on `$QA_ADMIN_PORT`, performing login once via
   the auth helper spec, saving `storageState` to
   `$QA_OUT_DIR/admin-state.json`, and tearing down at the end.
   You DO NOT manually `dotnet run` — you call the runner.

3. Generate one spec file per AC under `$QA_OUT_DIR/playwright/`:
   `ac-<n>-<short-name>.spec.ts`. Use the template at
   `$QA_AGENT_ROOT/templates/ui-spec.ts.tmpl`. Key points:
   - `test.use({ storageState: process.env.QA_ADMIN_STATE_FILE })`
   - Always navigate via `await page.goto('${ADMIN_URL}/path')` with
     `ADMIN_URL` from `process.env.QA_ADMIN_URL`.
   - Use the **z-index audit + coverage check** pattern from the
     knowledge base for any new visible UI element — copy the
     `assertNotCovered` helper verbatim from
     `$QA_AGENT_ROOT/knowledge/admin-selectors.md`.
   - **Capture a highlighted screenshot per AC (REQUIRED).** At the end
     of each AC test, after the assertion passes, call the
     `shotWithHighlight` helper (already in the template) to save a
     screenshot of the verified state with the element under test
     outlined in red:
     ```typescript
     await shotWithHighlight(
       page,
       `${SHOT_DIR}/ac-<n>-<short-name>.png`,
       "<the selector you just asserted on>"   // string or string[]
     );
     ```
     `SHOT_DIR` comes from `process.env.QA_SCREENSHOT_DIR` (set by the
     runner). The orchestrator attaches every PNG in that directory to
     the Trello card, so reviewers see the change visually. Name files
     `ac-<n>-<short-name>.png` so each Trello attachment is
     self-describing.
   - The highlight (red outline + glow on the target element) is what
     lets QA spot the change at a glance. Pass the SAME selector you
     asserted on — for multi-element AC, pass an array of selectors.
   - Failure screenshots are still captured automatically
     (`screenshot: "only-on-failure"` in the config) and also land in
     the artifacts dir. Both success-highlights and failure-shots get
     attached to Trello.
   - Set `test.describe.configure({ mode: 'serial' })` if multiple AC
     tests in one file share state.

4. Run via the runner:
   ```bash
   $QA_AGENT_ROOT/runners/ui-tier.sh "$QA_OUT_DIR/playwright"
   ```
   The runner produces `$QA_OUT_DIR/ui-results.json` (Playwright JSON
   reporter).

5. **Visual evaluation of each screenshot — MANDATORY for admin-ui AC.**

   You are a multimodal model. The `Read` tool returns PNG files as
   images you can actually see. After the Playwright run completes,
   for each AC's screenshot at
   `$QA_OUT_DIR/screenshots/ac-<n>-<short>.png`:

   a. **Read the image** with the `Read` tool. You will see the
      rendered admin UI with the element under test outlined in red.

   b. **Evaluate visually** across four dimensions. Be a strict QA
      eyeball, not a generous one:

      | Dimension | What to look for |
      |-----------|-----------------|
      | **Element present** | Is the red-outlined element clearly visible? Does it match the AC description (e.g. AC says "Branch ID text input" → there's a text input)? |
      | **Content correct** | If the AC names specific content (dropdown options, labels, button text), does the screenshot show it? E.g. "dropdown shows 10 entries" → count the entries you can see. |
      | **Alignment & layout** | Is the new element well-aligned with neighbors (labels above inputs, inputs same width as siblings, container padding consistent)? Does anything overlap, get cut off, or look broken? |
      | **Visual defects** | Cut-off text, wrong colors, missing labels, broken icons, ghost shadows, blank regions where content should be. |

   c. **Fold the visual verdict into the AC's Evidence column** in
      `qa-report.md`. Format:

      ```
      ac-3: <AC text>
        Verdict: ✅ PASS  (or whatever Playwright reached)
        Playwright: PASS — input[name="LoyaltyComoBranchId"] visible at :1257
        Visual: layout clean. Label "Branch ID" sits directly above the
                text input, matching sibling fields. No overlap, no clipping.
                One concern: input width appears narrower than the
                "API Key" input on the same row — minor inconsistency,
                worth a human eyeball.
      ```

      The visual note should be 1-3 sentences naming what you saw. Be
      specific about positions ("sits below", "left of", "narrower than")
      so the human can verify.

   d. **Downgrade the verdict if visual issues are severe.** If the
      screenshot shows the element is genuinely broken (cut in half,
      hidden behind another element, missing entirely despite
      Playwright passing the structural check), mark the AC as
      `FAIL` with a screenshot reference even though Playwright
      "passed". A passing DOM-level check on a visually broken
      element is itself a bug.

      Mild concerns (slight misalignment, off-by-a-few-px spacing)
      stay as `PASS` with a note — don't fail the build for taste.

   e. **For the Trello summary** (`qa-trello-summary.md`), include
      one short visual line per AC where applicable:

      ```
      - **ac-3:** Branch ID input renders — ✅ PASS · visual: layout clean
      ```

      Skip the visual line if it would just say "looks fine" — that's
      already implied by ✅ PASS.

   You do NOT visually evaluate screenshots when:
   - The AC tier is `api` (no UI screenshot exists)
   - The screenshot is from a Playwright FAILURE (the failure itself is
     the verdict; the screenshot is for human debug context)
   - The screenshot didn't capture (file missing — note that as the
     verdict and move on)

   This step is what closes the loop on "alignment / visual / layout"
   bugs that Playwright's structural checks miss. Use it.

## 5b. Eshop UI tier — Playwright against self-service-web

For each `eshop-ui` AC:

1. **Read the eshop knowledge files at run start.** They contain
   confirmed selectors, navigation patterns, API intercept recipes,
   and gotchas — using them avoids repeating known mistakes:
   - `$QA_AGENT_ROOT/knowledge/eshop-selectors.md`
   - `$QA_AGENT_ROOT/knowledge/eshop-flows.md`
   - `$QA_AGENT_ROOT/knowledge/eshop-api-intercept.md`
   - And of course the shared `lessons-learned.md` (covers both
     surfaces).

2. **Use the eshop spec template** at
   `$QA_AGENT_ROOT/templates/eshop-spec.ts.tmpl`. It
   handles tabletToken navigation, viewport selection (desktop/mobile),
   and the highlighted-screenshot pattern.

   **Screenshots are MANDATORY for every eshop AC, no exceptions.**
   Eshop bugs are overwhelmingly visual (alignment, layout, modal
   stacking, mobile cutoffs) — text-only verdicts hide more than they
   reveal. Every eshop AC test MUST end with a `shotWithHighlight`
   call to `$QA_SCREENSHOT_DIR/eshop-ac-<n>-<short>.png`. If you
   write an eshop spec that has no `shotWithHighlight` call,
   downgrade the AC verdict to `NEEDS_HUMAN` with reason "no visual
   evidence captured — eshop AC require screenshots". Apply this rule
   to:
   - mobile viewport tests (390×844) — capture how the change looks on iOS-sized screens
   - desktop viewport tests (1366×900) — capture how the change looks on widescreen
   - cross-system tests — capture BOTH the Admin side AND the eshop side after the propagation
   - tests that pass purely on assertion (still capture — passing tests need evidence)
   - tests that fail (Playwright also auto-captures on failure; both shots get attached to Trello)

   For multi-state AC (e.g. "category switch shouldn't flash"), take
   one shot BEFORE the action and one AFTER — name them
   `eshop-ac-<n>-before.png` and `eshop-ac-<n>-after.png`. Both get
   attached. The human reviewer can scan the pair and verify the
   absence of the bug between them.

3. **Common patterns the eshop knowledge encodes** (don't reinvent):
   - Home shows CATEGORIES, not products. Click a category first.
   - Product option buttons have NO testid/aria-label — use the
     `page.evaluate` filter pattern from `eshop-selectors.md`.
   - Google Places address autocomplete needs real network — use
     `'savanoriu 123'` as a stable test address (returns Savanorių 123,
     Kaunas at `.pac-item` index 1).
   - `cart-button` appears MULTIPLE times in DOM — always `.first()`.
   - Mobile (390×844) has different checkout flow than desktop —
     mobile needs an extra `cart-button` filtered by `/order/i` tap
     before order-type buttons appear.
   - API intercept patterns at `eshop-api-intercept.md` — passive
     listener vs `waitForRequest` vs `waitForResponse` vs `route` mock.

4. **Run via the runner:**
   ```bash
   $QA_AGENT_ROOT/runners/eshop-tier.sh "$QA_OUT_DIR/playwright"
   ```
   The runner starts the Vite dev server on `:5173`, polls until it
   responds, runs every `*.spec.ts` in the directory, kills Vite on
   exit. Produces `$QA_OUT_DIR/eshop-results.json`.

5. **Visual evaluation** (same as admin-ui — see §5 step 5):
   after the run completes, `Read` each
   `$QA_OUT_DIR/screenshots/eshop-ac-<n>-*.png` and fold a visual
   verdict into each AC's evidence row.

### Cross-system flow (`cross-system` tier) — SUPPORTED

When AC spans both surfaces, **DO NOT** route to `NEEDS_HUMAN`. Use
the dedicated runner `cross-system-tier.sh` which starts Admin AND
Vite together, logs in to Admin, then runs Playwright specs that open
two browser contexts in one test:

- Admin context uses storageState (`$QA_ADMIN_STATE_FILE`)
- Eshop context loads fresh with the tabletToken
- Make the change via Admin (real API write, NOT mocked)
- Reload eshop (or wait for next /api/qr/menu fetch), assert the
  change is reflected

**When to PROACTIVELY upgrade an `admin-ui` AC to `cross-system`**
(even if the AC text doesn't mention the eshop):

| Admin area touched               | Affects eshop? | Why                                       |
| -------------------------------- | -------------- | ----------------------------------------- |
| Product / menu items             | YES            | eshop fetches `/api/qr/menu`              |
| Categories                       | YES            | eshop renders the menu tree               |
| Prices                           | YES            | shown on cards + cart                     |
| Modifiers / options              | YES            | shown in item-detail modal                |
| Venue settings (theme, branding) | YES            | eshop uses `/api/qr/venue` for styling    |
| Allergens / labels               | YES            | shown on item cards                       |
| Delivery zones                   | YES            | eshop requires for checkout               |
| Stock / availability             | YES            | eshop hides out-of-stock items            |
| Users / roles                    | NO             | Admin-internal                            |
| Audit logs                       | NO             | Admin-internal                            |
| Reporting / dashboards           | NO             | Admin-internal                            |

If the diff modifies any "YES" area and the eshop has a corresponding
read path, **upgrade to `cross-system`** and add a propagation AC even
if the ticket only listed an Admin-side AC. Document the upgrade in
the report ("AC1 upgraded to cross-system — Admin product change
implies eshop propagation must be verified").

Pattern:

```bash
$QA_AGENT_ROOT/runners/cross-system-tier.sh "$QA_OUT_DIR/playwright"
```

Template: `$QA_AGENT_ROOT/templates/cross-system-spec.ts.tmpl`

Cross-system tests are slower (~60-90s vs ~20-30s for single-tier) but
produce the strongest signal for "did this change actually behave
end-to-end."

**Cleanup is guaranteed.** The runner traps EXIT / INT / TERM and
kills BOTH Admin and Vite (Vite by process-group, Admin by PID, both
with SIGKILL fallback after grace). You do NOT need to manually kill
servers from the spec.

## 6. cross-system / code-evidence / manual / skipped tiers

- `cross-system`: SUPPORTED via `cross-system-tier.sh` — see the
  "Cross-system flow" subsection above. Only fall back to
  `NEEDS_HUMAN` if BOTH servers genuinely cannot start (e.g.
  connection-string missing for Admin, network blocked from
  reaching the staging API for Vite). Document the specific
  blocker in the reason.
- `code-evidence`: Read the diff line-by-line. For each AC in this
  tier, identify the **specific code pattern** that proves the
  implementation does what the AC says, then verdict:
    - `PASS` — diff unambiguously implements the AC AND a passing test
      anywhere in the diff or scratch tests covers the behavior
    - `PARTIAL_PASS` — diff implements the AC structurally (correct
      function calls, correct routing, correct conditional logic) but
      end-to-end execution would still need live external state. Cite
      the specific line(s).
    - `FAIL` — diff CONTRADICTS the AC (e.g. AC says "always include X"
      but diff filters X out)
    - `AC_DRIFT` — see §3b
  Evidence format for `PARTIAL_PASS`:
    "Code review: `<file>:<line>` shows `<the code snippet>`. This
     implements the AC structurally; live verification deferred because
     `<specific external state needed>`."
- `manual`: Record verdict `NEEDS_HUMAN` with a one-line description of
  the manual verification step Giedrė should run.
- `skipped`: Verdict `SKIPPED`, reason "out of QA scope".

### When to use `code-evidence` proactively

The agent should reach for `code-evidence` rather than `NEEDS_HUMAN`
whenever the diff actually shows the change. Examples:

| AC text                                    | Reasoning  → Tier      |
|--------------------------------------------|----------------------|
| "Device SN `Y6DX9NFQ9G` appears in view"   | Specific live device → `code-evidence` (verify the lookup flow exists and calls the right service); plus a separate `manual` step for Giedrė to enter the SN |
| "Endpoint returns 200 with field X"        | API tier — runnable in WebApplicationFactory |
| "Validation message appears when empty"    | admin-ui tier — Playwright can drive this |
| "All Mosyle devices listed"                | If diff has no listing surface → `AC_DRIFT` |
| "Mosyle integration calls X service"       | `code-evidence` (grep diff for the call site) |
| "Production database row created with…"    | `code-evidence` + `manual` (no prod access) |
| "Visual matches the mockup in Figma"       | `manual` |
| "Loyalty API responds correctly"           | `skipped` (loyalty API out of QA scope) |

### Round-trip AC ("save → reload → still there") — RUN LIVE, do NOT settle for code-evidence

Whenever an AC says some variant of *"the value persists / saves /
reloads / shows after refresh"* — that AC is `admin-ui` tier and MUST
be run with Playwright end-to-end. This is exactly what Playwright
exists for. Do NOT downgrade to `code-evidence` / `PARTIAL_PASS`
because:

- "It mutates the shared dev DB" — every other admin-ui test you
  already wrote mutates the dev DB. Picking a unique sentinel value
  (e.g. `#FF<run-id-bytes>` for colors, `qa-test-<timestamp>` for
  text fields) avoids stepping on real data. The dev DB is for dev.
- "The control is fiddly" — that's a research problem, not a
  stopping condition. Solve it once, write the recipe to
  `knowledge/admin-selectors.md`, reuse forever. Fiddly controls
  the playbook expects you to drive:
  - **RadzenColorPicker** — see the recipe in
    `knowledge/admin-selectors.md` ("Radzen color picker — hex
    entry"). The HexValue input + Enter sequence is reliable.
  - **RadzenDropDown with virtual scroll** — `.evaluate(el => el.scrollTop = ...)`
    on `.rz-dropdown-list` then click.
  - **RadzenDatePicker** — type ISO into the input, then Tab to commit.
- "I'd rather not click Save in a shared environment" — the dev DB
  is precisely the place to click Save in tests. If anything,
  click Save TWICE: once to write the test value, once to write a
  human-recognizable "RESET-BY-QA" marker so future operators can
  spot QA traffic in the audit log.

The round-trip test shape (every admin-ui ticket that has a
persisted field):

```typescript
test("ac-N: <field> persists across reload", async ({ page }) => {
  const sentinel = `#FF${Date.now().toString(16).slice(-6).toUpperCase()}`;
  await page.goto(EDIT_URL);
  await setRadzenColorPicker(page, '[for="AddedToCartNotificationTintColor"]', sentinel);
  await page.locator('button:has-text("Save")').click();
  await page.waitForResponse(r => r.url().includes('/api/') && r.request().method() === 'PUT');
  await page.reload();
  await page.waitForLoadState('networkidle');
  const reloaded = await getRadzenColorPickerValue(page, '[for="AddedToCartNotificationTintColor"]');
  expect(reloaded.toUpperCase()).toBe(sentinel);
  await shotWithHighlight(page, `${SHOT_DIR}/ac-N-roundtrip-after-reload.png`, '...');
});
```

If you genuinely cannot drive the picker after honest attempts
(documented in `knowledge/admin-selectors.md` with the specific
failure), THAT is the moment to fall back to `PARTIAL_PASS` —
not because you decided in advance to avoid it.

The verdict ceiling for an AC that should have been round-trip-tested
but ran code-evidence instead is **`QA_NEEDS_HUMAN`** at the overall
level — not `QA_APPROVED_WITH_GATES`. A skipped live test isn't a
"gate" the human can clear with one click; it's an automated check
the rig didn't perform.

## 7. Aggregate verdicts

For each AC, compute:

```
PASS          — automated check ran and passed
PARTIAL_PASS  — code-evidence confirms the implementation; live execution deferred
FAIL          — automated check ran and failed (include error excerpt)
NEEDS_HUMAN   — manual, cross-system, or no useful evidence available
AC_DRIFT      — AC doesn't match the shipped implementation
SKIPPED       — out of QA scope
```

Map xUnit test results back to AC via the `[Fact(DisplayName = "AC<n>: ...")]`
prefix. Map Playwright tests back via the spec filename `ac-<n>-*.spec.ts`.
Map code-evidence verdicts back via the cited file:line.

### Overall verdict

Pick the *single most accurate* tag:

- `QA_APPROVED` — every AC is `PASS` (no `PARTIAL_PASS`, no
  `NEEDS_HUMAN`, no `FAIL`, no `AC_DRIFT`).
- `QA_APPROVED_WITH_GATES` — mix of `PASS` + `PARTIAL_PASS`, NO `FAIL`
  and NO `AC_DRIFT`, all manual steps clearly enumerated. The diff is
  structurally correct; a human eyeball is the final gate but not a
  blocker.
- `QA_REJECTED` — any AC is `FAIL`.
- `QA_NEEDS_HUMAN` — every automatable AC came back inconclusive, OR
  `AC_DRIFT` is present (PM decision needed), OR the change is in
  `HIGH_RISK` territory with NO `PASS` verdicts at all.

The new `QA_APPROVED_WITH_GATES` is the right verdict for cards where
the agent reads the diff, confirms the implementation matches the AC,
but a specific live check (specific device, specific account, prod
data) is still recommended. Use it when:

- ≥1 AC is `PASS` or `PARTIAL_PASS`
- NO `FAIL` verdicts
- NO `AC_DRIFT`
- The manual steps you list are *specific* (not vague) — Giedrė knows
  exactly what to click

If you find yourself wanting to mark `QA_NEEDS_HUMAN` because "the
agent couldn't fully verify", check whether `QA_APPROVED_WITH_GATES`
is more honest. The difference:

| Situation                                              | Verdict |
|--------------------------------------------------------|---------|
| Diff structurally correct, only live data missing      | `QA_APPROVED_WITH_GATES` |
| Diff doesn't match AC                                  | `QA_NEEDS_HUMAN` (with `AC_DRIFT`) |
| Couldn't even run a test (build broken, login broken)  | `QA_NEEDS_HUMAN` |
| One AC failed                                          | `QA_REJECTED` |
| `HIGH_RISK` area + no `PASS` evidence                  | `QA_NEEDS_HUMAN` |

The final stdout line must still be one of:
- `QA_APPROVED`
- `QA_APPROVED_WITH_GATES`  ← new
- `QA_REJECTED`
- `QA_NEEDS_HUMAN`

## 8. Write outputs

You write TWO report files. They target different readers:

### `$QA_OUT_DIR/qa-report.md` — full report (goes to GitHub PR comment)

Devs reading the PR need full detail: code-evidence file:line citations,
test framework details, recommendations, build/run logs.

```markdown
# QA Report — Ticket #<ticket>: <name>

**Verdict:** ✅ QA_APPROVED / ✅⚠ QA_APPROVED_WITH_GATES / ❌ QA_REJECTED / ⚠ QA_NEEDS_HUMAN
**PR:** <pr_url>
**Branch:** <head_ref_name>
**Diff size:** <files_changed> files, <added>+/<removed>− lines
<HIGH_RISK line if applicable>

## Per-AC Verdicts

| AC | Verdict | Tier | Evidence |
|----|---------|------|----------|
| ac-1: <verbatim text> | ✅ PASS | api | `QaScratch.T4621.AC1_Foo.Bar_ReturnsOk` (210ms) |
| ac-2: <verbatim text> | ❌ FAIL | admin-ui | `Expected color rgb(255,85,0), got rgb(0,122,255)`; screenshot: ac-2-step3.png |
| ac-3: <verbatim text> | ⚠ NEEDS_HUMAN | manual | "Verify the mobile layout in 390×844 viewport — Playwright assertion was inconclusive" |

## Test Run Summary

- API tier: <passed>/<total> passing (<duration>)
- Admin UI tier: <passed>/<total> passing (<duration>)

## Issues found

<bullet list of failures with file:line + the relevant assertion text>

## Recommendations

<short prose, optional — e.g. "Suggest reverting commit X to investigate
the validation regression in ac-2.">
```

### `$QA_OUT_DIR/qa-trello-summary.md` — short report (goes to Trello card)

Trello readers are QA (Giedrė) + PMs + the broader team — they need
status at a glance and actionable manual steps. They do NOT need code
citations, test framework details, or recommendations. Target length:
under 2000 characters. Hard cap: 4000 characters.

REQUIRED sections, in this order. **Use bullet lists, NOT markdown
tables** — Trello comments do not render markdown tables and the AC
results will look empty.

```markdown
🧪 **QA #<ticket>** — <short ticket title>

**Verdict:** ✅ QA_APPROVED  (or one of the four)
**PR:** <pr_url>
<HIGH_RISK line if applicable, one short line>

## Acceptance Criteria

- **ac-1:** <AC text, trimmed to ~80 chars> — ✅ PASS
- **ac-2:** <AC text trimmed> — ⚠ PARTIAL_PASS — <one-line reason>
- **ac-3:** <AC text trimmed> — 🟧 AC_DRIFT — <one-line reason>

## Manual gate (for Giedrė)

1. <specific step with exact UI label / serial number / dialog title>
2. <next step>
3. <…up to ~6 steps; if there are more, link to full report>

📎 Screenshots of the verified UI (element under test highlighted in red)
are attached to this card.
📋 Full report on GitHub PR: <pr_url>
```

(Include the 📎 screenshots line ONLY when the UI tier actually ran and
produced screenshots. Omit it for API-only or code-evidence-only runs.)

RULES for the Trello summary:

- **Use bullet lists, NOT tables.** Trello renders bullets, bold,
  italic, links, headers, inline code, fenced code blocks, and ordered
  lists — but **not markdown tables**. A table in the body shows up as
  one squashed line of pipes or gets stripped to near-blank. If you
  reach for `|...|...|`, stop and use `- **label:** value` instead.
- **Trim AC text** to ~80 chars per line if longer (use `…` truncation).
- **Evidence collapses** into the result line — one short reason
  (≤80 chars), no file:line, no test names.
- **Skip these sections entirely** vs. the full report:
  - "Test Run Summary" (counts)
  - "Issues found" (detailed list)
  - "Recommendations" (prose)
  - Diff size / branch name (metadata noise)
- **Keep Manual gate verbatim** from the full report — these are the
  high-value action items, the whole point of the Trello comment.
- **Always end with the PR URL** so anyone can click through to the
  full detailed report on GitHub.
- **Minimum length: 200 characters.** Even for a trivial diff, the
  summary must include verdict + at least one bullet per AC + the PR
  link. If you finish with under 200 chars, you've under-written it.
- If the verdict is `QA_APPROVED` and no manual steps are needed, the
  Trello summary can be ~300-500 chars — that's fine, shorter is
  better. But never zero.

If you only have time/budget to write one report well, write the full
`qa-report.md` first. The orchestrator falls back to truncating the
full report if `qa-trello-summary.md` is missing, but the Trello card
ends up cluttered — so writing the dedicated summary is strongly
preferred.

### `$QA_OUT_DIR/qa-telemetry.json`

```json
{
  "ticket": "<ticket>",
  "pr_url": "<url>",
  "verdict": "QA_APPROVED",
  "high_risk": false,
  "high_risk_reason": null,
  "ac_total": 5,
  "ac_pass": 4,
  "ac_fail": 0,
  "ac_needs_human": 1,
  "ac_skipped": 0,
  "api_tier": { "tests": 4, "passed": 4, "failed": 0, "duration_ms": 8120 },
  "ui_tier":  { "tests": 2, "passed": 2, "failed": 0, "duration_ms": 14200 },
  "files_changed": 7,
  "scope": ["self-service-api", "admin"]
}
```

### Last line on stdout

Exactly one of:

```
QA_APPROVED
QA_REJECTED
QA_NEEDS_HUMAN
```

## 9. After the run

The orchestrator does:
- Posts `$QA_OUT_DIR/qa-trello-summary.md` as a Trello card comment
  (or truncated `qa-report.md` if the summary file is missing)
- Posts `$QA_OUT_DIR/qa-report.md` as a GitHub PR comment
- Moves Trello card according to verdict
- Cleans `$QA_OUT_DIR` (you don't need to)
- Removes the `QaScratch/T<TICKET>/` folder from the worktree

You don't have to handle any of that.

## 10. Knowledge base — read on every run, update when you learn

`$QA_AGENT_ROOT/knowledge/` contains:

- `admin-selectors.md` — confirmed Radzen-rendered selectors for
  Dserve.Admin pages (login, grids, dialogs, forms)
- `lessons-learned.md` — gotchas (.NET runtime, port conflicts, login
  edge cases, dialog z-index quirks)

Read every file in `knowledge/` BEFORE writing any Playwright spec.
After the run, if you discovered a new confirmed selector or a new
gotcha, **append** to the appropriate file (use `Edit` tool, append-only).
Never rewrite. Never delete.

## 11. Things that have bitten earlier runs

- **CompanySelect after login.** If the test user has multiple companies,
  the login flow shows a company picker before the dashboard. The auth
  helper handles this; if you see it appear in a test, add `await
  page.locator('button:has-text("Select")').first().click()` or check
  the knowledge base.
- **Radzen dialog z-index.** Modals stack with z-index 1000+. If a new
  element renders below that, it's hidden behind modals. Use the
  `assertNotCovered` helper.
- **Port collisions.** If `:5080` is already in use (the developer ran
  Admin locally), the runner script fails fast. Tell the user — don't
  pick a random alternate port.
- **`Startup.cs` not `Program.cs`.** The integration test factory
  generic is `WebApplicationFactory<Startup>`, not `<Program>`. Don't
  change it.
- **Dserve.SelfServiceApi route constants** live in
  `Dserve.Core.SelfServiceApiRoutes.SelfServiceApiRoutes` — there's the
  outer namespace + inner static class with the same name. Use the
  `using static` import you'll see in existing tests.

## 12. Failure modes you must handle gracefully

| Situation | Action |
|-----------|--------|
| No AC found | Write report explaining; verdict `QA_NEEDS_HUMAN` |
| PR not found on the branch | Verdict `QA_NEEDS_HUMAN`, reason "no open PR found for ticket" |
| `dotnet build` fails on Dserve.SelfService.Integration | Mark API AC FAIL with build error; continue to UI tier |
| `dotnet run` (Admin) fails to start or times out (>120s) | Mark UI AC NEEDS_HUMAN with startup log; continue with API results |
| Login fails | Mark all UI AC NEEDS_HUMAN with reason "Admin login failed — check QA_ADMIN_EMAIL/QA_ADMIN_PASSWORD"; continue with API results |
| All AC are `skipped` or `manual` | Verdict `QA_NEEDS_HUMAN`, reason "nothing automatable in this card" |

Always write the report and telemetry, no matter how partial the
results. Always print the final verdict line. Never exit silently.

## 13. Never skip a UI assertion on first miss — try harder

### 13.0  Run the tier first. Do NOT skip pre-emptively.

This is the most important rule in this document. **Always attempt
the UI tier (or API tier) before deciding it won't work.** Lessons in
`knowledge/lessons-learned.md` are for **diagnosing failures after they
happen** — they are NOT permission to skip a tier you haven't run yet.

Anti-patterns the agent has done in the past (don't repeat):

- Reading lessons-learned, finding "ticket X had a permission gate",
  and concluding "this ticket probably will too — skip to code-evidence".
  **Wrong.** Run the spec. If it fails on a gate, the failure mode is
  now documented, AND the report has real screenshot evidence vs.
  speculation.
- Seeing "AC needs Como-configured venue in DB", concluding "test
  needs special data — skip". **Wrong.** Many AC about conditional UI
  rendering can be tested by setting the precondition IN the test
  itself (e.g. enable loyalty + select Como in the dropdown → assert
  field appears). Toggle data via UI before claiming data-gated.
- Marking `PARTIAL_PASS` via code-evidence on an AC that's plainly
  reachable in the UI. Code-evidence is the **fallback** when live
  verification fails or genuinely can't run. It is NOT a substitute
  for trying.

When in doubt: **try first, fall back on actual failure.** A failed
UI run with screenshots is more actionable than a confident
code-evidence write-up that the human still has to verify by hand.

### 13.1  Recovery sequence when an assertion actually misses

If a Playwright `toBeVisible()` / locator returns no match on the
first attempt, **do NOT immediately mark the AC as `SKIPPED`**. Try
the following recovery sequence, in order, and only skip if all four
steps still produce nothing:

1. **Wait for the network.** The page may still be loading data
   (Radzen DataGrid fetches lazily on tab/category change). Add
   `await page.waitForLoadState('networkidle')` and retry the locator.

2. **Try category / tab / filter navigation.** If the AC names a column
   or row that lives inside a DataGrid, check whether there's a
   sibling tab, category sidebar item, or dropdown filter that needs
   to be selected first. Consult `knowledge/admin-selectors.md` for
   page-specific patterns. Common pages and their tells:
   - **Menu / Products** — categories are in a list/tab strip; pick
     the one named in the AC (e.g. "Combo"). After click, wait for
     the DataGrid to fetch.
   - **Settings → Extra** — accordion or fieldset by feature area;
     click the matching legend.
   - **Venues / Organizations** — search-by-name input may filter
     out the row you're looking for; clear the search first.

   **Stay on the user-click path.** Use the same navigation a human
   would: top nav → grid → row action → dialog. Do NOT try to bypass a
   blocked UI by navigating directly to a `@page` route. Many Dserve
   pages declare `@page "/area/{id}"` but are designed for dialog use
   only — direct URLs to them hang on `_loading=true` or render
   broken state. **Direct-URL bypass is not in the recovery toolkit.**
   If the click path is blocked (e.g. the Edit menu item doesn't
   render), that's the gate — don't try to route around it.

3. **Scroll the container.** Radzen DataGrids are virtualised — rows
   and columns may exist in the DOM but be outside the visible
   viewport. Try:
   ```typescript
   await page.locator('.rz-datatable, .rz-grid, .rz-data-grid').first()
     .scrollIntoViewIfNeeded();
   ```
   Then retry. For horizontal columns specifically, scroll the grid
   wrapper sideways: `await page.evaluate(() => document.querySelector('.rz-datatable-wrapper').scrollLeft = 9999);`

4. **Check the auth path.** Some columns / rows are role-gated
   (visible only to Master Admin). Verify the test user (`QA_ADMIN_EMAIL`)
   has the right policy. If not, that's a `NEEDS_HUMAN` reason, not
   a `SKIPPED` reason — name the policy and the human action needed.

5. **Re-grep the .razor source for alternative selector shapes.** If
   you wrote a spec looking for `button:has-text("Edit")` but the recon
   missed an icon-only variant, go back to the source and check for
   `Icon="edit"`, `Icon="pencil"`, `<RadzenIcon`, or DataGrid row-action
   handlers. Update the selector and retry. This is the same step as
   §5.2 source reconnaissance — repeated because in practice the
   correct selector is often *very close* to what was tried but uses an
   icon, an aria-label, or a tooltip text instead of inner text.

   **Data prerequisites count too.** If the action exists in source
   but is gated by data (Edit only visible when a row exists, or
   when a venue is attached, or a category is selected), and the dev
   DB has zero such rows, the right verdict is `PARTIAL_PASS` via
   `code-evidence` (the change is structurally sound, but live
   activation requires data) — NOT `SKIPPED`. Note the data
   prerequisite explicitly in the report so a human knows what to
   seed.

Only after all five steps fail, mark the AC as:
- `SKIPPED` with reason "element absent after navigation + scroll +
  network-wait + source re-grep — agent could not locate in test-user
  view" AND
- Add an entry to `knowledge/admin-selectors.md` describing what was
  tried, so the next run can either skip the false-skip or know the
  selector is genuinely absent.

`SKIPPED` because of a missed selector is an agent failure, not a
verdict — treat it that way.
