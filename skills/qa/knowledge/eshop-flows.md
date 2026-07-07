# Eshop (self-service-web) — Test Flows

Step-by-step navigation patterns verified against `ss-dev.dserve.app`.
These are the building blocks for any eshop Playwright test.
Sourced from colleague's qa-ticket skill.

All flows assume:
- Vite dev server running at `http://localhost:$QA_ESHOP_PORT` (default 5173)
- `VITE_APP_API_URL=https://ss-dev.dserve.app/api` (or local backend if running)
- `QA_TABLET_TOKEN` env set (from keychain via the orchestrator)

---

## Flow 1: Home → Category → Product Modal → Cart

```typescript
const ESHOP_URL = process.env.QA_ESHOP_URL ?? 'http://localhost:5173';
const TOKEN = process.env.QA_TABLET_TOKEN ?? '';

// 1. Load with tablet token
await page.goto(`${ESHOP_URL}/?tabletToken=${TOKEN}`);
await page.waitForLoadState('networkidle');

// 2. Click a category (home shows categories, not products)
await page.getByText('Main dishes').click();
await page.waitForSelector('[data-testid="product-item"]');

// 3. Click a product card to open the modal
await page.locator('[data-testid="product-item"]').first().click();
await page.waitForSelector('[data-testid="product-page"]');

// 4. If product has required options, select one before adding to cart
await page.evaluate(() => {
  const productPage = document.querySelector('[data-testid="product-page"]');
  if (!productPage) return;
  const buttons = Array.from(productPage.querySelectorAll('button')).filter(b => {
    const text = (b.textContent || '').trim();
    return (
      text.length > 4 &&
      !b.getAttribute('data-testid') &&
      !b.getAttribute('aria-label') &&
      !/^(add|more info|\d+\.\d+)/i.test(text)
    );
  });
  if (buttons.length > 0) (buttons[0] as HTMLButtonElement).click();
});

// 5. Click "Add to cart" inside the modal
await page.getByRole('button', { name: /add to cart/i }).click();

// 6. Wait for modal to close
await page.waitForFunction(() => !document.querySelector('[data-testid="product-page"]'));
```

---

## Flow 2: Cart → Checkout → Select Delivery

```typescript
await page.getByRole('button', { name: /checkout|proceed/i }).click();
await page.waitForLoadState('networkidle');

await page.getByText('Delivery').click();
await page.waitForTimeout(300); // form animation
```

---

## Flow 3: Delivery Address via Google Places

```typescript
const addressInput = page.locator(
  'input[placeholder*="address" i], input[placeholder*="Enter" i]'
).first();
await addressInput.click();
await addressInput.type('savanoriu 123', { delay: 80 });

// Google Places dropdown
await page.waitForSelector('.pac-item', { timeout: 10000 });

// Pick the 2nd suggestion (index 1) — reliably returns Savanorių 123, Kaunas
await page.locator('.pac-item').nth(1).click();
await page.waitForTimeout(500);
```

