# Eshop Test Flows

Step-by-step navigation patterns verified against ss-dev.dserve.app.
These are the building blocks for any eshop Playwright test.

---

## Flow 1: Home → Category → Product Modal → Cart

```typescript
// 1. Load with tablet token
await page.goto(`http://localhost:5173/?tabletToken=${process.env.QA_TABLET_TOKEN}`)
await page.waitForLoadState('networkidle')

// 2. Click a category (home shows categories, not products)
await page.getByText('Main dishes').click()
await page.waitForSelector('[data-testid="product-item"]')

// 3. Click a product card to open the modal
await page.locator('[data-testid="product-item"]').first().click()
await page.waitForSelector('[data-testid="product-page"]')

// 4. If product has required options, select one before adding to cart
const optionClicked = await page.evaluate(() => {
  const productPage = document.querySelector('[data-testid="product-page"]')
  if (!productPage) return false
  const buttons = Array.from(productPage.querySelectorAll('button')).filter(b => {
    const text = (b.textContent || '').trim()
    return (
      text.length > 4 &&
      !b.getAttribute('data-testid') &&
      !b.getAttribute('aria-label') &&
      !/^(add|more info|\d+\.\d+)/i.test(text)
    )
  })
  if (buttons.length > 0) {
    (buttons[0] as HTMLButtonElement).click()
    return buttons[0].textContent?.trim()
  }
  return false
})

// 5. Click "Add to cart" inside the modal
await page.getByRole('button', { name: /add to cart/i }).click()

// 6. Wait for modal to close
await page.waitForFunction(() => !document.querySelector('[data-testid="product-page"]'))
```

---

## Flow 2: Cart → Checkout → Select Delivery

```typescript
// After item is in cart, proceed to checkout
await page.getByRole('button', { name: /checkout|proceed/i }).click()
await page.waitForLoadState('networkidle')

// Select delivery order type
await page.getByText('Delivery').click()
await page.waitForTimeout(300) // wait for form to appear
```

---

## Flow 3: Delivery Address with Google Places

This flow fills in a delivery address using Google Places autocomplete.

```typescript
// 1. Find the address input
const addressInput = page.locator('input[placeholder*="address" i], input[placeholder*="Enter" i]').first()
await addressInput.click()

// 2. Type a partial address to trigger suggestions
await addressInput.type('savanoriu 123', { delay: 80 })

// 3. Wait for Google Places dropdown
await page.waitForSelector('.pac-item', { timeout: 10000 })

// 4. Select the desired suggestion (0-indexed; use index 1 for 2nd item)
const pacItems = page.locator('.pac-item')
await pacItems.nth(1).click()

// 5. Wait for the address to be filled in
await page.waitForTimeout(500)
```

**Notes:**
- Google Places requires a real network connection (not mocked) to appear
- The `.pac-item` container loads asynchronously — always `waitForSelector`
- If you need a specific address, type enough to uniquely identify it
- The address `'savanoriu 123'` reliably returns Savanorių Prospektas 123, Kaunas as the 2nd option (index 1)

---

## Flow 4: Intercept API Calls

### Intercept calculateOrderPrice / createOrder

```typescript
// Set up listener BEFORE navigation or action that triggers the call
let capturedPayload: any = null

page.on('request', req => {
  if (req.url().includes('/calculate') || req.url().includes('calculateOrderPrice')) {
    try {
      capturedPayload = JSON.parse(req.postData() || '{}')
    } catch {}
  }
})

// ... trigger the flow ...

// Assert after the call fires
expect(capturedPayload).not.toBeNull()
expect(capturedPayload.deliveryLatitude).toBeTruthy()
```

Alternatively, use `page.waitForRequest` for a one-shot capture:

```typescript
const [request] = await Promise.all([
  page.waitForRequest(req => req.url().includes('/calculate')),
  addressInput.type('savanoriu 123', { delay: 80 })
    .then(() => page.waitForSelector('.pac-item'))
    .then(() => page.locator('.pac-item').nth(1).click())
])
const payload = JSON.parse(request.postData() || '{}')
```

---

## Flow 6: Table Order — At the table + To the waiter payment (reference implementation, 2026-05-08)

Verified on both **desktop-chromium** and **mobile-chromium** against `gg-dev.dserve.app` via local dev server.

**Key discovery:** Desktop and mobile have different checkout entry flows. Desktop opens an order-type modal directly; mobile shows a cart review page first and requires an extra "Order" tap.

```typescript
import { test, expect } from '@playwright/test'

