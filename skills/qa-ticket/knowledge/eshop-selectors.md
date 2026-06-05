# Eshop Confirmed Selectors

Verified selectors from live Playwright runs against ss-dev.dserve.app.
Update this file whenever a selector is confirmed or a new one is found.

---

## Data-testid Selectors (stable, prefer these)

| Element | Selector | Notes |
|---------|----------|-------|
| Product page wrapper | `[data-testid="product-page"]` | Appears when product modal is open |
| Product item card (grid) | `[data-testid="product-item"]` | On category product list page |

## Class / Role Selectors (less stable, use as fallback)

| Element | Selector | Notes |
|---------|----------|-------|
| Google Places dropdown item | `.pac-item` | Standard Google Places CSS class |

## page.evaluate() Patterns

### Click first required-option button inside product modal

When a product modal requires selecting an option (sauce, size, etc.) before adding to cart:

```typescript
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
```

**Why this works:** Option buttons inside the product modal lack data-testid and aria-label.
Filtering those out leaves only option buttons. Text length > 4 excludes icon-only buttons.

### Check if product modal is still open

```typescript
const dialogOpen = await page.evaluate(() =>
  !!document.querySelector('[data-testid="product-page"]')
)
```

---

## Navigation Notes

- **Home page shows categories** (e.g. "Main dishes"), NOT products directly
- Must click a category first to see products
- Use `page.getByText('Main dishes')` or the first category card
- After category click, wait: `await page.waitForSelector('[data-testid="product-item"]')`

---

## Known Missing / Unreliable Selectors

| Element | Problem | Workaround |
|---------|---------|------------|
| Checkout "Place Order" button | No stable testid | `page.getByRole('button', { name: /place order/i })` |
| Cart icon / badge | Theme-dependent class | `[aria-label*="cart"]` |
| Order type toggle (delivery/pickup) | Text-based | `page.getByText('Delivery')` |
| Address input field | May be Google-injected | `page.locator('input[placeholder*="address" i]').first()` |
