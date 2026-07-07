# Eshop (self-service-web) — Running it locally for QA + payment-gated flows

Practical, battle-tested recipe for driving the REAL running eshop against
the real dev backend, including reaching payment-gated screens (the QR
"Scan and pay" modal). Learned the hard way on ticket #5078. Follow this and
you won't repeat the mistakes.

Golden rule (see lessons-learned): QA evidence must come from the REAL running
app — never an isolated component harness / mocked store / staged render.
The technique below reaches even gated states organically, no mocks.

---

## 0. Environment gotchas (hit these every time)

- **PATH gets clobbered.** After `source scripts/lib.sh` or when mixing dotnet,
  a raw shell can lose `/usr/bin`. Prepend it in EVERY bash command:
  `export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"`.
- **zsh `--include=*.tsx` fails** ("no matches found"). Use
  `grep -rIn "pat" src` and filter with a second `grep`, or quote the glob.
- **`qa_prepare.py` resets the worktree** (`git reset --hard` + `git clean -fd`).
  This DELETES untracked files: your `.env.local`, any throwaway vite config,
  and your Playwright driver. Re-create them after every prepare (see below).
- **The eshop needs `.env.local` or Vite won't start** — it throws
  `vite-plugin-environment: the VITE_APP_ENV environment variable is undefined`.
  Restore it: `cp /Users/DSERVE/Documents/GitHub/self-service-web/.env.local \
  /Users/DSERVE/Documents/GitHub/self-service-web-qa/.env.local`.
  It points the eshop at the real dev API: `VITE_APP_API_URL=https://ss-dev.dserve.app/api`.

## 1. Start the eshop (plain HTTP, quick smoke)

```bash
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
cd /Users/DSERVE/Documents/GitHub/self-service-web-qa
# .env.local must exist (see above)
nohup npx vite --port 3000 --host > /tmp/eshop.log 2>&1 &
# wait for HTTP 200 on http://localhost:3000/
```

Route is `/:tabletId`. Load a tablet: `http://localhost:3000/<tabletId>`.

## 2. Known test tablet / venue (Apollo Cinema, dark theme, light-bulb enabled)

- Tablet: `1a5b1cf0-d39f-4ef0-9a06-35aad2352179`
- Resolves to venue **"Action by Apollo"**, `restaurantId 15e5c7b8-7eba-428d-a492-3908c0a53116`
- That id is the single entry in `SCREEN_DIMMER_VENUE_IDS` (`src/utilities/screenDim.ts`),
  so `useIsScreenDimVenue()` is true → the cinema screen-dim / light-bulb affordances render.
- It renders its own **dark** custom theme — the real cinema look (good for
  verifying dark-theme contrast, e.g. the QR modal close-X).
- Menu has "Savory sticks with cheese" cookies (8.69 €); order type is **Table only**.

## 3. Reach the QR "Scan and pay" modal (payment-gated) — the flow

`QrPaymentModal` opens in `Checkout` only when `qrPaymentUrl` is set, i.e. AFTER
creating a real order via a web-payment method. Steps (Playwright):

1. goto `<origin>/1a5b1cf0-...`, wait networkidle.
2. Add a product: click a category → `[data-testid="product-item"]` → in
   `[data-testid="product-page"]` auto-select the first required option (see
   eshop-selectors) → "Add to cart".
3. Open cart (floating `[data-testid="cart-button"]`, use `.first()`). On MOBILE
   there is an EXTRA cart-review step needing one more "Order" tap before payment.
4. Order type is set to **Table** automatically for this venue.
5. On "Placing an Order" → click **Order** → PaymentSelectModal appears with
   **"Bank Transfer or Card"** (EveryPay `webCard`) and **"Client code"**.
6. Click **"Bank Transfer or Card"** → real `POST /api/qr/orders` (201) →
   `qrPaymentUrl` set → the real "Scan and pay" QR modal renders.
   Stop here — do NOT complete payment (the QR is the state we verify).
   This DOES create a real order on dev (expected; a few throwaway orders are fine).