const ESHOP_URL = 'http://localhost:5173'
const TOKEN = process.env.QA_TABLET_TOKEN || ''
const VENUE_TABLET_ID = '54a8432a-3f4b-463b-ad32-a0d5879b738d'

test('place a table order and select "To the waiter" payment', async ({ page }) => {
  let orderResponse: any = null
  page.on('response', async res => {
    if (res.url().includes('/orders') && res.request().method() === 'POST') {
      try { orderResponse = await res.json() } catch {}
    }
  })

  // 1. Load eshop
  await page.goto(`${ESHOP_URL}/?tabletToken=${TOKEN}`)
  await page.waitForLoadState('networkidle')

  // 2. Handle venue group selection modal (if visible)
  const venueBtn = page.getByTestId(`restaurant-option-${VENUE_TABLET_ID}`)
  if (await venueBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
    await venueBtn.click()
    await page.waitForLoadState('networkidle')
  }

  // 3. Wait for product cards
  await page.waitForSelector('[data-testid^="product-card-"]', { timeout: 15000 })

  // 4. Open first product modal
  await page.locator('[data-testid^="product-card-"]').first().click()
  await page.waitForSelector('[data-testid="product-page"]', { timeout: 8000 })

  // 5. Select required option if present (options have no testid/aria-label)
  await page.evaluate(() => {
    const pp = document.querySelector('[data-testid="product-page"]')
    if (!pp) return
    const btn = Array.from(pp.querySelectorAll('button')).find(b => {
      const t = (b.textContent || '').trim()
      return t.length > 4 && !b.getAttribute('data-testid') && !b.getAttribute('aria-label') && !/^(add|more info|\d+\.\d+)/i.test(t)
    })
    if (btn) (btn as HTMLButtonElement).click()
  })
  await page.waitForTimeout(300)

  // 6. Add to cart — use cart-button.first() (there are 2+ in DOM)
  await page.getByTestId('cart-button').first().click()
  await page.waitForFunction(() => !document.querySelector('[data-testid="product-page"]'), { timeout: 8000 })
  await page.waitForTimeout(500)

  // 7. Open checkout (floating cart button)
  //    Desktop: opens "Placing an Order" modal overlay with order-type buttons directly
  //    Mobile:  opens cart review page "Your order" — needs extra step (7b)
  await page.getByTestId('cart-button').first().click()
  await page.waitForLoadState('networkidle')
  await page.waitForTimeout(1500)

  // 7b. Mobile adaptation: if order-type buttons not visible, click "Order" to proceed
  if (!(await page.getByTestId('order-type-table').isVisible({ timeout: 2000 }).catch(() => false))) {
    await page.locator('[data-testid="cart-button"]').filter({ hasText: /order/i }).first().click({ force: true })
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(1000)
  }

  // 8. Select "At the table"
  await page.getByTestId('order-type-table').waitFor({ timeout: 8000 })
  await page.getByTestId('order-type-table').click()
  await page.waitForTimeout(500)

  // 9. Fill email
  await page.locator('input[name="email"]').fill('qa@test.com')

  // 10. Fill comment if present (desktop only — not visible on mobile viewport)
  const commentInput = page.locator('input[placeholder="Enter comment"], textarea[placeholder="Enter comment"]')
  if (await commentInput.isVisible({ timeout: 2000 }).catch(() => false)) {
    await commentInput.fill('Test order - QA')
  }
  await page.waitForTimeout(300)

  // 11. Click the "Order" submit button (cart-button filtered by "Order" text)
  await page.locator('[data-testid="cart-button"]').filter({ hasText: /order/i }).first().click({ force: true })
  await page.waitForTimeout(1000)

  // 12. "Enter your name" popup — fill and dismiss
  const nameInput = page.locator('input[placeholder="Enter name"]')
  await nameInput.waitFor({ timeout: 8000 })
  await nameInput.fill('Test User')
  await page.getByRole('button', { name: /done/i }).click()
  await page.waitForTimeout(1500)

  // 13. Payment method popup — click "To the waiter"
  const waiterPayment = page.getByText('To the waiter').first()
  await waiterPayment.waitFor({ timeout: 10000 })
  await waiterPayment.click()
  await page.waitForTimeout(3000)

  // 14. Assert
  expect(orderResponse).not.toBeNull()
  expect(orderResponse?.paymentType).toBe('cashier')       // 'cashier' = To the waiter
  expect(orderResponse?.guestIdentification).toBe('Test User')
})
```

### Selectors reference for table order flow

| Element | Selector | Notes |
|---------|----------|-------|
| Venue modal option | `getByTestId('restaurant-option-{TABLET_ID}')` | Shown when group has multiple venues |
| Product card | `[data-testid^="product-card-"]` | Prefix selector |
| Product modal | `[data-testid="product-page"]` | |
| Add to cart (modal) | `getByTestId('cart-button').first()` | 2+ cart-buttons in DOM; .first() = modal button |
| Floating cart button | `getByTestId('cart-button').first()` | After modal closes |
| Order type — table | `getByTestId('order-type-table')` | Also: `order-type-takeaway`, `order-type-delivery` |
| Email input | `input[name="email"]` | |
| Comment | `input[placeholder="Enter comment"]` | Optional, desktop only |
| Submit Order button | `[data-testid="cart-button"]` filtered by `/order/i` | |
| Name popup input | `input[placeholder="Enter name"]` | Appears after clicking Order |
| Done button | `getByRole('button', { name: /done/i })` | |
| To the waiter | `getByText('To the waiter').first()` | In payment popup |

### API response fields (POST /orders)

| Field | Expected | Notes |
|-------|----------|-------|
| `paymentType` | `'cashier'` | To the waiter payment code |
| `paymentStatus` | `'unpaid'` | Awaiting waiter |
| `guestIdentification` | name from popup | Shown to kitchen staff |

---

## Flow 5: Delivery Flow — Full End-to-End (reference implementation, ticket #4718)

```typescript
test('delivery fields present in calculateOrderPrice', async ({ page }) => {
  let capturedPayload: any = null
  page.on('request', req => {
    if (req.url().includes('calculateOrderPrice') || req.url().includes('/calculate')) {
      try { capturedPayload = JSON.parse(req.postData() || '{}') } catch {}
    }
  })

  // Load eshop
  await page.goto(`http://localhost:5173/?tabletToken=${process.env.QA_TABLET_TOKEN}`)
  await page.waitForLoadState('networkidle')

  // Add a product
  await page.getByText('Main dishes').click()
  await page.waitForSelector('[data-testid="product-item"]')
  await page.locator('[data-testid="product-item"]').first().click()
  await page.waitForSelector('[data-testid="product-page"]')

  // Select required option if present
  await page.evaluate(() => {
    const pp = document.querySelector('[data-testid="product-page"]')
    if (!pp) return
    const btn = Array.from(pp.querySelectorAll('button')).find(b => {
      const t = (b.textContent || '').trim()
      return t.length > 4 && !b.getAttribute('data-testid') && !b.getAttribute('aria-label') && !/^(add|more info|\d+\.\d+)/i.test(t)
    })
    if (btn) (btn as HTMLButtonElement).click()
  })

  // Add to cart and close modal
  await page.getByRole('button', { name: /add to cart/i }).click()
  await page.waitForFunction(() => !document.querySelector('[data-testid="product-page"]'))

  // Checkout → Delivery
  await page.getByRole('button', { name: /checkout|proceed/i }).click()
  await page.waitForLoadState('networkidle')
  await page.getByText('Delivery').click()
  await page.waitForTimeout(300)

  // Fill address with Google Places
  const input = page.locator('input[placeholder*="address" i], input[placeholder*="Enter" i]').first()
  await input.click()
  await input.type('savanoriu 123', { delay: 80 })
  await page.waitForSelector('.pac-item', { timeout: 10000 })
  await page.locator('.pac-item').nth(1).click()
  await page.waitForTimeout(1500) // allow calculateOrderPrice to fire

  // Assert payload
  expect(capturedPayload, 'calculateOrderPrice was not intercepted').not.toBeNull()
  expect(capturedPayload.deliveryLatitude, 'latitude missing or zero').toBeTruthy()
  expect(capturedPayload.deliveryLongitude, 'longitude missing or zero').toBeTruthy()
  expect(capturedPayload.deliveryStreet, 'street missing').toBeTruthy()
  expect(capturedPayload.deliveryCity, 'city missing').toBeTruthy()
})
```
