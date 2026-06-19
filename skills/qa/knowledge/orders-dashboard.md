# orders-dashboard (KDS) — confirmed facts & selectors

The third QA surface: **orders-dashboard** = DServe's web KDS (Kitchen
Display System). React + Vite + TypeScript. Repo
`MaistoMyletojai/orders-dashboard`, default branch `main`.

## A `KDS` ticket = the orders-dashboard SYSTEM (front + back)
A `KDS` label is NOT backend-only. The orders-dashboard is the user-facing
KDS, and its backend is **`KdsController`** at
`Dserve.SelfServiceApi/Controllers/KdsController.cs` — routes under
**`api/kds/*`** (`SelfServiceApiRoutes.Kds`, base `api/kds`):
`users/authenticate`, `users/profile`, `locations`,
`orders/active/{locationId}`, `orders/kitchen/{locationId}`,
`orders/{id}/markReady|markConfirmed|markPaid|markFinished|reprint|undo`,
`orders/createBase`, `devices/pair|heartbeat|config`, …

Route by the PR's repo:
- PR in **orders-dashboard** → `orders-ui` (drive the dashboard; it consumes
  `api/kds/*` via `$QA_ORDERS_API_URL`).
- PR in **dserve-backend** touching `KdsController` → `api` tier (xUnit on the
  `api/kds/*` endpoints) **and** verify the consuming dashboard UI
  (cross-system; or code-evidence on propagation if the backend change isn't
  deployed to what the dashboard talks to).
Either way the dashboard is the surface the operator sees — don't stop at the
endpoint.

> This file is a STARTER — append confirmed selectors/gotchas as you learn
> them (Edit tool, append-only), same discipline as the other knowledge files.

## How it runs
- Stack: Vite 4 + React 18 + react-router-dom 6 + MUI + redux/rematch
  (`@rematch/persist`) + Axios. Epson **ePOS** printer integration
  (`src/utilities/epos2.js`) — physical printing is NOT driveable in QA.
- Dev server: `npm run dev` → Vite, **port 3000** (`vite.config.ts`
  `server.port: 3000`). The skill's `orders-tier.sh` runs it on
  `$QA_ORDERS_PORT` (default 3000).
- API target: `VITE_APP_API_URL` (Axios `baseURL`) = the **KdsController
  root `api/kds`** (e.g. `https://ss-dev.dserve.app/api/kds`). The dashboard
  calls routes RELATIVE to this (`/users/authenticate`, `/orders/active/...`),
  so the base MUST include `/api/kds` — a plain `/api` base 404s login. The
  runner sets it from `$QA_ORDERS_API_URL`.
- `node_modules` must be installed in the worktree (`npm install`).

## Auth (login — NOT tabletToken)
- Login page `/login` (`src/pages/Login/index.tsx`), MUI form:
  - email: `input[name="email"]` (type=email, placeholder "Enter email address")
  - password: `input[name="password"]` (type=password)
  - submit: `button[type="submit"]`
- `login()` → `POST /users/authenticate` `{email,password}` → `{token}`
  (`src/models/authentication.ts`). Token persisted to **localStorage** via
  redux-persist → Playwright `storageState()` captures the session.
- On success the app navigates to **`/:locationId/orders`**. Authed views are
  under `ProtectedRoutes`.
- Use `templates/orders-login.ts.tmpl` to log in + save `storageState`
  (the runner does this automatically). Creds: `QA_ORDERS_EMAIL` /
  `QA_ORDERS_PASSWORD` (a KDS/venue self-service user).

## Routes
- `/login` — login
- `/:locationId/orders` — main orders board (post-login landing)

## Gotchas (append as discovered)
- Physical receipt/printer output (ePOS) can't be verified in QA → those AC
  are `code-evidence` / `manual` (printer is a real device).
- It's a different login + token than the Blazor Admin (`/users/authenticate`,
  not the Admin login form). Don't reuse `admin-state.json` here.
