# Dserve.Admin — Playwright selectors + interaction recipes

Confirmed patterns for driving the Blazor + Radzen.Blazor 4.28.x Admin
panel from Playwright. Use these instead of inventing fresh
selectors — when a control is fiddly, the playbook expects you to
look here first, and add a recipe back here if you solve a NEW one.

All examples assume:
- `page` is the Playwright Page bound to `http://localhost:${QA_ADMIN_PORT}`
- Admin login already happened (via `admin-login.ts.tmpl`) so
  `storageState` carries the auth cookie

---

## RadzenColorPicker — hex entry + commit

The most reliable way to set a `<RadzenColorPicker>` to an exact hex
value. Tested via the Customization Profile edit screen in run #4948.

The component renders as a square swatch button. Clicking it opens a
popup with a saturation/value gradient + an `HexValue` text input.
**Drive only the HexValue input** — the gradient is for humans and
hard to position pixel-perfect from Playwright.

```typescript
async function setRadzenColorPicker(page, fieldLabel: string, hex: string) {
  // Open the picker. The trigger is the colored square next to the label.
  // Find by label proximity: label > sibling .rz-colorpicker-trigger.
  const trigger = page.locator(
    `label:has-text("${fieldLabel}") + * .rz-colorpicker-trigger, ` +
    `label:has-text("${fieldLabel}") ~ * .rz-colorpicker-trigger, ` +
    `[aria-label="${fieldLabel}"] .rz-colorpicker-trigger`
  ).first();
  await trigger.click();
  // Wait for the popup. Radzen renders it portaled to <body>.
  const popup = page.locator('.rz-colorpicker-content').last();
  await popup.waitFor({state: 'visible'});
  // Type into HexValue, normalize to no-#, uppercase. Component accepts both.
  const hexInput = popup.locator('input[name="HexValue"], .rz-hex input');
  await hexInput.click({clickCount: 3});       // select all
  await hexInput.fill(hex.replace(/^#/, ''));
  await hexInput.press('Enter');                // commits + closes
  // Belt + braces: if popup didn't close on Enter, click outside.
  await page.locator('body').click({position: {x: 5, y: 5}, force: true})
    .catch(() => { /* popup already closed */ });
}

async function getRadzenColorPickerValue(page, fieldLabel: string): Promise<string> {
  // The swatch button's inline background-color exposes the current value.
  // Read computed style, parse rgb(N,N,N) → #NNNNNN.
  const trigger = page.locator(
    `label:has-text("${fieldLabel}") + * .rz-colorpicker-trigger, ` +
    `label:has-text("${fieldLabel}") ~ * .rz-colorpicker-trigger, ` +
    `[aria-label="${fieldLabel}"] .rz-colorpicker-trigger`
  ).first();
  const bg = await trigger.evaluate(el => getComputedStyle(el).backgroundColor);
  // rgb(N, N, N) → #NNNNNN
  const m = bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
  if (!m) return bg;
  const hex = [m[1], m[2], m[3]].map(n => parseInt(n).toString(16).padStart(2, '0')).join('');
  return `#${hex.toUpperCase()}`;
}
```

**Round-trip test usage:**

```typescript
test("ac-N: <field> color round-trips across reload", async ({ page }) => {
  // Sentinel: per-run unique hex so different QA runs don't clash.
  const sentinel = `#FF${Date.now().toString(16).slice(-6).toUpperCase()}`;
  await page.goto(`${ADMIN_URL}/configuration/customization-profiles/edit/<id>`);
  await page.waitForLoadState('networkidle');

  await setRadzenColorPicker(page, "Added To Cart Notification Tint Color", sentinel);

  // Submit + wait for save round-trip
  const savePromise = page.waitForResponse(
    r => r.request().method() !== "GET" && /api/.test(r.url())
  );
  await page.locator('button:has-text("Save")').click();
  const saveResp = await savePromise;
  expect(saveResp.status(), `Save returned ${saveResp.status()}`).toBeLessThan(400);

  // Reload, verify persistence
  await page.reload();
  await page.waitForLoadState('networkidle');
  const got = await getRadzenColorPickerValue(page, "Added To Cart Notification Tint Color");
  expect(got).toBe(sentinel);

  await shotWithHighlight(page,
    `${process.env.QA_SCREENSHOT_DIR}/ac-N-roundtrip-after-reload.png`,
    `label:has-text("Added To Cart Notification Tint Color")`);
});
```

**Why not Radzen's `[value]` attr?**
The component doesn't surface its current value as a stable HTML
attribute — `[value]` on the trigger is empty. The swatch's
`background-color` computed style is the only reliable read-back.

---

## RadzenDropDown — select by visible text

Radzen wraps the dropdown in a custom popup; native `<select>`
selectors don't work.

```typescript
async function selectRadzenDropDown(page, fieldLabel: string, optionText: string) {
  const dropdown = page.locator(
    `label:has-text("${fieldLabel}") + * .rz-dropdown, ` +
    `label:has-text("${fieldLabel}") ~ .rz-dropdown`
  ).first();
  await dropdown.click();
  // The popup renders portaled to <body>. Find by role + name.
  await page.locator(`.rz-dropdown-panel li:has-text("${optionText}")`).first().click();
}
```

For **virtualized** dropdowns (Organizations, Venues — hundreds of
items), scroll the list before clicking:

```typescript
await page.locator('.rz-dropdown-panel').evaluate((el, target) => {
  // Scroll until target text comes into view
  const items = el.querySelectorAll('li');
  for (const item of items) {
    if (item.textContent?.includes(target)) {
      item.scrollIntoView({block: 'center'});
      return;
    }
  }
}, optionText);
```

---

## RadzenDataGrid — find a row by cell content

```typescript
async function clickGridRowByText(page, cellText: string) {
  await page.locator(`.rz-datatable tr:has-text("${cellText}")`).first().click();
}

