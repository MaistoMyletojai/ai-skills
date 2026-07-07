# QA Runner — Lessons Learned

Append new lessons at the bottom with a date stamp. Never rewrite older
entries — they're history. If a lesson becomes obsolete, mark it
`[obsolete: <reason>]` rather than deleting.

---

## RULE — Reach for `cross-system` whenever Admin writes data the eshop reads

A surprising number of "admin-only" tickets actually have a customer-
facing effect, because the eshop is a thin read-client over the same
data Admin writes. Default to `cross-system` (not `admin-ui`) for any
diff that modifies these areas:

- Products / menu items / categories / prices
- Modifiers, options, allergens, labels
- Venue settings (theme, branding, hours, contact)
- Delivery zones, pickup windows
- Stock / availability flags
- Promotions, discounts, vouchers

The rule of thumb: **if the Admin write touches a row the eshop will
read on its next `/api/qr/menu` (or `/api/qr/venue`) call, the cross-
system check is in-scope** — even if the ticket text only describes
the Admin side. Add an explicit propagation AC ("AC1.b: after saving
in Admin, eshop reflects the change within 5s of reload") and verdict
it via the cross-system runner.

Admin areas that do NOT need cross-system: users, roles, audit logs,
internal reports, system settings scoped to Admin, tenancy admin.
These never reach customer-facing endpoints.

**Why this rule:** historically the agent has been routing tickets
like "rename product field in Admin" to `admin-ui`-only, which gives
a green verdict when the Admin form saves — but misses the case
where the save went through yet the eshop API filters the field out,
or the eshop's local cache holds the old value past a reasonable
refresh. Those are the bugs customers actually see.

The runner exists (`cross-system-tier.sh`), the template exists
(`cross-system-spec.ts.tmpl`), and cleanup is guaranteed (both Admin
and Vite get killed on EXIT/INT/TERM). There is no excuse to skip.

---

## RULE — Eshop tests MUST capture screenshots, every time

For every `eshop-ui` AC, the Playwright spec MUST end with at least one
`shotWithHighlight` call writing to
`$QA_SCREENSHOT_DIR/eshop-ac-<n>-<short>.png`. No exceptions:

- AC that pass cleanly → still screenshot (passing tests need evidence)
- AC that fail → Playwright auto-captures on failure AND you call
  shotWithHighlight before the assertion; both get attached
- Multi-state AC (before/after) → two screenshots, named with `-before`
  / `-after` suffixes
- Cross-system AC → capture BOTH the Admin side and the eshop side
- Desktop viewport tests → screenshot at 1366×900
- Mobile viewport tests → screenshot at 390×844 (iPhone 14 Pro size)

**Why it's non-negotiable for eshop specifically:** eshop bugs are
overwhelmingly visual — alignment, modal stacking, mobile cutoffs,
animation flash, theming. A green Playwright assertion on "element
exists" can pass while the actual rendered UI is broken. The
highlighted screenshot is what lets the human reviewer (and the
agent's own multimodal pass) catch the class of bugs the structural
check misses.

If a spec lacks a `shotWithHighlight` call, **downgrade the verdict
to `NEEDS_HUMAN`** with reason "no visual evidence captured — eshop
AC require screenshots". Force the agent's next iteration to add it.

This rule does NOT apply to api-tier ACs (no UI to screenshot) or
code-evidence-only ACs (no live test ran).

---

## RULE — Use Trello labels for scope routing

Trello cards carry **labels** that name the intended surface. Always
read `task.card.labels[*].name` BEFORE looking at the diff:

| Label name (case-insensitive) | Forces scope |
|-------------------------------|--------------|
| `E-shop / QR`, `eshop`, `qr`, `webshop` | `eshop-ui` |
| `Admin`, `Admin UI` | `admin-ui` |
| `SelfServiceApi`, `api` | `api` |

The label is the authoritative source. Common scenarios where the
label saves you:

- Card is *Done* with no `feature/<n>` branch (merged + branch
  deleted post-merge). No diff to read. Label still tells you "eshop"
  → switch to current-master verification on that surface.
- Card description is just a screenshot + one-line bug report, no AC.
  Label tells you which surface to verify on. Read the screenshot
  (you're multimodal) + title to infer 1-2 AC.
- Diff touches dserve-backend in a tiny way but card is really about
  eshop (e.g. an API contract update that ships with a webshop UI
  change). Label disambiguates.

**Anti-pattern (don't do this, the agent did it on #4788):**

> "The qa-runner only knows two surfaces … neither covers a webshop
> language-button render bug. If you want this verified, I'd need
> the webshop repo cloned … neither exists today."

Three things wrong with that:
1. Self-service-web IS in scope (since 2026-05-29).
2. The agent didn't check the card's `E-shop / QR` label.
3. The agent refused instead of doing diff-less master verification
   on a card that genuinely just needed a mobile-viewport screenshot
   check.

When in doubt, label > diff > refusal. See playbook §3 steps A-D.

---

## RULE — Visually evaluate every UI screenshot (you are multimodal)

You are Opus 4.8 — multimodal. After the UI tier runs, every
`$QA_OUT_DIR/screenshots/ac-<n>-*.png` should be Read by you (the
`Read` tool returns PNG content as an image you can see). The red
outline shows the element under test; evaluate it AND its surroundings
for:

1. **Presence** — is the highlighted element actually there?
2. **Content** — does what's rendered match the AC (dropdown options
   present? labels correct? text contents right?)?
3. **Alignment** — is the new element well-positioned relative to
   neighbors (labels above inputs, inputs same width as siblings,
   container padding consistent)?
4. **Visual defects** — cut-off text, missing labels, broken icons,
   ghost shadows, blank content areas.

Append a 1-3 sentence visual verdict to each AC's evidence row in
`qa-report.md`. For SEVERE visual breakage (element cut in half,
hidden, missing despite Playwright "passing"), DOWNGRADE the AC
verdict to FAIL even when the DOM-level check passed — a structurally
present but visually broken element is itself a bug.

For minor concerns (a few pixels off, slight inconsistency with
neighbors), keep PASS but note the concern. Trust the human to
adjudicate taste-level issues.

Playwright covers DOM-shape correctness. Your visual pass covers
"does the rendered UI actually look right" — the class of bugs
structural checks always miss. See playbook §5 for format.

---

## RULE — MasterAdmin has ALL permissions, by design

`UserRole.MasterAdmin` grants every `Permission.*` claim in Dserve.
This is a design contract, not an implementation detail. The claim
expansion happens upstream of `AdminPermissionService.HasPermission` —
likely at login or in middleware — but the agent does NOT need to
trace it. **Trust the contract.**

Implications for the agent:

- **Never recommend a code change to "add a MasterAdmin bypass"** on a
  per-page `_canEdit = …` line. The bypass already exists somewhere
  centralised. If the agent's leaf-method reading suggests otherwise,
  the leaf reading is incomplete.
- **Never conclude "the test user lacks a permission claim"** as a
  permanent fact about `edvardas@test.test`. The QA test user is
  MasterAdmin → it has every claim by construction. If a permission
  check appears to fail, the cause is one of: stale Playwright
  storageState, a transient session issue, or a real auth-path bug
  upstream of `HasPermission` — investigate in that order. Don't skip
  the UI tier on subsequent tickets because of it.
- **Never skip a tier pre-emptively** based on past permission
  failures. Run the spec; recover on actual failure. See `qa-card.md`
  §13.0.

If the agent EVER finds itself recommending "centralise the
MasterAdmin bypass" or "grant the test user `Permission.X`", stop —
that's a hallucination from misreading the code. Pause, re-state the
rule above, and continue.

---

## 2026-05-14 — Initial setup notes

- **WebApplicationFactory<Startup>**, not `<Program>`. Dserve still uses
  the classic Startup pattern in `Dserve.SelfServiceApi`. Don't change
  the generic — it'll break the existing integration test fixture too.
- **Test user for API tier** is `TestData.UserName / TestData.Password`
  (defined in `Dserve.SelfService.Integration/Common/TestData.cs`) —
  already wired into `IntegrationTest.AuthenticateAsync()`. Different
  from the Admin UI test user (configured via `QA_ADMIN_EMAIL` /
  `QA_ADMIN_PASSWORD` in `$QA_RIG_ROOT/.env`).
- **Ports:**
  - SelfServiceApi default `:5020`. Don't bind QA's API tier to a port —
    the integration tests use WebApplicationFactory, in-process, no
    network port needed.
  - Dserve.Admin default `:5030`. QA uses `:5080` (env `QA_ADMIN_PORT`).
    The dev pipeline never runs Admin, only builds + tests, so collision
    is unlikely — but if a human is debugging Admin locally on `:5030`,
    QA's `:5080` still avoids conflict.
- **.NET version** is net8.0 for both Admin and SelfService.Integration.
  No mismatched-runtime gotchas as long as the local toolchain has 8.0
  installed.
- **Radzen.Blazor 4.28.x** is the UI library — selectors are predictable
  but classes can change between major versions. Always trust `name="..."`
  attributes from the .razor source over CSS class selectors.
- **Connection string** lives in launchSettings — same RDS dev instance
  used by humans. QA writes go to the real dev DB. **Implication:** the
  agent should write tests that clean up after themselves where possible
  (delete what they create), OR use existing seed data instead of
  creating new records.
- **Don't `git commit` from QA.** The agent has Write tools but the
  branch is shared with the developer — committing in the QA worktree
  would diverge it. QaScratch files are ephemeral; orchestrator cleans
  them up post-run.

---

## Recipes that work

### `dotnet test` filtered by class

```bash
dotnet test Dserve.SelfService.Integration/Dserve.SelfService.Integration.csproj \
  --filter "FullyQualifiedName~Dserve.SelfService.Integration.QaScratch.T4621" \
  --logger "trx;LogFileName=/tmp/x.trx"
```

The trx XML is parseable — `UnitTestResult/@outcome` is `Passed` or
`Failed`, `Output/StdErr/Message` contains the assertion error for
failures, `Output/StdOut` has any printf debug. Use `xmlstarlet` or
parse it from the agent directly.

### Playwright JSON reporter shape

Top level: `{ stats: { expected, passed, failed, ... }, suites: [...] }`.
Each spec: `suites[i].specs[j].tests[k].results[l]`. Use `results[*].status`
(`passed` / `failed` / `timedOut`). Failure detail in `results[*].error.message`.
Screenshots referenced in `results[*].attachments[*].path`.

### Process killing on macOS

`kill <pid>` is enough for `dotnet run` — it propagates to children.
Don't use `pkill -f dotnet` — would kill the developer pipeline too.

---

## Anti-patterns (don't do)

- **Don't `pkill dotnet`** — would kill the developer pipeline if it's
  running in parallel.
- **Don't write tests that depend on each other's order.** Each `[Fact]`
  must stand alone — the `--filter` may run them in any order.
- **Don't mock services in the integration test factory.** The whole
  point is end-to-end. If a test needs to isolate something, write it as
  a unit test in `Dserve.Tests` instead — but those are the developer
  agent's job, not yours.
- **Don't add NuGet packages to `Dserve.SelfService.Integration.csproj`.**
  Stick to what's already there (xUnit, FluentAssertions, AspNetCore.Mvc.Testing).

---

## 2026-05-14 — Ticket #4781 (MDM device lookup) — lessons

This was the first real-world card that exercised the partial-verification
path. Takeaways folded back into the playbook:

- **External-state ACs are not `NEEDS_HUMAN` by default.** AC like
  "device SN `Y6DX9NFQ9G` appears" require live external state (a
  specific Mosyle-registered device). Marking them all `NEEDS_HUMAN` is
  too pessimistic. The right move: classify them as `code-evidence`,
  verify the diff structurally (function calls, routing, error path),
  emit `PARTIAL_PASS` with cited file:line, and enumerate a specific
  manual step for the human. See playbook §6 "Code-evidence proactivity".
- **AC drift is a first-class signal.** Ticket #4781 had an AC ("All
  Mosyle-registered devices are listed") that the diff did NOT
  implement (the diff added a lookup-by-SN, not a listing). The agent
  must call this out as `AC_DRIFT`, not silently mark it `NEEDS_HUMAN` —
  someone needs to either reword the AC or file a follow-up. See
  playbook §3b.
- **High-risk areas (MDM, fiscal, register integrations, auth, payments,
  migrations) need both `code-evidence` AND a manual step.** Even when
  the diff is structurally sound, leave a clear breadcrumb for the human.
  Verdict for these cards: prefer `QA_APPROVED_WITH_GATES` over
  `QA_APPROVED`.

## Env-propagation gotchas

- **`QA_ADMIN_EMAIL` / `QA_ADMIN_PASSWORD` must be in `$QA_RIG_ROOT/
  orchestrator/.env`.** Adding them to `env.example` doesn't auto-merge
  into a deployed `.env`. The deploy script now warns when they're
  missing (since 2026-05-14). When they're missing, the orchestrator
  sets `QA_UI_TIER_AVAILABLE=0` and the agent should gracefully
  downgrade `admin-ui` AC to `code-evidence` instead of hard-failing.
- **Check `QA_UI_TIER_AVAILABLE` at classification time** (step 3), not
  at execution time. Generating UI specs that can't run is wasted work.
  If `=0`, classify all admin-ui AC as `code-evidence` from the start.

## 2026-05-18 — Ticket #4735 (Como Branch ID) — preemptive-skip anti-pattern

The agent verdict was `QA_APPROVED_WITH_GATES`, but the UI tier was
**never run** — the agent declared "intentionally not executed" citing
data-gating + a misread of the #4795 lessons-learned entry. Edvardas
flagged this as a regression: the agent should have tried first.

**Why this was wrong:**

1. Data-gating was overstated. AC-3 ("Branch ID field appears when
   Como is selected") doesn't need a pre-existing Como-configured
   venue. The agent could have picked any venue, enabled loyalty,
   selected Como in the provider dropdown, and asserted the field
   appears. Conditional rendering is testable by TOGGLING the
   precondition in the test itself — not only by finding pre-staged
   data.

2. The #4795 lessons-learned entry about "test user has partial
   permission claims" was misapplied. That entry describes how to
   **diagnose** a failure when it happens, NOT permission to skip
   pre-emptively on future tickets. The agent read the lesson, saw
   "permission gating possible", and stopped before even trying.

3. AC-6 ("required validation when Como is selected") is also UI-
   testable end-to-end — toggle to Como, clear field, click Save,
   assert toast — none of which needs pre-existing data.

**Corrective behavior (added to qa-card.md §13.0):**

- Always run the relevant tier first. Run, observe, then react.
- Lessons-learned is for diagnosing AFTER a failure, not for skipping
  before trying.
- If an AC requires a precondition (provider selection, loyalty
  enabled, etc.), set the precondition IN the test before asserting.
- `PARTIAL_PASS via code-evidence` is the fallback when live
  verification genuinely fails or can't run — it is NOT a substitute
  for trying.

If the UI tier hits a real gate on retry → mark `PARTIAL_PASS` with
the SPECIFIC reason observed (screenshot, network error, missing
element after the recovery sequence). That's an honest verdict.
Pre-emptive skip with speculation isn't.

## 2026-05-18 — Ticket #4795 (Org Edit timezone dropdown) — three findings

The agent found three actionable issues; two are Dserve code bugs, one
is a rig bug.

1. **Rig: `playwright.config.ts` pinned `testDir: "."`.** The agent had
   to copy specs into `playwright-runtime/qa-scratch-4795/` to get them
   discovered. **Fixed 2026-05-18:** `playwright.config.ts` now reads
   `process.env.PLAYWRIGHT_TEST_DIR || "."`, and `ui-tier.sh` sets
   `PLAYWRIGHT_TEST_DIR=$SPEC_DIR` before invoking `npx playwright
   test`. The deploy script now also re-runs `install-playwright.sh`
   on every deploy (was guarded by node_modules absence), so config
   regen lands automatically.

2. ~~**Dserve bug: MasterAdmin permission-claim inconsistency.**~~
   **[Retracted 2026-05-18 — incorrect attribution.]** The agent
   reported `OrganizationGrid.razor:83` lacks a MasterAdmin bypass
   while `OrganizationEdit.razor:900` has one, and recommended
   centralizing the bypass in `AdminPermissionService.HasAsync`.
   Edvardas confirmed this is wrong: in Dserve, **MasterAdmin role
   already grants all permissions by design** (almost certainly via
   claim expansion at login or a middleware the agent didn't grep).
   The agent stopped at the leaf `HasAsync` method and didn't trace
   where claims come from. Don't recommend code changes to "add MA
   bypass" — the bypass exists somewhere; the agent just hasn't found
   it.

   **What the agent SHOULD do when a MasterAdmin user appears
   permission-blocked:**
   - **DO NOT skip future UI runs pre-emptively because this happened
     once.** This lesson exists to guide diagnosis when a failure
     happens, NOT to justify avoiding the UI tier on subsequent
     tickets. Always run the spec first; recover on actual failure.
   - Treat the observed failure as a **data/session issue**, not a
     code bug
   - First hypothesis: stale Playwright session — drop the saved
     `storageState`, re-login, retry
   - Second hypothesis: the test user's role assignment in the DB is
     broken (partially-MA) — operational fix, not code
   - Third hypothesis: a real auth path bug somewhere upstream of
     `HasAsync` — only after the first two are ruled out
   - Never recommend a per-page bypass fix as the resolution. If
     anything looks centralized-able, the answer is "trace the
     existing centralization, not add another"

3. ~~**Dserve bug: standalone `/organizations/{id}` hang.**~~
   **[Withdrawn 2026-05-18 — not a bug.]** The agent flagged a hang on
   the standalone `@page "/organizations/{id}"` URL when the user
   lacks edit permission. Edvardas clarified: this URL is NOT a
   supported entry point. The only valid path to OrganizationEdit is
   the UI flow (Organizations grid → row action → Edit menu → dialog).
   The `@page` annotation exists for the dialog routing system, not
   for direct URL access by users. The hang is a side-effect of
   reaching the page through an unsupported path. **Playbook §13
   updated to forbid direct-URL fallbacks as a recovery step.**

   General rule: many Dserve admin pages declare `@page "/area/{id}"`
   but are designed for dialog use only. When the agent reads .razor
   source and sees a route, it should NOT assume that URL is a valid
   user entry point. The user-click navigation chain (top nav → grid →
   row action) is the contract. If that chain is gated, stop at the
   gate and emit `NEEDS_HUMAN` naming the gate — don't route around it.

## Permissions: MasterAdmin = all access (design contract)

**Design rule confirmed by Edvardas (2026-05-18):** the MasterAdmin
role implies all permission claims. A MasterAdmin user must have full
admin access without per-claim seeding in `UserClaims`.

The leaf method `AdminPermissionService.HasPermission` IS claims-based
(`ClaimsPrincipalExtensions.cs:6-7` does `user.HasClaim("Permission", X)`),
but the claims must be populated upstream — at login, in a middleware,
or via role-to-claims expansion in the auth setup. The agent should
NOT stop at the leaf method; it should trace where the claims come
from (`Startup.cs`, `AuthConfig.cs`, login handlers) to verify the
expansion exists.

**Diagnostic checklist when a MasterAdmin user appears to be missing
permission claims:**

1. **Stale Playwright session.** Maybe storageState was saved before
   claim expansion finished. Force a fresh login and retry.
2. **Login path bug.** Trace
   `AuthConfig.cs` / `AdminAuthService` / `CustomAuthStateProvider`
   to find where claims are set after login. Verify the
   `UserRole.MasterAdmin` branch adds all `Permission.*` claims.
3. **DB state on the specific user.** Confirm the user's role is
   actually `MasterAdmin` in the DB (not just visible-because-of-cache).

If all three check out and the user still lacks claim X at runtime,
that's a real Dserve auth bug worth filing — not a test-setup issue.

The agent's first observation on ticket #4795 was that role-gated UI
rendered (Add button, Reset organizations) but claim-gated UI didn't
(Edit menu, `_canEdit=false`). That internal inconsistency in the same
session is the signal: either Playwright captured a half-expanded
session, or there's a real bug in the expansion path.

**Agent behavior when a permission gap blocks a MasterAdmin user:**
verdict `NEEDS_HUMAN` is acceptable, but name the diagnostic options
(stale session vs. bug in expansion vs. DB state) so the human knows
what to check first. Don't conclude "user lacks claim X" — that's only
true if the design were "claims required at the DB level", which it
isn't here.

## Specific Dserve.Admin selectors discovered

- `ExtraComponentsGrid.razor` — page-level fields like `_mdmLookupSerial`
  / `_mdmLookupDeviceId` are stable per-circuit (Blazor Server isolates
  them per connection); safe to use for multi-step UI tests.
- Radzen `Disabled=@condition` produces a real DOM `disabled` attribute
  on the rendered `<input>` / `<button>`; Playwright's `isDisabled()`
  works as expected.

## 2026-05-14 — Runtime environment bugs surfaced on first real run

The first end-to-end run on the mini found two infrastructure bugs (not
code issues in the card under test — bugs in the QA rig itself):

1. **`DOTNET_ROLL_FORWARD` value typo.** `ui-tier.sh` was setting
   `DOTNET_ROLL_FORWARD="Disabled"`. The valid values per Microsoft docs
   are `LatestPatch`, `Minor`, `LatestMinor`, `Major`, `LatestMajor`,
   `Disable` (no "d"). dotnet silently accepts unknown values as "no
   override" — so the env var was effectively ignored, and dotnet would
   roll forward to whatever shared framework was available (defeating
   the purpose of pinning to net8). Fixed in `ui-tier.sh` (2026-05-14).
   This bug also exists in the source skill; flag it if you see it
   re-introduced.

2. **.NET 8 not installed on the QA host.** The mini had .NET 10 only
   (`Microsoft.NETCore.App 10.0.3`, `Microsoft.AspNetCore.App 10.0.3`)
   but `Dserve.Admin` targets `net8.0`. Without the 8.x ASP.NET Core
   shared framework, `dotnet run --project Dserve.Admin` fails to
   start. **Correct fix (`--overwrite`, not `--force`):**
   ```
   brew install dotnet@8
   brew link --overwrite dotnet@8
   ```
   On a host with .NET 10 already linked at `/opt/homebrew/bin/dotnet`,
   `brew link --force dotnet@8` fails with "Could not symlink
   bin/dotnet — Target already exists". `--overwrite` is required.
   Don't ever recommend `--force` in install hints — it has bitten this
   rig once and will again.

   `ui-tier.sh` pre-checks for `Microsoft.AspNetCore.App 8.x` and exits
   with a clear install hint if missing (exit code 6). The deploy
   script also warns at deploy time when 8.x is missing.

## .NET runtime version policy

- `Dserve.Admin.csproj` and `Dserve.SelfService.Integration.csproj` both
  target `net8.0`. Both projects need the 8.x shared framework to run.
- Higher major versions (.NET 9, .NET 10) may be ALSO installed —
  that's fine. The runner pins to 8 via `DOTNET_ROLL_FORWARD=LatestPatch`
  (NOT `Disable` — see below), so a newer major won't accidentally be
  used but patch deltas within net8 are tolerated.
- If the team upgrades the target to net9 / net10 in the future,
  search this repo for `Microsoft.AspNetCore.App 8\.` and bump those
  checks too. The version pin is in:
    - `qa-agent/runners/ui-tier.sh` (preflight grep)
    - `deploy-trello-update.sh` (deploy-time warning)

## 2026-05-14 — Dynamic Pricing run (#4751) — two more rig bugs

1. **`DOTNET_ROLL_FORWARD=Disable` was too strict.** Projects ship a
   `runtimeconfig.json` pinned to the version they were built against
   (often `8.0.0`), but the installed runtime is the latest patch
   (`8.0.25`). With `Disable`, the runtime refuses even patch-level
   roll-forward and the app exits at startup with a frameworks-missing
   error. **Fix:** `LatestPatch` — keeps the major.minor pin (no
   accidental net9/10 use) but tolerates `8.0.0 → 8.0.25`. Applied
   2026-05-14 to `ui-tier.sh`.

2. **`--no-launch-profile` strips the dev connection string.** The SQL
   Server and Mongo connection strings live in
   `Dserve.Admin/Properties/launchSettings.json` under the profile's
   `environmentVariables`. `--no-launch-profile` (which we use to
   prevent the launchSettings `applicationUrl` from overriding our QA
   port `:5080`) discards those env vars too — so `Startup.cs:79`
   throws "Cannot retrieve connection string from environment
   variables" and the app dies. **Fix:** the runner now extracts the
   `environmentVariables` from launchSettings.json (skipping
   `ASPNETCORE_HOSTPORT` / `ASPNETCORE_URLS` so our QA-port overrides
   win), writes them to `$QA_OUT_DIR/admin-env.sh`, sources that, then
   runs `dotnet run --no-launch-profile`. Applied 2026-05-14 to
   `ui-tier.sh`. See the new "1c. Source the dev profile's
   environmentVariables" block.

   Long-term improvement (out of QA-agent scope): the dev connection
   strings should move from `launchSettings.json` into
   `appsettings.Development.json`, which survives `--no-launch-profile`
   and is the conventional place for environment-specific config. File
   as a follow-up if the team agrees.

3. **Worktree branch lock when dev + QA target the same ticket.**
   Observed when the developer pipeline finishes a PR for `feature/N`
   and the user immediately fires `qa #N`. The developer worktree
   (`projects/main`) holds `feature/N` checked out; the QA worktree
   tries to `git checkout feature/N` and git refuses with
   `fatal: 'feature/N' is already checked out at '.../projects/main'`.
   Git's local-branch lock spans worktrees. **Fix:** QA worktree now
   always uses `git checkout --detach origin/<head_ref>` — never
   creates or switches to a local branch. Detached HEAD is not locked
   against other worktrees; QA never commits or pushes anyway, so a
   local branch was always unnecessary. Applied 2026-05-14 to
   `run_qa_pipeline` in `orchestrator.py`.

   The recovery path also got simpler: previously we had to
   "detach → reset → clean → try local checkout → fall back to
   creating a tracking branch" — five git calls with multiple failure
   modes. Now it's "fetch → reset → clean → detach onto
   origin/<head>" — four calls, single happy path.

## Run #4948 (Admin) — CustomizationProfile color field + runner path gotchas

- **`Select organization` modal blocks Configuration pages on fresh login.**
  Navigating to any `/configuration/*` page right after the login helper shows
  a Radzen dialog titled "Select organization" (no current org in storage).
  It renders `.rz-dialog-wrapper` which intercepts ALL pointer events, so any
  click on the page underneath times out with "rz-dialog-wrapper intercepts
  pointer events". Handle it first: open the Organization `.rz-dropdown`,
  pick the first option, click `button:has-text("Confirm")`.

- **Radzen dropdown option selection — scope to the VISIBLE panel.**
  `.rz-dropdown-panel .rz-dropdown-item` matches items in EVERY dropdown's
  panel in the DOM (e.g. the "Venues" dropdown panel is present but hidden),
  so `.first()` often resolves to an invisible item → click times out. Use
  `.rz-dropdown-panel:visible .rz-dropdown-item` and add a keyboard fallback
  (`ArrowDown` + `Enter`) for filtered/virtualized panels.

- **CustomizationProfilesGrid → Edit dialog flow:** `/configuration/customizationProfiles`,
  pick org, click `button.add-button:has-text("Add")` (create) or the per-row
  `.context-menu-button` (dots icon) → `RadzenMenuItem Text="Edit"`. The editor
  is `CustomizationProfileEdit.razor` opened via `DialogService.OpenAsync`
  (700px). Color rows are `<div class="row">` with a `RadzenLabel` + a
  `.rz-colorpicker` + a "Restore" `RadzenButton`.

- **shotWithHighlight needs PLAIN CSS** — its `page.evaluate(document.querySelector(sel))`
  rejects Playwright-only `:has-text()`. Tag the target first
  (`await loc.evaluate(el => el.setAttribute('data-qa-target','x'))`) and pass
  `[data-qa-target="x"]`.

- **`/configuration/customizationProfiles` lands on a TAB VIEW that defaults to
  the "Category Icons" tab, NOT the profiles grid.** (Confirmed 2026-06-10.)
  The Configuration page has tabs: Category Icons | Tags | Customization profiles |
  Adyen | CircleK. Navigating to the route shows Category Icons first; clicking
  "Add" there opens a **"Create image"** dialog (category icon), not the profile
  editor — the AC label will never be found. Fix: after navigation, click
  `.rz-tabview-title:has-text("Customization profiles")`, wait for networkidle,
  THEN Add/Edit. The profile editor dialog title is **"Create customization
  profile"**; the new tint field lives in the **"Footer"** fieldset, immediately
  after Cart Button/Badge color rows. On this host an org ("123 express") was
  already selected post-login, so the "Select organization" modal did NOT appear —
  keep the dismiss handler but don't depend on it firing.

- **ui-tier.sh path gotchas (this rig install):**
  - `QA_PLAYWRIGHT_RUNTIME` was set to a RELATIVE value (`playwright-runtime`);
    export it absolute: `$HOME/dserve-qa-skill-data/playwright-runtime`.
  - `QA_OUT_DIR` must be ABSOLUTE — the runner writes `$QA_OUT_DIR/login.log`
    etc. from inside `cd "$RUNTIME_DIR"` subshells; a relative QA_OUT_DIR makes
    login.log writes fail and the runner reports "login failed".
  - Specs live OUTSIDE the runtime's node_modules tree, so `import "@playwright/test"`
    fails with "Cannot find module". Fix: symlink the runtime node_modules into
    the spec dir (`ln -sfn $RUNTIME/node_modules $SPEC_DIR/node_modules`).

## Run #4941 (KDS profile language) — AC4/AC5 unit-testable via pure ResolveTitle (2026-06-18)

The KDS "selected language vs. fallback-to-primary" decision (AC4/AC5) lives
entirely in one PURE method: `ProductTitleTranslationModel.ResolveTitle(LanguageCode?)`
(`Dserve.Models/Products/ProductTitleTranslationModel.cs`). No DB, no
WebApplicationFactory needed — write a plain `[Fact]` class that does NOT derive
from `IntegrationTest`, just `new ProductTitleTranslationModel{...}` and assert.
`Dserve.Models` + `Dserve.Core` are referenced transitively by
`Dserve.SelfService.Integration` (via `Dserve.SelfServiceApi`), so `using
Dserve.Models.Products;` + `using Dserve.Core.Enums;` resolve fine. The
api-tier.sh runner builds + runs the scoped `QaScratch.T<ticket>` filter as-is.
Six [Fact]s (en/no slot hit, null→primary, no-slot fallback, empty-text
fallback, no-slots-at-all) ran in ~0.05s, all green. Fallback shapes to cover:
(1) requested lang not in Language2/Language3, (2) lang matches but Title text
empty/null, (3) product has no translation slots at all.

Service wiring (for the code-evidence half of AC4): order-product titles are
localised ONCE at order-creation time — `KdsService.LocaliseOrderProductTitlesAsync`
(KdsService.cs, called from CreateOrder ~:443) → `MenuService.GetProductTitleTranslationsAsync`
→ `ResolveTitle`. Fetch/display path returns stored titles verbatim (no per-read
lookup). Behavioral nuance worth flagging to PM: changing a profile's language
only affects orders created AFTER the change; in-flight orders keep their
creation-time language. The translation is best-effort/fail-safe (try/catch,
never blocks order creation).

CONFIRMED AGAIN (matches the admin-selectors.md #4941 note): on a NEW KDS
profile the "Display Language" RadzenDropDown renders VISUALLY BLANK in the
collapsed state — it does NOT display the "Default (primary language)" label
even though the bound value (null) is functionally the primary language. AC2 is
functionally correct but the default isn't shown to the user — keep flagging this
as a PASS-with-UX-note for a human/PM eyeball, not a FAIL. Open panel correctly
shows: Default (primary language), Lietuvių, English, Norwegian (test org).

---

## RULE — Any UI change ships a GENUINE screenshot; design images are NOT evidence (2026-07-03)

Concrete miss on **#5078** (QR "Scan and pay" popup — CTA hierarchy + light
toggle): the run posted the ticket's own *design reference* image to the
Trello card and treated it as screenshot evidence. It isn't. No live capture
of the actual change was ever produced.

The rule, now mechanically enforced (`scripts/qa_evidence.py`, wired into
`qa_attach.py` + `qa_post.py`, exit code 3):

- If a ticket changes UI or affects UI functionality, the run MUST include ≥1
  **genuine** QA capture in `$QA_OUT_DIR/screenshots/` — a Playwright
  `shotWithHighlight` named `ac-<n>-*` / `eshop-ac-<n>-*` / `orders-ac-<n>-*`
  / `cross-system-*`.
- The card's OWN design / mockup / Figma / reference images do NOT count.
  Never copy the design image into `screenshots/` and pass it off as a result.
  Files whose name contains design|reference|ref-|mockup|figma|ticket|
  spec-image|prefix are classified reference-only and ignored by the gate.
- Gated / hard-to-reach UI is NOT an excuse. Force the state: `page.route(...)`
  API mock, redux/localStorage injection, sentinel-driven flow, or isolated
  component render. Example for #5078: the QR modal only opens after an order
  and the light bulb is venue-gated to Apollo Cinema — both are forceable by
  mocking the create-order response (to set `qrPaymentUrl`) and injecting a
  cinema `restaurantId` into redux so `useIsScreenDimVenue()` is true.
- Set `"ui_change": true` + `"live_screenshots_captured": <n>` in
  `qa-telemetry.json`. Only when a capture is genuinely impossible: verdict
  `QA_NEEDS_HUMAN`, explain why, and publish with `--allow-no-shots`.

Also fixed here: `qa_attach.py` now posts the two split summaries
(`qa-summary-qa.md` + `qa-summary-dev.md`), not just the legacy
`qa-trello-summary.md` — previously it silently posted no comment when only
the split files existed.

---

## RULE — QA evidence MUST come from the real running application, never a staged harness (2026-07-03)

Second miss on **#5078**: after being told to always capture a real screenshot,
the run captured one by mounting the REAL `QrPaymentModal` in an isolated Vite
harness with a self-populated redux store (`restaurantId` faked to the cinema
venue) and fabricated props, then posted those as evidence. That is NOT testing
the running application — it's staging a render of your own making. It can pass
while the real app + real backend behave differently. Rejected and removed.

Hard rule (now enforced in `qa_evidence.py` via `evidence_source`):
- Evidence = screenshots of the ACTUAL running application, driven through its
  real user flow against the real (dev) backend. Nothing else counts.
- FORBIDDEN as evidence: isolated component harness, component mounted with a
  mocked/hand-built redux store, fabricated props, storybook, any staged render.
- Prefer the real backend over `page.route` mocks. If a mock is unavoidable to
  reach a state, disclose it; it caps the verdict at `QA_NEEDS_HUMAN`.
- To reach a gated/hard state, drive the REAL flow / use REAL test data (a real
  cinema tablet token, an actual test order) — do not fabricate the state.
- If it can't be reached on QA infra: verdict `QA_NEEDS_HUMAN`, state exactly
  what's needed (real cinema tablet, permission to place a dev order, kiosk
  eyeball) and ask. Do NOT synthesize evidence to close the gap.
- Set `"evidence_source": "real-app"` in telemetry; `harness`/`isolated`/`mock`/
  `staged` are rejected by the gate (exit 3).

---

## RULE — eshop visual QA runs BOTH mobile and desktop, always (2026-07-03)

Every eshop UI AC must be captured on BOTH viewports: mobile 390×844 AND
desktop 1366×900. Never verify a single viewport. Name captures with a
`-mobile` / `-desktop` suffix (`eshop-ac-<n>-<short>-mobile.png` /
`-desktop.png`) — both still match the evidence-gate capture pattern.
Mobile-only concerns (bottom-sheet height/margins, cutoffs, sticky footers)
must be shown specifically on the mobile viewport. Origin of rule: #5078 had
a mobile-only full-screen-sheet fix that a desktop-only capture would miss.
