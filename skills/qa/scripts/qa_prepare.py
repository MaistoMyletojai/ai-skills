#!/usr/bin/env python3
"""qa_prepare.py — deterministic QA setup for the dserve-qa-runner skill.

Faithful port of the dserve-qa-rig pipeline's setup phase (pipeline.py
steps 0-4 + resolve_pr_for_ticket + dispatch_qa_blocking + the label
helpers from helpers.py). The scheduler/queue/Telegram/launchd layers are
intentionally NOT carried over — this script does only the testing-setup
work the agent needs before it starts classifying acceptance criteria.

What it does, given a Trello card reference (short id / URL / fragment):

  1. Resolves the card via tools/trello.sh  → full card payload
  2. Resolves the PR across BOTH repos (dserve-backend, self-service-web)
     via `gh pr list` — OPEN first, else most-recent merged/closed
  3. eshop-master fallback when there is no PR but an eshop label
  4. Picks the matching QA worktree and verifies it is a usable git repo
  5. Checks out the head ref (detached) — fetch head+base, reset, clean
  6. Captures the actual head SHA
  7. Writes the agent inputs: qa-ticket.json, qa-pr.json, qa-diff.patch
     (into both $QA_OUT_DIR and /tmp — the playbook reads /tmp)
  8. Prints a JSON summary to stdout for the skill to consume

It NEVER runs tests, posts to Trello/GitHub, or moves cards — those are
separate steps (the agent tests; qa_post.py posts).

Usage:
  python3 qa_prepare.py <card-ref>
Env (see config/qa-skill.env.example for the full list + defaults):
  MAIN_REPO_DIR MAIN_REPO_QA WEB_REPO_DIR WEB_REPO_QA
  MAIN_BASE_BRANCH WEB_BASE_BRANCH
  QA_ADMIN_EMAIL QA_ADMIN_PASSWORD QA_DATA_ROOT
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
TRELLO_SH = SKILL_ROOT / "tools" / "trello.sh"

# Verdicts the agent may emit (kept here so qa_post.py and the skill agree).
VALID_VERDICTS = ("QA_APPROVED", "QA_APPROVED_WITH_GATES",
                  "QA_REJECTED", "QA_NEEDS_HUMAN")

# Label fuzzy-match keywords — ported verbatim from config.py.
ESHOP_LABEL_KEYWORDS = ("eshop", "webshop", "qr")
KDS_LABEL_KEYWORDS = ("kds", "ordersdashboard")


# ───────── config (mirrors qa_rig/config.py _env semantics) ─────────
def _env(name: str, default: str = "") -> str:
    """Get an env var, treating an empty/whitespace value as unset.

    Critical for path-typed values: os.environ.get(name, default) returns
    '' for `KEY=` in an env file, and Path('') silently becomes the cwd.
    """
    val = os.environ.get(name, "").strip()
    return val if val else default


HOME = Path.home()
DATA_ROOT = Path(_env("QA_DATA_ROOT", str(HOME / "dserve-qa-skill-data")))
RUNS_DIR = DATA_ROOT / "runs"

MAIN_REPO_DIR = Path(_env("MAIN_REPO_DIR", str(HOME / "Documents/GitHub/dserve-backend")))
MAIN_REPO_QA = Path(_env("MAIN_REPO_QA", str(HOME / "Documents/GitHub/dserve-backend-qa")))
WEB_REPO_DIR = Path(_env("WEB_REPO_DIR", str(HOME / "Documents/GitHub/self-service-web")))
WEB_REPO_QA = Path(_env("WEB_REPO_QA", str(HOME / "Documents/GitHub/self-service-web-qa")))
ORDERS_REPO_DIR = Path(_env("ORDERS_REPO_DIR", str(HOME / "Documents/GitHub/orders-dashboard")))
ORDERS_REPO_QA = Path(_env("ORDERS_REPO_QA", str(HOME / "Documents/GitHub/orders-dashboard-qa")))

MAIN_BASE_BRANCH = _env("MAIN_BASE_BRANCH", "master")
WEB_BASE_BRANCH = _env("WEB_BASE_BRANCH", "main")
ORDERS_BASE_BRANCH = _env("ORDERS_BASE_BRANCH", "main")

QA_ADMIN_EMAIL = _env("QA_ADMIN_EMAIL", "")
QA_ADMIN_PASSWORD = _env("QA_ADMIN_PASSWORD", "")
TRELLO_BOARD_ID = _env("TRELLO_BOARD_ID", "")

# Remote mode (no local repos): GitHub slugs + deployed dev-server URLs.
MAIN_REPO_SLUG = _env("MAIN_REPO_SLUG", "MaistoMyletojai/dserve-backend")
WEB_REPO_SLUG = _env("WEB_REPO_SLUG", "MaistoMyletojai/self-service-web")
ORDERS_REPO_SLUG = _env("ORDERS_REPO_SLUG", "MaistoMyletojai/orders-dashboard")
QA_ADMIN_DEV_URL = _env("QA_ADMIN_DEV_URL", "")
QA_ESHOP_DEV_URL = _env("QA_ESHOP_DEV_URL", "https://ss-dev.dserve.app")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def die(msg: str, summary: dict) -> None:
    """Emit a terminal summary (so the skill can react) and exit non-zero."""
    summary["ok"] = False
    summary["error"] = msg
    log(f"✗ {msg}")
    print(json.dumps(summary, indent=2))
    sys.exit(1)


# ───────── shell ─────────
def sh(cmd: list[str], cwd: Path | None = None, check: bool = True):
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None,
                          capture_output=True, text=True, check=check)


# ───────── trello ─────────
def trello_resolve(ref: str) -> dict:
    out = sh([str(TRELLO_SH), "resolve", ref]).stdout
    data = json.loads(out)
    if "error" in data:
        raise ValueError(data["error"])
    return data


def trello_board_cards() -> list[dict]:
    out = sh([str(TRELLO_SH), "board_cards", TRELLO_BOARD_ID]).stdout
    return json.loads(out)


def resolve_card(ref: str) -> dict:
    """Resolve a card reference to its full payload.

    For a purely numeric ref (a ticket #NNNN) match the board card's
    `idShort` EXACTLY — Trello's free-text search is fuzzy and will happily
    return a neighbouring card (observed: query '4941' → card #4942). Only
    fall back to the fuzzy `trello.sh resolve` for non-numeric refs (URLs,
    title fragments) or when the number isn't found on the board.
    """
    r = ref.strip()
    if re.fullmatch(r"\d+", r) and TRELLO_BOARD_ID:
        try:
            cards = trello_board_cards()
        except Exception:
            cards = None
        if cards:
            want = int(r)
            exact = [c for c in cards if c.get("idShort") == want]
            if len(exact) == 1:
                return exact[0]
            if len(exact) > 1:
                raise ValueError(f"#{want} matches {len(exact)} cards on the board")
            log(f"  #{want} not found by idShort — falling back to fuzzy search")
    return trello_resolve(ref)


# ───────── label helpers (ported from helpers.py) ─────────
def _normalize_label(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def label_names(card: dict) -> list[str]:
    return [(lab.get("name") or "").strip()
            for lab in (card.get("labels") or [])
            if (lab.get("name") or "").strip()]


def has_eshop_label(card: dict) -> bool:
    for raw in label_names(card):
        n = _normalize_label(raw)
        if any(kw in n for kw in ESHOP_LABEL_KEYWORDS):
            return True
    return False


def has_kds_label(card: dict) -> bool:
    for raw in label_names(card):
        n = _normalize_label(raw)
        if any(kw in n for kw in KDS_LABEL_KEYWORDS):
            return True
    return False


# ───────── PR resolution (ported from pipeline.resolve_pr_for_ticket) ─────────
def resolve_pr_for_ticket(ticket: str) -> dict | None:
    """Dual-repo `gh pr list` lookup. Returns the first OPEN PR across
    either repo; falls back to the most recently updated merged/closed.
    The returned dict carries a synthetic `repo` field."""
    digits = re.sub(r"\D", "", ticket) or ticket
    repos = [("dserve-backend", MAIN_REPO_DIR), ("self-service-web", WEB_REPO_DIR),
             ("orders-dashboard", ORDERS_REPO_DIR)]
    all_prs: list[dict] = []
    for repo_name, cwd in repos:
        if not cwd.exists():
            log(f"  (repo {repo_name} not found at {cwd} — skipping)")
            continue
        for query in (f"[{digits}]", digits):
            try:
                proc = sh(["gh", "pr", "list", "--search", query,
                           "--state", "all", "--json",
                           "number,title,url,state,headRefName,baseRefName,"
                           "headRefOid,mergedAt,updatedAt"],
                          cwd=cwd, check=False)
            except Exception:
                continue
            out = (proc.stdout or "").strip()
            if not out:
                continue
            try:
                prs = json.loads(out)
            except Exception:
                continue
            for p in (prs or []):
                p["repo"] = repo_name
                all_prs.append(p)
            if prs:
                break
    if not all_prs:
        return None
    # OPEN first, then most-recently-updated (full ISO sorts lexically —
    # a small accuracy improvement over the rig's year-only sort key).
    all_prs.sort(key=lambda p: (p.get("state") != "OPEN",
                                _neg_iso(p.get("updatedAt"))))
    return all_prs[0]


def _neg_iso(ts: str | None) -> str:
    """Sort key that puts the most recent ISO timestamp first."""
    if not ts:
        return "0"
    # invert each char so later timestamps sort earlier
    return "".join(chr(0x10FFFF - ord(c)) if ord(c) < 0x10FFFF else c for c in ts)


def resolve_pr_remote(ticket: str) -> dict | None:
    """Dual-repo PR lookup straight from GitHub (no local clone needed) via
    `gh pr list --repo <slug>`. Returns the first OPEN PR, else most recent.
    Carries synthetic `repo` + `slug` fields."""
    digits = re.sub(r"\D", "", ticket) or ticket
    repos = [("dserve-backend", MAIN_REPO_SLUG), ("self-service-web", WEB_REPO_SLUG),
             ("orders-dashboard", ORDERS_REPO_SLUG)]
    all_prs: list[dict] = []
    for repo_name, slug in repos:
        if not slug:
            continue
        for query in (f"[{digits}]", digits):
            proc = sh(["gh", "pr", "list", "--repo", slug, "--search", query,
                       "--state", "all", "--json",
                       "number,title,url,state,headRefName,baseRefName,"
                       "headRefOid,mergedAt,updatedAt"], check=False)
            out = (proc.stdout or "").strip()
            if not out:
                continue
            try:
                prs = json.loads(out)
            except Exception:
                continue
            for p in (prs or []):
                p["repo"] = repo_name
                p["slug"] = slug
                all_prs.append(p)
            if prs:
                break
    if not all_prs:
        return None
    all_prs.sort(key=lambda p: (p.get("state") != "OPEN", _neg_iso(p.get("updatedAt"))))
    return all_prs[0]


def _write_inputs(qa_dir, card, pr, diff: str) -> None:
    card_json = json.dumps(card, indent=2)
    pr_json = json.dumps(pr, indent=2)
    for base in (qa_dir, Path("/tmp")):
        (base / "qa-ticket.json").write_text(card_json)
        (base / "qa-pr.json").write_text(pr_json)
        (base / "qa-diff.patch").write_text(diff)


def _run_remote(card, ticket_id, qa_dir, ui_ready, summary) -> None:
    """Remote mode: resolve PR + diff from GitHub; UI runs vs the dev server.
    No worktree, no checkout, no local build."""
    summary["mode"] = "remote"
    summary["admin_dev_url"] = QA_ADMIN_DEV_URL or None
    summary["eshop_dev_url"] = QA_ESHOP_DEV_URL or None

    log("→ resolving PR via gh --repo (no local clone)")
    pr = resolve_pr_remote(ticket_id)
    if not pr:
        if has_eshop_label(card):
            log(f"  no PR; eshop label → verify dev eshop ({QA_ESHOP_DEV_URL}) on {WEB_BASE_BRANCH}")
            pr = {"repo": "self-service-web", "slug": WEB_REPO_SLUG,
                  "headRefName": WEB_BASE_BRANCH, "url": None, "state": "FALLBACK",
                  "title": f"(no PR — verifying dev eshop {WEB_BASE_BRANCH})"}
        elif has_kds_label(card):
            log(f"  no PR; KDS label → verify orders-dashboard on {ORDERS_BASE_BRANCH}")
            pr = {"repo": "orders-dashboard", "slug": ORDERS_REPO_SLUG,
                  "headRefName": ORDERS_BASE_BRANCH, "url": None, "state": "FALLBACK",
                  "title": f"(no PR — verifying KDS dashboard {ORDERS_BASE_BRANCH})"}
        else:
            summary["verdict_hint"] = "QA_NEEDS_HUMAN"
            die("no PR found and no eshop/KDS label — nothing to verify", summary)

    head_ref = pr.get("headRefName") or ""
    summary.update(pr_url=pr.get("url"), head_ref=head_ref, pr_state=pr.get("state"),
                   pr_number=pr.get("number"), repo=pr.get("repo"),
                   repo_slug=pr.get("slug"), base_branch=(
                       WEB_BASE_BRANCH if pr.get("repo") == "self-service-web"
                       else ORDERS_BASE_BRANCH if pr.get("repo") == "orders-dashboard"
                       else MAIN_BASE_BRANCH),
                   head_sha=(pr.get("headRefOid") or ""))
    log(f"  PR: {pr.get('url') or '(none — dev fallback)'}  state={pr.get('state')}  head={head_ref}")

    # Diff straight from GitHub (works for fork PRs; empty for the fallback).
    diff = ""
    if pr.get("number") and pr.get("slug"):
        d = sh(["gh", "pr", "diff", str(pr["number"]), "--repo", pr["slug"]], check=False)
        diff = d.stdout if d.returncode == 0 else ""
    _write_inputs(qa_dir, card, pr, diff)
    summary["diff_bytes"] = len(diff)
    summary["recon_hint"] = (f"read source via: scripts/gh_file.sh {pr.get('slug')} "
                             f"<path> {pr.get('headRefOid') or head_ref}")
    summary["ui_note"] = ("remote UI tier tests the DEPLOYED dev server — for an "
                          "open, undeployed PR it reflects the dev branch, not the PR")
    log("✓ remote prepare complete (no local checkout)")
    print(json.dumps(summary, indent=2))


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="QA setup for the dserve-qa-runner skill")
    ap.add_argument("card_ref", help="ticket #NNNN, full id, URL, or title fragment")
    ap.add_argument("--remote", action="store_true",
                    help="no local repos: resolve PR/diff from GitHub, test UI on the dev server")
    args = ap.parse_args()
    card_ref = args.card_ref
    summary: dict = {"ok": True, "card_ref": card_ref, "mode": "remote" if args.remote else "local"}

    # 1. Resolve the card (same in both modes — Trello is always remote).
    log(f"→ resolving Trello card {card_ref}")
    try:
        card = resolve_card(card_ref)
    except Exception as e:
        die(f"could not resolve Trello card '{card_ref}': {e}", summary)
    short = card.get("idShort") or card.get("shortLink") or card.get("id") or card_ref
    ticket_id = re.sub(r"\D", "", str(short)) or str(short)
    summary.update(ticket=ticket_id, card_id=card.get("id"),
                   card_title=card.get("name"),
                   labels=label_names(card))
    log(f"  ticket #{ticket_id} — {card.get('name')!r}  labels={label_names(card)}")

    qa_dir = RUNS_DIR / (re.sub(r"\D", "", ticket_id) or ticket_id.lower())
    qa_dir.mkdir(parents=True, exist_ok=True)
    summary["out_dir"] = str(qa_dir)

    # 0. UI tier preflight.
    ui_ready = bool(QA_ADMIN_EMAIL and QA_ADMIN_PASSWORD)
    summary["ui_tier_available"] = ui_ready
    if not ui_ready:
        log("⚠ QA_ADMIN_EMAIL / QA_ADMIN_PASSWORD missing — UI tier will be "
            "skipped (admin-ui AC must fall back to code-evidence)")

    # Branch: remote (GitHub + dev server) vs local (worktree checkout).
    if args.remote:
        return _run_remote(card, ticket_id, qa_dir, ui_ready, summary)

    # 1. Resolve PR.
    log("→ resolving PR via gh (dserve-backend + self-service-web + orders-dashboard)")
    pr = resolve_pr_for_ticket(ticket_id)
    if not pr:
        if has_eshop_label(card):
            log(f"  no PR; eshop label present → fallback to self-service-web@{WEB_BASE_BRANCH}")
            pr = {"repo": "self-service-web", "headRefName": WEB_BASE_BRANCH,
                  "url": None, "state": "FALLBACK",
                  "title": f"(no PR — verifying eshop {WEB_BASE_BRANCH})"}
        elif has_kds_label(card):
            log(f"  no PR; KDS label present → fallback to orders-dashboard@{ORDERS_BASE_BRANCH}")
            pr = {"repo": "orders-dashboard", "headRefName": ORDERS_BASE_BRANCH,
                  "url": None, "state": "FALLBACK",
                  "title": f"(no PR — verifying KDS dashboard {ORDERS_BASE_BRANCH})"}
        else:
            summary["verdict_hint"] = "QA_NEEDS_HUMAN"
            die("no PR found and no eshop/KDS label — cannot determine what to "
                "verify (rig would short-circuit to QA_NEEDS_HUMAN here)", summary)

    head_ref = pr.get("headRefName") or ""
    pr_url = pr.get("url")
    summary.update(pr_url=pr_url, head_ref=head_ref,
                   pr_state=pr.get("state"), pr_number=pr.get("number"))
    log(f"  PR: {pr_url or '(none — master-fallback)'}  state={pr.get('state')}  head={head_ref}")

    # 2. Pick the worktree.
    pr_repo = (pr.get("repo") or "dserve-backend").lower()
    if pr_repo == "self-service-web":
        wt_dir, wt_base = WEB_REPO_QA, WEB_BASE_BRANCH
    elif pr_repo == "orders-dashboard":
        wt_dir, wt_base = ORDERS_REPO_QA, ORDERS_BASE_BRANCH
    else:
        wt_dir, wt_base = MAIN_REPO_QA, MAIN_BASE_BRANCH
    summary.update(repo=pr_repo, worktree=str(wt_dir), base_branch=wt_base)

    if not wt_dir.exists() or not (wt_dir / ".git").exists():
        die(f"QA worktree missing: {wt_dir} — create it with "
            f"`git -C <source-repo> worktree add {wt_dir} {wt_base}` "
            f"(or point *_REPO_QA at an existing checkout)", summary)

    # .git in a worktree is a FILE with an absolute pointer; if the repo was
    # relocated (or macOS TCC blocks the path) every git op fails cryptically.
    probe = sh(["git", "rev-parse", "--is-inside-work-tree"], cwd=wt_dir, check=False)
    if probe.returncode != 0:
        err = (probe.stderr or "").strip()[:200]
        die(f"worktree at {wt_dir} is not a usable git repo: {err}. "
            f"Likely a dangling worktree link or a Full-Disk-Access/TCC block. "
            f"Fix: `git -C <source-repo> worktree repair`; keep paths under ~/ "
            f"or grant Full Disk Access to your terminal.", summary)

    # 3. Checkout head ref (detached).
    log(f"→ checking out {pr_repo}@{head_ref} (detached) in {wt_dir}")
    sh(["git", "fetch", "origin", head_ref], cwd=wt_dir, check=False)
    sh(["git", "fetch", "origin", wt_base], cwd=wt_dir, check=False)
    sh(["git", "reset", "--hard"], cwd=wt_dir, check=False)
    sh(["git", "clean", "-fd"], cwd=wt_dir, check=False)
    co = sh(["git", "checkout", "--detach", f"origin/{head_ref}"], cwd=wt_dir, check=False)
    if co.returncode != 0:
        die(f"git checkout failed: {(co.stderr or '').strip()[:200]}", summary)

    try:
        head_sha = sh(["git", "rev-parse", "HEAD"], cwd=wt_dir).stdout.strip()
    except Exception:
        head_sha = ""
    summary["head_sha"] = head_sha
    log(f"  head SHA: {head_sha or '(unknown)'}")

    # 4. Write inputs (both $QA_OUT_DIR and /tmp — playbook reads /tmp).
    log("→ writing inputs (qa-ticket.json, qa-pr.json, qa-diff.patch)")
    card_json = json.dumps(card, indent=2)
    pr_json = json.dumps(pr, indent=2)
    try:
        diff = sh(["git", "diff", f"origin/{wt_base}...HEAD"], cwd=wt_dir).stdout
    except Exception:
        diff = ""
    for base in (qa_dir, Path("/tmp")):
        (base / "qa-ticket.json").write_text(card_json)
        (base / "qa-pr.json").write_text(pr_json)
        (base / "qa-diff.patch").write_text(diff)
    summary["diff_bytes"] = len(diff)

    log("✓ prepare complete")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