// Or click an action button inside a specific row:
async function clickRowAction(page, rowText: string, action: "Edit" | "Delete") {
  const row = page.locator(`.rz-datatable tr:has-text("${rowText}")`).first();
  await row.locator(`button:has-text("${action}"), [aria-label="${action}"]`).first().click();
}
```

Grids are **virtualized** vertically. If the row isn't visible:

```typescript
await page.locator('.rz-data-grid-data, .rz-datatable-data').first()
  .evaluate(el => { el.scrollTop = el.scrollHeight; });
// Then retry. May need multiple scroll passes for long tables.
```

For **columns** outside the visible viewport (horizontal scroll):

```typescript
await page.evaluate(() => {
  const wrap = document.querySelector('.rz-datatable-wrapper, .rz-data-grid-table-wrapper');
  if (wrap) wrap.scrollLeft = 9999;
});
```

---

## RadzenDatePicker — typed entry

```typescript
async function setRadzenDate(page, fieldLabel: string, isoDate: string) {
  // "2026-06-10" → typed into the picker's text input
  const input = page.locator(
    `label:has-text("${fieldLabel}") + * input.rz-datepicker-input, ` +
    `label:has-text("${fieldLabel}") ~ * input.rz-datepicker-input`
  ).first();
  await input.click({clickCount: 3});
  await input.fill(isoDate);
  await input.press('Tab');  // commit
}
```

The popup calendar UI is hard to drive precisely. Typed entry is
faster and just as reliable.

---

## Saving + waiting for the server response

Every `Save` / `Submit` button in Admin posts via Blazor's SignalR
hub. Two patterns:

```typescript
// 1. Wait for the API call (most reliable for forms with HTTP-API saves)
const resp = page.waitForResponse(r =>
  r.request().method() !== "GET" && /api/.test(r.url())
);
await page.locator('button:has-text("Save")').click();
await resp;

// 2. Wait for the toast notification (works for Radzen-managed saves)
await page.locator('button:has-text("Save")').click();
await page.locator('.rz-notification-success, .rz-toast-success')
  .waitFor({state: 'visible', timeout: 5000});