**Gotchas:**
- Google Places needs real network — NOT mockable via `page.route()` unless
  you intercept the JS bundle (don't).
- `.pac-item` loads async — always `waitForSelector(timeout: 10000)`.
- `'savanoriu 123'` reliably surfaces Savanorių Prospektas 123, Kaunas at
  index 1. Other inputs vary in stability.

---

## Flow 4: API Intercept During a Flow

See `eshop-api-intercept.md` for the full pattern catalog. Quick example:

```typescript
let capturedPayload: any = null;
page.on('request', req => {
  if (req.url().includes('/calculate') || req.url().includes('calculateOrderPrice')) {
    try { capturedPayload = JSON.parse(req.postData() || '{}'); } catch {}
  }
});

// ... run your flow ...

expect(capturedPayload).not.toBeNull();
expect(capturedPayload.deliveryLatitude).toBeTruthy();
```

---

## Flow 5: Delivery — Full End-to-End (reference, ticket #4718)

```typescript
test('delivery fields present in calculateOrderPrice', async ({ page }) => {
  let capturedPayload: any = null;
  page.on('request', req => {
    if (req.url().includes('calculateOrderPrice') || req.url().includes('/calculate')) {
      try { capturedPayload = JSON.parse(req.postData() || '{}'); } catch {}
    }
  });

  await page.goto(`${ESHOP_URL}/?tabletToken=${TOKEN}`);
  await page.waitForLoadState('networkidle');

  // Add a product
  await page.getByText('Main dishes').click();
  await page.waitForSelector('[data-testid="product-item"]');
  await page.locator('[data-testid="product-item"]').first().click();
  await page.waitForSelector('[data-testid="product-page"]');

  // Select required option if present (see selectors)
  await page.evaluate(() => { /* … option click helper … */ });

  await page.getByRole('button', { name: /add to cart/i }).click();
  await page.waitForFunction(() => !document.querySelector('[data-testid="product-page"]'));

  // Checkout → Delivery
  await page.getByRole('button', { name: /checkout|proceed/i }).click();
  await page.waitForLoadState('networkidle');
  await page.getByText('Delivery').click();
  await page.waitForTimeout(300);

  // Fill address with Google Places
  const input = page.locator('input[placeholder*="address" i]').first();
  await input.click();
  await input.type('savanoriu 123', { delay: 80 });
  await page.waitForSelector('.pac-item', { timeout: 10000 });
  await page.locator('.pac-item').nth(1).click();
  await page.waitForTimeout(1500);

  expect(capturedPayload).not.toBeNull();
  expect(capturedPayload.deliveryLatitude).toBeTruthy();
  expect(capturedPayload.deliveryLongitude).toBeTruthy();
  expect(capturedPayload.deliveryStreet).toBeTruthy();
  expect(capturedPayload.deliveryCity).toBeTruthy();
});
```

---

## Flow 6: Table Order — At-the-table + To-the-waiter Payment (reference, 2026-05-08)

Verified on **desktop-chromium** AND **mobile-chromium** against
`gg-dev.dserve.app`.

**Key discovery:** desktop and mobile have different checkout entry flows.
Desktop opens an order-type modal directly; mobile shows a cart review
page first and requires an extra "Order" tap before the order-type
buttons appear.

```typescript
import { test, expect } from '@playwright/test';

const ESHOP_URL = process.env.QA_ESHOP_URL ?? 'http://localhost:5173';
const TOKEN = process.env.QA_TABLET_TOKEN ?? '';
const VENUE_TABLET_ID = '54a8432a-3f4b-463b-ad32-a0d5879b738d';

test('place a table order and select "To the waiter" payment', async ({ page }) => {
  let orderResponse: any = null;
  page.on('response', async res => {
    if (res.url().includes('/orders') && res.request().method() === 'POST') {
      try { orderResponse = await res.json(); } catch {}
    }
  });

  // 1. Load eshop
  await page.goto(`${ESHOP_URL}/?tabletToken=${TOKEN}`);
  await page.waitForLoadState('networkidle');

  // 2. Handle venue group selection modal (if visible)
  const venueBtn = page.getByTestId(`restaurant-option-${VENUE_TABLET_ID}`);
  if (await venueBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
    await venueBtn.click();
    await page.waitForLoadState('networkidle');
  }

  // 3. Wait for product cards
  await page.waitForSelector('[data-testid^="product-card-"]', { timeout: 15000 });

  // 4. Open first product modal
  await page.locator('[data-testid^="product-card-"]').first().click();
  await page.waitForSelector('[data-testid="product-page"]', { timeout: 8000 });

  // 5. Select required option if present (no testid/aria-label)
  await page.evaluate(() => {
    const pp = document.querySelector('[data-testid="product-page"]');
    if (!pp) return;
    const btn = Array.from(pp.querySelectorAll('button')).find(b => {
      const t = (b.textContent || '').trim();
      return t.length > 4 && !b.getAttribute('data-testid') && !b.getAttribute('aria-label')
        && !/^(add|more info|\d+\.\d+)/i.test(t);
    });
    if (btn) (btn as HTMLButtonElement).click();
  });
  await page.waitForTimeout(300);

  // 6. Add to cart — use cart-button.first() (2+ in DOM)
  await page.getByTestId('cart-button').first().click();
  await page.waitForFunction(() => !document.querySelector('[data-testid="product-page"]'), { timeout: 8000 });
  await page.waitForTimeout(500);

  // 7. Open checkout (floating cart button)
  //    Desktop: opens "Placing an Order" modal with order-type buttons
  //    Mobile:  opens cart review page — needs extra step (7b)
  await page.getByTestId('cart-button').first().click();
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(1500);

  // 7b. Mobile adaptation
  if (!(await page.getByTestId('order-type-table').isVisible({ timeout: 2000 }).catch(() => false))) {
    await page.locator('[data-testid="cart-button"]').filter({ hasText: /order/i }).first().click({ force: true });
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(1000);
  }

  // 8. Select "At the table"
  await page.getByTestId('order-type-table').waitFor({ timeout: 8000 });
  await page.getByTestId('order-type-table').click();
  await page.waitForTimeout(500);

  // 9. Fill email
  await page.locator('input[name="email"]').fill('qa@test.com');

  // 10. Fill comment if present (desktop only)
  const commentInput = page.locator(
    'input[placeholder="Enter comment"], textarea[placeholder="Enter comment"]'
  );
  if (await commentInput.isVisible({ timeout: 2000 }).catch(() => false)) {
    await commentInput.fill('Test order - QA');
  }
  await page.waitForTimeout(300);

  // 11. Submit order
  await page.locator('[data-testid="cart-button"]').filter({ hasText: /order/i })
    .first().click({ force: true });
  await page.waitForTimeout(1000);

  // 12. "Enter your name" popup
  const nameInput = page.locator('input[placeholder="Enter name"]');
  await nameInput.waitFor({ timeout: 8000 });
  await nameInput.fill('Test User');
  await page.getByRole('button', { name: /done/i }).click();
  await page.waitForTimeout(1500);

  // 13. Payment method — "To the waiter"
  const waiterPayment = page.getByText('To the waiter').first();
  await waiterPayment.waitFor({ timeout: 10000 });
  await waiterPayment.click();
  await page.waitForTimeout(3000);

  // 14. Assert
  expect(orderResponse).not.toBeNull();
  expect(orderResponse?.paymentType).toBe('cashier');       // 'cashier' = To the waiter
  expect(orderResponse?.guestIdentification).toBe('Test User');
});
```

### API response fields (POST /orders)

| Field | Expected | Notes |
|-------|----------|-------|
| `paymentType` | `'cashier'` | To the waiter payment code |
| `paymentStatus` | `'unpaid'` | Awaiting waiter |
| `guestIdentification` | name from popup | Shown to kitchen staff |

---

## Flow 7: Cross-System — Admin Change → Eshop Effect

For AC that span both surfaces (e.g. "color set in Admin shows in eshop"):

```typescript
test('Admin change is reflected in eshop', async () => {
  const browser = await chromium.launch();

  // 1. Admin context with saved auth
  const adminContext = await browser.newContext({
    storageState: process.env.QA_ADMIN_STATE_FILE
  });
  const adminPage = await adminContext.newPage();
  await adminPage.goto(process.env.QA_ADMIN_URL ?? 'http://localhost:5080');
  await adminPage.waitForLoadState('networkidle');

  // 2. Eshop context (fresh)
  const eshopContext = await browser.newContext();
  const eshopPage = await eshopContext.newPage();
  const TOKEN = process.env.QA_TABLET_TOKEN ?? '';
  await eshopPage.goto(`${ESHOP_URL}/?tabletToken=${TOKEN}`);
  await eshopPage.waitForLoadState('networkidle');

  // 3. Make the change in Admin (real API write — not mocked)
  // Example:
  //   await adminPage.fill('[data-field="primary-color"]', '#FF5500');
  //   await adminPage.click('button:has-text("Save")');
  //   await adminPage.waitForResponse(r => r.url().includes('/api/settings'));

  // 4. Reload eshop and assert the change is reflected
  // Example:
  //   await eshopPage.reload();
  //   await eshopPage.waitForLoadState('networkidle');
  //   await expect(eshopPage.locator('.btn-primary'))
  //     .toHaveCSS('background-color', 'rgb(255, 85, 0)');

  await browser.close();
});
```

**Key principle:** the Admin write goes through the REAL API so the eshop
fetches the updated value on reload. Test the full DB round-trip — don't
mock either side. Cross-system tests are slower (~30-60s) but give the
strongest signal for "did this actually change behavior."

---

## Flow 8: Reach the QR "Scan and pay" modal + run the eshop locally

Payment-gated (the modal only opens after a real web-payment order) and there's
a localhost-Origin blocker. Full recipe — how to start the eshop, the known
Apollo Cinema test tablet, the real-Origin HTTPS + Chromium host-resolver
technique (no mocks, no sudo), and dual-viewport rules — lives in a dedicated
doc: **`knowledge/eshop-local-run.md`**. Read it before any QR-payment or
payment-gated eshop spec.
