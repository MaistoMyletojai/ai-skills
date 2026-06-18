# Eshop API Intercept Patterns

How to intercept, assert, and mock API calls in Playwright tests against the eshop.

---

## Known API Routes

All routes are under the base URL configured in `.env.local` (`VITE_APP_API_URL`).

| Route | Method | Triggered By |
|-------|--------|-------------|
| `/api/qr/orders/calculate` | POST | Selecting a delivery address (calculateOrderPrice) |
| `/api/qr/orders` | POST | Clicking "Place Order" (createOrder) |
| `/api/qr/menu` | GET | Page load — fetches menu/categories |
| `/api/qr/settings` | GET | Page load — fetches venue settings, theme |

**Note:** The exact path may vary — always match by `.includes('/calculate')` or `.includes('/orders')` rather than full URL to survive API version changes.

---

## Pattern 1: Passive listener (captures all matching requests)

Use when you want to capture the last request of a type across multiple triggers.

```typescript
let capturedPayload: any = null
let capturedResponse: any = null

page.on('request', req => {
  if (req.url().includes('calculateOrderPrice') || req.url().includes('/calculate')) {
    try { capturedPayload = JSON.parse(req.postData() || '{}') } catch {}
  }
})

page.on('response', async res => {
  if (res.url().includes('calculateOrderPrice') || res.url().includes('/calculate')) {
    try { capturedResponse = await res.json() } catch {}
  }
})

// ... run your flow ...

expect(capturedPayload).not.toBeNull()
expect(capturedResponse.status).toBe(200) // or check res.ok()
```

---

## Pattern 2: waitForRequest (one-shot, race with trigger)

Use when the request fires as a direct result of one specific action.

```typescript
const [request] = await Promise.all([
  page.waitForRequest(req =>
    req.method() === 'POST' &&
    (req.url().includes('/calculate') || req.url().includes('calculateOrderPrice'))
  ),
  page.locator('.pac-item').nth(1).click() // the action that triggers the call
])

const payload = JSON.parse(request.postData() || '{}')
expect(payload.deliveryLatitude).toBeTruthy()
```

---

## Pattern 3: waitForResponse (assert HTTP status)

```typescript
const [response] = await Promise.all([
  page.waitForResponse(res =>
    res.url().includes('/calculate') && res.status() === 200
  ),
  page.locator('.pac-item').nth(1).click()
])

expect(response.ok()).toBe(true)
const body = await response.json()
// e.g. expect(body.deliveryFee).toBeGreaterThan(0)
```

---

## Pattern 4: Route interception (mock response)

Use when you want to test without a real backend, or force specific scenarios.

```typescript
await page.route('**/calculateOrderPrice**', async route => {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({ deliveryFee: 5.34, status: 'OK' })
  })
})
```

**Warning:** Only mock when explicitly testing frontend behavior in isolation.
For integration/AC tests, always hit the real API (ss-dev or local backend).

---

## Timing Notes

- `calculateOrderPrice` fires **after** a Google Places address is selected, not during typing
- There can be a 300–800ms delay between `.pac-item` click and the API call
- Add `await page.waitForTimeout(1500)` after address selection if using passive listener pattern
- If using `waitForRequest`/`waitForResponse`, no extra sleep needed — they block until fired

---

## Auth / Token

The eshop authenticates via a `tabletToken` query parameter (not a header).

```typescript
await page.goto(`${ESHOP_URL}/?tabletToken=${process.env.QA_TABLET_TOKEN}`)
```

`QA_TABLET_TOKEN` is set in `.claude/settings.json` env and in `self-service-web/.env.local`.
Value: `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...` (see env file, expires 2032).