```

If both fail (e.g. silent save with no toast), fall back to a `wait
for networkidle` after the click and re-read the persisted value to
confirm.

---

## Select organization modal (master-admin scoped pages)

Master-admin views often pop a "Select organization" modal on page
load. Dismiss it before doing anything else:

```typescript
await page.goto(ADMIN_URL + '/configuration/customization-profiles');
// Modal may or may not appear depending on stored selection
const modal = page.locator('.rz-dialog:has-text("Select organization")');
if (await modal.isVisible().catch(() => false)) {
  await selectRadzenDropDown(page, "Organization", process.env.QA_DEFAULT_ORG_NAME || "Dserve");
  await modal.locator('button:has-text("OK"), button:has-text("Continue")').first().click();
  await modal.waitFor({state: 'hidden'});
}
```

Set `QA_DEFAULT_ORG_NAME` in `.env` (or use a hardcoded default in
the spec) so this is deterministic.

---

## Test data hygiene — sentinel values

When you must mutate the dev DB, pick values that are:

1. **Unique per run** — use `Date.now()` or the test name.
2. **Recognizable** — prefix with `qa-`, `QA-`, or use distinctive hex
   like `#FF1234` so a human eyeballing the dev DB can spot QA traffic.
3. **Reversible by no-op** — if the AC is "color persists", don't pick
   the SAME color twice in a row across runs (would yield a false
   positive on round-trip — value was already there). Always
   randomize.

Common sentinel patterns:

```typescript
const RUN_ID = Date.now().toString(36).slice(-6);
const sentinelText = `QA-${RUN_ID}-${ticket}`;
const sentinelHex = `#FF${Date.now().toString(16).slice(-6).toUpperCase()}`;
const sentinelEmail = `qa-${RUN_ID}@test.qa.local`;
```

---

## Adding a new recipe

When you solve a new fiddly control during a QA run, append a section
to this file. Format:

```markdown
## <ControlName> — <task>

<one-paragraph explanation of the gotcha>

```typescript
<the minimum code that works>
```

