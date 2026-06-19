#!/usr/bin/env bash
# install-playwright.sh — one-time setup of the qa-agent's Playwright runtime.
#
# Creates ~/dserve-qa-skill-data/playwright-runtime/ with:
#   - package.json (minimal — just @playwright/test)
#   - node_modules with Playwright installed
#   - playwright.config.ts pre-configured for headless Chromium against
#     localhost:$QA_ADMIN_PORT, with screenshot+video on failure
#   - Chromium browser installed via `playwright install chromium`
#
# Idempotent — safe to re-run.

set -euo pipefail

RUNTIME_DIR="${QA_PLAYWRIGHT_RUNTIME:-$HOME/dserve-qa-skill-data/playwright-runtime}"
mkdir -p "$RUNTIME_DIR"
cd "$RUNTIME_DIR"

if [ ! -f package.json ]; then
  cat > package.json <<'JSON'
{
  "name": "qa-agent-playwright-runtime",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "playwright test"
  },
  "devDependencies": {
    "@playwright/test": "^1.45.0",
    "typescript": "^5.4.0"
  }
}
JSON
fi

# Regenerate config every run so testDir change lands on existing installs.
cat > playwright.config.ts <<'TS'
import { defineConfig, devices } from "@playwright/test";

// testDir is env-driven so ui-tier.sh can point Playwright at any
// per-ticket directory (typically $QA_OUT_DIR/playwright/) without
// having to copy specs into this runtime folder. Falls back to "." for
// the auth-helper spec which lives next to this config.
const TEST_DIR = process.env.PLAYWRIGHT_TEST_DIR || ".";

export default defineConfig({
  testDir: TEST_DIR,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  retries: 0,
  reporter: [["json", { outputFile: "test-results.json" }]],
  use: {
    headless: true,
    actionTimeout: 10_000,
    navigationTimeout: 30_000,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
    viewport: { width: 1366, height: 900 },
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
TS

if [ ! -f tsconfig.json ]; then
  cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "esModuleInterop": true,
    "strict": false,
    "skipLibCheck": true
  }
}
JSON
fi

echo "→ npm install"
npm install --silent

echo "→ playwright install chromium (with deps)"
npx playwright install chromium --with-deps

echo "✓ qa-agent Playwright runtime ready at $RUNTIME_DIR"
