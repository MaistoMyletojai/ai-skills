# Eshop (self-service-web) — Confirmed Selectors

Verified selectors from live Playwright runs against `ss-dev.dserve.app`.
Update this file whenever a selector is confirmed or a new one is found.
Sourced from colleague's qa-ticket skill, adapted to this rig.

---

## Data-testid Selectors (stable, prefer these)

| Element | Selector | Notes |
|---------|----------|-------|
| Product page wrapper | `[data-testid="product-page"]` | Appears when product modal is open |
| Product item card (grid) | `[data-testid="product-item"]` | On category product list page |
| Product card (prefix) | `[data-testid^="product-card-"]` | Newer pages — prefix match across all variants |
| Cart button | `[data-testid="cart-button"]` | **Multiple in DOM — always use `.first()`** |
| Order type — table | `[data-testid="order-type-table"]` | Also: `order-type-takeaway`, `order-type-delivery` |
| Venue option (multi-venue groups) | `[data-testid="restaurant-option-<TABLET_ID>"]` | Shown when group has multiple venues |

## Class / Role Selectors (less stable, use as fallback)

| Element | Selector | Notes |
|---------|----------|-------|
| Google Places dropdown item | `.pac-item` | Standard Google Places CSS class |
| Add to cart button (modal) | `page.getByRole('button', { name: /add to cart/i })` | Inside product modal |
| Place Order button | `page.getByRole('button', { name: /place order/i })` | Checkout footer |
| Delivery toggle | `page.getByText('Delivery')` | Text-based order type switch |
| Address input | `input[placeholder*="address" i]` (first match) | May be Google-injected |
| Email input | `input[name="email"]` | Checkout form |
| Comment input | `input[placeholder="Enter comment"]` / textarea | Desktop only — hidden on mobile |
| Name popup | `input[placeholder="Enter name"]` | After clicking Order |
| Done button | `page.getByRole('button', { name: /done/i })` | Name popup confirm |

---

## `page.evaluate()` Patterns

### Click first required-option button inside product modal

Many products require selecting an option (sauce, size, temperature) before
the "Add to cart" button activates. Option buttons have **no data-testid
and no aria-label** — filter them by elimination:

```typescript
const optionClicked = await page.evaluate(() => {
  const productPage = document.querySelector('[data-testid="product-page"]');
  if (!productPage) return false;
  const buttons = Array.from(productPage.querySelectorAll('button')).filter(b => {
    const text = (b.textContent || '').trim();
    return (
      text.length > 4 &&
      !b.getAttribute('data-testid') &&
      !b.getAttribute('aria-label') &&
      !/^(add|more info|\d+\.\d+)/i.test(text)
    );
  });
  if (buttons.length > 0) {
    (buttons[0] as HTMLButtonElement).click();
    return buttons[0].textContent?.trim();
  }
  return false;
});
```

**Why this works:** option buttons lack testid/aria-label and contain
descriptive text. Filtering excludes utility buttons (Add, More info,
prices). Text length > 4 excludes icon-only buttons.

### Check if product modal is still open

```typescript
const dialogOpen = await page.evaluate(() =>
  !!document.querySelector('[data-testid="product-page"]')
);
```

### Coverage check (catches z-index conflicts on floating elements)

Same `assertNotCovered` pattern used in `admin-selectors.md` — works
identically in the eshop. Use for any new floating / fixed / sticky UI
element to detect "hidden behind product modal" type bugs.

---

## Navigation Notes

- **Home page shows categories** (e.g. "Main dishes"), NOT products directly
- Must click a category first to see products
- Use `page.getByText('Main dishes')` or the first category card
- After category click, wait: `await page.waitForSelector('[data-testid="product-item"]')`
- On newer builds with multi-venue groups: a venue picker modal may appear
  before the menu — handle it via `restaurant-option-<TABLET_ID>` if visible

---

## Known Missing / Unreliable Selectors

| Element | Problem | Workaround |
|---------|---------|------------|
| Checkout "Place Order" button | No stable testid | `page.getByRole('button', { name: /place order/i })` |
| Cart icon / badge | Theme-dependent class | `[aria-label*="cart"]` |
| Order type toggle | Text-based | `page.getByText('Delivery')` / `page.getByText('Pickup')` |
| Address input field | Google-injected | `page.locator('input[placeholder*="address" i]').first()` |
| Submit Order button on checkout | Same testid as floating cart | `[data-testid="cart-button"]` filtered by `/order/i` |

---

## Mobile vs Desktop Differences

- **Cart drawer.** Desktop: floating cart icon. Mobile: full cart-review
  page first, with an extra "Order" button before order-type selection.
- **Checkout flow.** Desktop: order-type modal opens directly. Mobile:
  needs an additional `cart-button` filtered by `/order/i` tap to reach
  order-type buttons (see flow §6 in `eshop-flows.md`).
- **Comment input.** Desktop only. Mobile checkout hides it. Always
  wrap comment fill in `if await comment.isVisible()`.
- **Standard mobile viewport for QA:** 390×844 (iPhone 14 Pro size).
- **Standard desktop viewport:** 1366×900.
