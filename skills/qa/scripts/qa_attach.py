#!/usr/bin/env python3
"""qa_attach.py — attach QA evidence to a Trello card (Trello-only, no PR).

Publishes a finished QA run to its Trello card:
  • posts qa-trello-summary.md as a comment (unless --no-comment)
  • attaches qa-report.md as a file (QA-Report-<ticket>.md)
  • attaches every screenshot in screenshots/*.png

Guard rail (the reason this is its own step): before attaching anything it
SCANS the card for EXISTING QA evidence — prior QA report attachments, prior
QA screenshots, or prior QA verdict comments. If any are found it does NOT
attach; it lists what is already there and exits 2 ("needs confirmation").
Re-run with --confirm to add another round of evidence anyway. This stops
re-runs from silently piling duplicate reports onto the card.

It deliberately ignores the card's OWN design/spec images (e.g. image.png)
— only attachments matching QA naming (QA-Report*, ac-N-*, eshop-ac-N-*,
cross-system-*) and comments carrying a QA verdict marker count as "existing
QA evidence".

Usage:
  python3 qa_attach.py <ticket> [--card <id>] [--out <dir>]
                       [--confirm] [--no-comment] [--report-only]
Exit codes:
  0 — attached successfully (or nothing to attach)
  2 — existing QA evidence found and --confirm not given (caller should ask)
  1 — error (no output dir, no card id, etc.)
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
TRELLO_SH = SKILL_ROOT / "tools" / "trello.sh"

VERDICT_TOKENS = ("QA_APPROVED_WITH_GATES", "QA_APPROVED",
                  "QA_REJECTED", "QA_NEEDS_HUMAN")

# Attachment names this skill produces (so we don't mistake the ticket's own
# design screenshots — typically image.png — for prior QA evidence).
_QA_ATTACH_RE = re.compile(
    r"^(qa-report|qa-trello-summary)|^(eshop-)?ac-\d+[-.]|^cross-system",
    re.IGNORECASE,
)


def _env(name: str, default: str = "") -> str:
    import os
    v = os.environ.get(name, "").strip()
    return v if v else default


def log(m: str) -> None:
    print(m, file=sys.stderr, flush=True)


def sh(cmd: list[str]):
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def _is_qa_attachment(name: str) -> bool:
    return bool(_QA_ATTACH_RE.search((name or "").strip()))


def _is_qa_comment(text: str) -> bool:
    t = text or ""
    return ("🧪" in t) or ("QA #" in t) or any(tok in t for tok in VERDICT_TOKENS)


def existing_qa_evidence(card_id: str) -> dict:
    """Return {attachments: [...], comments: [{date,excerpt}]} of prior QA."""
    out = {"attachments": [], "comments": []}
    a = sh([str(TRELLO_SH), "attachments", card_id])
    if a.returncode == 0 and a.stdout.strip():
        try:
            for att in json.loads(a.stdout):
                if _is_qa_attachment(att.get("name", "")):
                    out["attachments"].append(att.get("name"))
        except Exception:
            pass
    c = sh([str(TRELLO_SH), "comments", card_id])
    if c.returncode == 0 and c.stdout.strip():
        try:
            for act in json.loads(c.stdout):
                text = (act.get("data") or {}).get("text") or ""
                if _is_qa_comment(text):
                    out["comments"].append({
                        "date": act.get("date"),
                        "excerpt": text.strip().splitlines()[0][:80] if text.strip() else "",
                    })
        except Exception:
            pass
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("ticket")
    ap.add_argument("--card", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--confirm", action="store_true",
                    help="attach even if the card already has QA evidence")
    ap.add_argument("--no-comment", action="store_true",
                    help="attach files only; don't post the summary comment")
    ap.add_argument("--report-only", action="store_true",
                    help="attach the report only; skip screenshots")
    args = ap.parse_args()

    digits = re.sub(r"\D", "", args.ticket) or args.ticket
    data_root = Path(_env("QA_DATA_ROOT", str(Path.home() / "dserve-qa-skill-data")))
    qa_dir = (Path(args.out) if args.out
              else Path(_env("QA_OUT_DIR")) if _env("QA_OUT_DIR")
              else data_root / "runs" / digits)
    if not qa_dir.exists():
        log(f"✗ output dir not found: {qa_dir}")
        sys.exit(1)

    # Resolve card id.
    card_id = args.card
    tj = qa_dir / "qa-ticket.json"
    if not card_id and tj.exists():
        try:
            card_id = json.loads(tj.read_text()).get("id")
        except Exception:
            pass
    if not card_id:
        log("✗ no card id (pass --card or ensure qa-ticket.json exists)")
        sys.exit(1)

    # Gather local evidence.
    report = qa_dir / "qa-report.md"
    summary = qa_dir / "qa-trello-summary.md"
    shots = sorted((qa_dir / "screenshots").glob("*.png")) if (qa_dir / "screenshots").exists() else []
    if args.report_only:
        shots = []

    # ── Guard: is there already QA evidence on the card? ──
    existing = existing_qa_evidence(card_id)
    has_existing = bool(existing["attachments"] or existing["comments"])
    if has_existing and not args.confirm:
        log(f"⚠ Card {card_id} ALREADY has QA evidence — NOT attaching.")
        if existing["attachments"]:
            log("  existing QA attachments:")
            for n in existing["attachments"]:
                log(f"    • {n}")
        if existing["comments"]:
            log("  existing QA comments:")
            for c in existing["comments"]:
                log(f"    • [{c['date']}] {c['excerpt']}")
        log("  → confirm with the user, then re-run with --confirm to add another round.")
        print(json.dumps({
            "status": "needs_confirmation",
            "card_id": card_id,
            "existing": existing,
            "would_attach": {
                "report": report.name if report.exists() else None,
                "screenshots": [p.name for p in shots],
                "comment": (not args.no_comment) and summary.exists(),
            },
        }, indent=2))
        sys.exit(2)

    # ── Attach ──
    posted: list[str] = []
    if not args.no_comment and summary.exists() and summary.read_text().strip():
        r = sh([str(TRELLO_SH), "comment", card_id, summary.read_text()[:16000]])
        posted.append("✓ comment" if r.returncode == 0 else "✗ comment")
    if report.exists() and report.read_text().strip():
        r = sh([str(TRELLO_SH), "attach", card_id, str(report), f"QA-Report-{digits}.md"])
        posted.append("✓ report" if r.returncode == 0 else "✗ report")
    attached = 0
    for p in shots:
        try:
            sz = p.stat().st_size
        except OSError:
            continue
        if sz == 0 or sz > 10 * 1024 * 1024:
            continue
        if sh([str(TRELLO_SH), "attach", card_id, str(p), p.name]).returncode == 0:
            attached += 1
    if attached:
        posted.append(f"📎 {attached} screenshot(s)")

    log("attached: " + (" · ".join(posted) if posted else "(nothing)"))
    print(json.dumps({"status": "attached", "card_id": card_id,
                      "added_after_existing": has_existing, "posted": posted}, indent=2))


if __name__ == "__main__":
    main()