## 4. THE BLOCKER: localhost Origin is rejected for web payments

Symptom: at step 6 you get an "Important info — **Selected payment type is not
available**" modal, and `POST /api/qr/orders` returns **400** (internalErrorCode
201). Cause: the dev backend allow-lists the venue's real origin for EveryPay.

Isolated fact (probe the endpoint):
- `Origin: http://localhost:3000`      → **400** "payment type not available"
- `Origin: https://gg-dev.dserve.app`  → **201** with a real EveryPay link

`GroupHost` / `WebshopLocationUrl` headers do NOT matter — only the browser
`Origin` (and `Referer`). A browser on `localhost` cannot spoof its own Origin,
and Playwright `route.continue({headers})` can't change it either. Do NOT rewrite
the request (that's not real QA). Instead, make the browser's REAL origin correct:

## 5. FIX: serve HTTPS locally + Chromium host-resolver (real Origin, no sudo, no mocks)

The browser genuinely loads the page from `https://gg-dev.dserve.app`, so it
sends a real `Origin: https://gg-dev.dserve.app`, while the TCP connection is
transparently redirected to your local HTTPS Vite server. Fully organic.

```bash
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
# self-signed cert (CN is irrelevant; Playwright ignores cert errors)
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/qa-key.pem \
  -out /tmp/qa-cert.pem -days 2 -subj "/CN=gg-dev.dserve.app"
```

Throwaway Vite config `vite.qa-https.config.ts` in the worktree (imports the
base config, overrides `server`):
```ts
import base from './vite.config'
import fs from 'fs'
export default {
  ...base,
  server: {
    https: { key: fs.readFileSync('/tmp/qa-key.pem'), cert: fs.readFileSync('/tmp/qa-cert.pem') },
    port: 5199, host: '127.0.0.1', allowedHosts: true, hmr: false,
  },
}
```
Run it: `npx vite --config vite.qa-https.config.ts` (kill any plain :3000 first).

Playwright launch (Chromium):
```js
const browser = await chromium.launch({
  args: ['--host-resolver-rules=MAP gg-dev.dserve.app 127.0.0.1:5199',
         '--ignore-certificate-errors'],
})
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: {...} })
const page = await ctx.newPage()
await page.goto('https://gg-dev.dserve.app/1a5b1cf0-d39f-4ef0-9a06-35aad2352179')
// window.location.origin is now https://gg-dev.dserve.app → Origin + GroupHost both correct.
// You do NOT need VITE_FORCE_MAIN_HOST — getGroupHost() = window.location.origin here.
```
Prove it's organic: passively observe the create-order (`page.on('response')`) —
expect **201** and log the request's `Origin` header. No `page.route*` anywhere.

## 6. Dual viewport (mandatory for eshop visual QA)

Always capture BOTH: desktop 1366×900 AND mobile 390×844 (deviceScaleFactor 2,
touch). Suffix files `-desktop` / `-mobile`. Mobile-only concerns (bottom-sheet
height/margins/cutoffs) must be shown on the mobile viewport. Run the flow once
per viewport (each creates its own order).

## 7. Cleanup

Kill servers (`pkill -f "vite --config vite.qa-https.config.ts"`, `pkill -f "vite --port 3000"`),
remove scratch (`vite.qa-https.config.ts`, driver `.mjs`, `/tmp/qa-*.pem`). The
worktree is reset on the next `qa_prepare` anyway, but tidy up so nothing leaks.

## 8. Backend note for payment QA

The QR flow uses EveryPay. Return URL is built from the order's `GroupHost`
(`getGroupHost()` → `VITE_FORCE_MAIN_HOST` if set, else `window.location.origin`),
but the real gate is the browser **Origin** (§4). See dserve-backend
`Dserve.Services/EveryPayService.cs` (`InitiateOneOffPayment`, `CustomerUrl`).