Tested via: ticket #<N>, <date>.
```

Don't gold-plate — the next agent reading this needs the recipe, not
an essay.

---

## RadzenColorPicker — CONFIRMED popup structure + reliable hex entry (run #4948, 2026-06-10)

The RadzenColorPicker popup (`ShowRGBA ShowHSV`) renders portaled to <body>
as `.rz-colorpicker-popup.rz-popup`. Inside `.rz-colorpicker-rgba` there are
five `.rz-color-box` cells: a **Hex** text input then R/G/B/A numeric spinners:

```html
<input aria-label="Hex" class="rz-textbox" ...>
<input aria-label="R" class="rz-spinner-input" ...>   <!-- + G, B, A -->
```

**Use the Hex input, NOT the R/G/B spinners.** The spinners sit to the right
and get **clipped off the viewport edge** when the popup opens near the right
side (Playwright reports "element is not visible" on B / A). The Hex box is
leftmost and always on-screen.

```typescript
const popup = page.locator('.rz-colorpicker-popup, .rz-colorpicker-content').last();
await popup.waitFor({ state: 'visible' });
const hexInput = popup.locator('input[aria-label="Hex"]').first();
await hexInput.click({ clickCount: 3 });
await hexInput.fill(hex.replace(/^#/, ''));   // 6 hex digits, no '#'
await hexInput.press('Enter');
await hexInput.press('Tab');                  // commit via blur
// close popup by clicking the dialog title bar (not the page underneath)
await dialog.locator('.rz-dialog-titlebar').first().click({ force: true });
```

Read-back: the closed trigger swatch exposes the value as a computed
`background-color` on a descendant of `.rz-colorpicker`. Scan descendants for
the first non-transparent / non-white bg and parse `rgb()` → hex. Allow ±4 per
channel (HSV round-trip rounding).

## CustomizationProfilesGrid — row context menu "Edit" (run #4948)

The per-row dots button is `button.context-menu-button`. Clicking it opens a
**Radzen ContextMenu** (NOT a RadzenMenu) portaled as `.rz-contextmenu`. Items
render as `.rz-navigation-item` with text in `.rz-navigation-item-text` —
`.rz-menuitem` does NOT match here.

```typescript
await myRow.locator('.context-menu-button').first().click();
const ctxMenu = page.locator('.rz-contextmenu, .rz-menu').last();
await ctxMenu.waitFor({ state: 'visible' });
await ctxMenu.locator('.rz-navigation-item:has-text("Edit")').first().click();
```

Round-trip recipe that works end-to-end for this card: open the
"Customization profiles" tab → `button.add-button:has-text("Add")` → fill
`input[name="Title"]` with a unique sentinel + set the tint via the Hex input →
`button:has-text("Save")` (Submit calls `CustomizationProfileService.CreateAsync`,
real API write) → dialog closes → find `tr:has-text("<sentinel title>")` →
context-menu → Edit → read the persisted swatch. Confirmed PASS 2026-06-10.

NOTE: `shotWithHighlight`'s `scrollIntoView({block:'center'})` does NOT bring
a Footer-fieldset row into the captured frame — the editor dialog renders from
"Basic info" at the top and the screenshot viewport shows the top portion. The
tint field lives in the **Footer** fieldset (below the fold). Functional
asserts still pass; just don't expect the swatch itself to be centered in the
PNG without scrolling the dialog body explicitly.

---

## Specs at $QA_OUT_DIR/playwright need a node_modules symlink (run #4914, 2026-06-15)

The ui-tier runner runs `npx playwright test` from `$RUNTIME_DIR` with
`PLAYWRIGHT_TEST_DIR=$QA_OUT_DIR/playwright`. Node resolves `import {test} from
"@playwright/test"` by walking UP from the spec file's directory — which has no
`node_modules` — so specs fail with **"Cannot find module '@playwright/test'"**
and Playwright reports "No tests found" (stats.expected=0). The login spec works
only because the runner copies it INTO `$RUNTIME_DIR`.

Fix before running the UI tier:
```bash
ln -sfn "$HOME/dserve-qa-skill-data/playwright-runtime/node_modules" \
        "$QA_OUT_DIR/playwright/node_modules"
```
(Exporting `NODE_PATH` to the runtime node_modules also works as a belt.)

## AuditLogsGrid (/auditLogs) filter bar — direct-child selectors (run #4914)

`.audit-filter-bar` has exactly FOUR direct children, in order:
`[0]` From RadzenDatePicker (`div`, empty class), `[1]` To RadzenDatePicker,
`[2]` Organization `div.rz-dropdown`, `[3]` Apply `button.rz-button`.

Gotchas that wasted attempts:
- `bar.querySelector(".rz-dropdown")` can return a ZERO-SIZE nested match — use
  the DIRECT child `'.audit-filter-bar > .rz-dropdown'` instead.
- `'.rz-button'` matches the **datepicker calendar trigger** (icon-only, w≈20)
  before the Apply button. Apply is the only direct-child `<button>`:
  `'.audit-filter-bar > button'`.
- There are THREE `input.rz-inputtext` in the bar (2 date inputs + the
  dropdown's AllowFiltering filter input), so `toHaveCount(2)` fails — scope to
  children or use `.rz-datepicker` inputs.
- Measure the four DIRECT children's `getBoundingClientRect()` to verify
  alignment/height. After the fix all four are y=71, h=40 (2.5rem), cy=91 →
  baseline+height spread 0.0px.
- A **"Select organization" modal** (`rz-dialog`) pops on load for the
  master-admin test user (multi-org, no preselected org) and intercepts
  center-clicks on the bar. The bar still renders/aligns above it; use
  `click({force:true})` for Apply, and treat dropdown-open as best-effort.

## "Select organization" context modal — BLOCKS /configuration on fresh sessions (run #4948, 2026-06-15)

The master-admin test user (`QA_ADMIN_EMAIL`) has NO persisted current-org.
On a fresh login storageState (the ui-tier runner re-logs in every run), the
global **"Select organization"** modal (`.rz-dialog:has-text("Select
organization")`) opens EMPTY over `/configuration/*` and intercepts every
click — including the `Customization profiles` tab and the grid `Add` button.
It has two `.rz-dropdown` (Organization, Venues) + a `Confirm` button; BOTH
dropdowns must hold a value before Confirm dismisses it.

Tried and still blocked this run: clicking `Confirm` directly (no-op while
empty); opening each `.rz-dropdown` and picking the first item via
`.rz-dropdown-panel:visible .rz-dropdown-item`; opening each dropdown and
`ArrowDown`+`Enter` keyboard selection; 3× retry loop; re-dismiss after the
tab click. In all cases the modal's Organization field stayed empty (selection
did not commit) so Confirm never dismissed it, and the subsequent tab click
timed out "element is visible, enabled and stable" → intercepted by the modal
overlay.

The prior #4948 run (2026-06-10) PASSED end-to-end ONLY because that session
already had a current org persisted server-side, so the modal never appeared.

NEXT TIME: this is a context/auth gate, not a selector miss. Options for a
human/rig to unblock: (a) pre-seed a current org+venue for the QA admin user
server-side so the modal doesn't prompt; (b) set a `QA_DEFAULT_ORG_NAME` env +
solve the in-modal Radzen org dropdown commit (the keyboard + first-item click
approaches above did NOT commit — likely the org list is virtualized/filtered
and needs a typed filter then explicit `li.rz-dropdown-item` click on the
portaled panel). Until then, `/configuration` admin-ui AC for this user must
fall back to code-evidence + a manual gate.

---

## KdsProfileEdit — "Display Language" dropdown + Create-via-Add path (run #4941, 2026-06-18)

KDS profile editor route: `/venues/kdsprofiles` -> the page is a TAB VIEW
(`Venues | Register profiles | KDS profiles`); click the `KDS profiles` tab
(`.rz-tabview-title:has-text("KDS profiles")`). Both the grid `Add`
(`button.add-button:has-text("Add")` -> "Create KDS profile" dialog) and a row's
context-menu `Edit` open the SAME `KdsProfileEdit` component via
`DialogService.OpenAsync` (900px). On this host the KDS grid is EMPTY for the
default org ("No records to display"), so use the **Add** path — no existing
profile needed to verify the editor's fields.

EMPTY-GRID GHOST BUTTON: the empty Radzen grid renders a hidden/unstable
`button.context-menu-button` in the frozen first column that intermittently
matches `:visible` and then detaches mid-click. Do NOT gate the row-Edit path on
row presence; gate on the explicit "No records to display" message, or just use
Add (it opens the same editor).

NESTED-ROW SCOPING (important): the editor lays fields in nested rows —
`div.row > div.col-md-6 > div.row > div.col-8 (label) + div.col-4 (.rz-dropdown)`.
The OUTER `.row` contains BOTH "TV Font Size" and "Display Language", so a naive
`div.row:has(label:has-text("Display Language")) .rz-dropdown` grabs the WRONG
(TV Font Size, value "Regular") dropdown. Scope to the label's IMMEDIATE row:
```typescript
page.locator('div.col-8:has(label:has-text("Display Language"))')
    .locator('xpath=parent::div[contains(@class,"row")]')
    .locator('.rz-dropdown').first();
```
The "Display Language" RadzenDropDown on a NEW profile renders `rz-state-empty`
(visually BLANK), but its bound value/text content IS "Default (primary language)"
(Id=null). Confirmed options for the test org: `Default (primary language)`,
`Lietuvių`, `English`, `Norwegian` — i.e. org's OrganizationsLanguages +
AddDefaultLanguages. Note for AC "default = primary language": functionally
correct (null -> ResolveTitle returns primary Title) but the create-form does
not DISPLAY the default label — worth a human eyeball.

ORG MODAL is non-deterministic across runs (fresh login each run): sometimes
opens pre-filled ("12eat TEST"/"ADMIN" -> just Confirm), sometimes EMPTY with
"Select organization" validation errors -> must select BOTH dropdowns first. A
loop that selects the first visible `.rz-dropdown-panel:visible .rz-dropdown-item`
in each, verifies the dropdown text became non-empty, then clicks Confirm
(retry x3) DID dismiss it reliably this run.

shotWithHighlight gotcha (confirmed again): pass a PLAIN selector. Tag the
target first via a Playwright locator
(`loc.evaluate(el => el.setAttribute('data-qa-target','x'))`) and pass
`[data-qa-target="x"]` — `:has`/`:has-text` throw in document.querySelector.

ENV gotchas this rig: (1) Playwright runtime was MISSING at
`~/dserve-qa-skill-data/playwright-runtime` — bootstrap with
`runners/install-playwright.sh` (downloads Chromium ~265MB). (2) Default `dotnet`
on PATH is .NET 10; Dserve.Admin targets net8.0 and ui-tier.sh rejects it. Force
.NET 8: `export PATH="/opt/homebrew/opt/dotnet@8/bin:$PATH"; export
DOTNET_ROOT="/opt/homebrew/opt/dotnet@8/libexec"` before calling the runners.
