# QA Lessons Learned

Hard-won knowledge from running QA on this codebase. Read before writing a new test.

---

## Test File Location

**ALWAYS put test files in `tests/specs/`**, not `e2e/` or root.

```
self-service-web/
  tests/
    specs/        ← PUT TESTS HERE
    helpers/
  playwright.config.ts  ← testDir: './tests'
```

`playwright.config.ts` sets `testDir: './tests'` — Playwright will not find specs in `e2e/` or other directories.

---

## Backend: .NET 8 vs .NET 10

The `dserve-backend` project targets `net8.0`. As of 2026-05, only `.NET 10` is installed on the QA machine.

- Running `dotnet run` will attempt a roll-forward to .NET 10 — the app starts but Blazor assets return 404, making Admin UI unreachable.
- **Workaround for eshop tests:** Set `VITE_APP_API_URL=https://ss-dev.dserve.app/api` in `.env.local` to route all API calls to the staging server.
- **Impact on backend AC:** Backend ACs must be verified by code diff only; live API tests go via ss-dev.
- Check: `dotnet --list-runtimes | grep "Microsoft.AspNetCore.App 8"` before attempting Admin tests.

---

## .env.local Must Point to ss-dev for Live Tests

The default `.env.local` uses `localhost:5020` (local backend). For live Playwright tests without a running backend:

```
# Change this:
VITE_APP_API_URL=http://localhost:5020/api
# To this:
VITE_APP_API_URL=https://ss-dev.dserve.app/api
```

**Remember to restore after the test run.** The file is not committed but developers expect it to point locally.

---

## Home Page Shows Categories, Not Products

A common mistake: writing a test that immediately looks for `[data-testid="product-item"]` after loading the home page. It will timeout.

The home page renders **category cards** first. You must click a category before products appear.

```typescript
// WRONG — will timeout on fresh page load
await page.waitForSelector('[data-testid="product-item"]')

// CORRECT
await page.getByText('Main dishes').click()
await page.waitForSelector('[data-testid="product-item"]')
```

---

## Product Modal Has Required Options

Many products require selecting an option (sauce, size, temperature, etc.) before the "Add to cart" button becomes active. If you try to click "Add to cart" immediately after opening the modal, it either does nothing or the button is disabled.

These option buttons have **no data-testid and no aria-label** — use `page.evaluate()` to click them (see `eshop-selectors.md`).

---

## `__dirname` Not Available in ESM Test Files

Playwright TypeScript tests run as ESM modules. Using `__dirname` directly causes:
```
ReferenceError: __dirname is not defined in ES module scope
```

**Workaround:** Either use hardcoded absolute paths, or reconstruct:
```typescript
import { fileURLToPath } from 'url'
import path from 'path'
const __dirname = path.dirname(fileURLToPath(import.meta.url))
```

Or just hardcode the path string if it's a QA output directory.

---

## Screenshot Saving in Playwright

`page.screenshot()` does NOT create the destination directory automatically. The directory must exist before the call.

```typescript
// Ensure directory exists before screenshotting
import fs from 'fs'
fs.mkdirSync('/path/to/screenshots', { recursive: true })
await page.screenshot({ path: '/path/to/screenshots/my-shot.png' })
```

Or use a hardcoded path that already exists (e.g. `/tmp/`).

---

## Backend Project Name

The backend API project (not Admin) is:
```
Dserve.SelfServiceApi/
```
Not `Dserve.Api/`, not `Dserve.Web/`. When running `dotnet run --project`, use:
```bash
dotnet run --project Dserve.SelfServiceApi/
```

---

## Google Places in Tests

- Google Places autocomplete is **not mockable** via `page.route()` unless you intercept the Google Maps JS bundle — don't attempt this.
- For delivery address tests, always use a real network connection and let the real Places API run.
- Use a known stable address like `'savanoriu 123'` which reliably produces Savanorių Prospektas 123, Kaunas as the 2nd suggestion.
- After typing, `waitForSelector('.pac-item', { timeout: 10000 })` — 10s is needed because Places API can be slow.

---

## z-index / Overlay Conflicts (Lesson from ticket #4684)

A UI element can pass all AC tests but still be visually broken if it's behind an overlay.

**Real example:** A floating button passed AC verification but was completely hidden by the product modal on mobile viewport (390×844). This only appeared during manual testing.

**Rule:** For any new floating/fixed/sticky UI element, always run the scenario matrix from `qa-ticket` SKILL.md Step 9f — especially: product modal open on mobile, cart drawer open on mobile.

Use `elementFromPoint()` to assert the element is not covered:
```typescript
const covered = await page.evaluate(([x, y, sel]) => {
  const target = document.querySelector(sel)
  const top = document.elementFromPoint(x, y)
  return !target?.contains(top) && top !== target
}, [cx, cy, selector])
expect(covered).toBe(false)
```

---

## .NET 8 Runtime Detection (Lesson from ticket #4714)

`dotnet --list-runtimes` only shows runtimes registered under the **active** `dotnet` binary on PATH.
On this machine, `dotnet` points to Homebrew's dotnet 10 formula, but .NET 8 is installed separately under `dotnet@8`.

**Always check both:**
```bash
dotnet --list-runtimes | grep "AspNetCore.App 8"
ls /opt/homebrew/opt/dotnet@8/libexec/shared/Microsoft.AspNetCore.App/ 2>/dev/null
```

**To start Admin with .NET 8:**
```bash
export DOTNET_ROOT=/opt/homebrew/opt/dotnet@8/libexec
$DOTNET_ROOT/dotnet run --project Dserve.Admin/ --launch-profile "Dserve.Admin" &
```

Do NOT set `DOTNET_ROLL_FORWARD=Disabled` — not a valid value in .NET 8 and causes a startup crash.

---

## Blazor Admin: Org Selection Dialog (Lesson from ticket #4714)

After login, a "Select organization" dialog appears with a Radzen dropdown. Playwright's `.click()` fails
because the dropdown panel overlay intercepts pointer events on the Confirm button.

**Working pattern:** Use `page.evaluate()` to drive the entire dialog via JS:
```javascript
await page.evaluate(async () => {
  const dropdown = document.querySelector('.rz-dropdown')
  dropdown.click()
  await new Promise(r => setTimeout(r, 800))
  const panel = document.querySelector('.rz-dropdown-panel, [id^="popup-"]')
  panel.querySelector('.rz-dropdown-item').click()
  await new Promise(r => setTimeout(r, 400))
  Array.from(document.querySelectorAll('button'))
    .find(b => b.textContent?.trim() === 'Confirm')
    ?.click()
})
await page.waitForLoadState('networkidle')
await page.waitForTimeout(3000)
```

---

## Blazor ProtectedLocalStorage (Lesson from ticket #4714)

The Admin "Click to update menu!" button is gated by `ProtectedLocalStorage` (encrypted via ASP.NET Data Protection).
Cannot be forced via `localStorage.setItem()` from Playwright JS — it uses a different encrypted format.

**Workaround:** Make a real product/category change in Admin to trigger the notification flag organically,
then test the button. Or mark as NEEDS_REVIEW and note what manual steps are needed.
