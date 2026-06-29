#!/usr/bin/env python3
"""qa_post.py — publish QA results for the dserve-qa-runner skill.

Faithful port of the dserve-qa-rig pipeline's posting phase (pipeline.py
steps 6-10: verdict resolution, report fallback chain, Trello comment,
GitHub PR comment, screenshot attachment, verdict-based card move). Run
this AFTER the agent has written its outputs into $QA_OUT_DIR.

This is the only part of the skill with external side effects, so it is
optional and gated:
  • `--dry-run` prints exactly what WOULD be posted and touches nothing.
  • Trello posting is skipped (with a warning) if trello.sh can't auth.
  • GitHub posting is skipped if there is no PR URL or `gh` isn't ready.

Reads from $QA_OUT_DIR (defaults to <data-root>/runs/<ticket>):
  qa-report.md          → GitHub PR comment (full report)
  qa-summary-dev.md     → Trello comment #1 — DEVELOPER (technical) summary
  qa-summary-qa.md      → Trello comment #2 — QA-PERSON (UI/UX) summary
  qa-trello-summary.md  → Trello card comment (LEGACY fallback, single summary)
  qa-telemetry.json     → verdict + pr_url (when not passed on the CLI)
  screenshots/*.png     → attached to the Trello card
  playwright-artifacts/**/*.png → failure shots, attached too

Trello posting (in priority order):
  1. If qa-summary-dev.md and/or qa-summary-qa.md exist & are non-empty,
     post each present one as its OWN Trello comment (dev first, then qa),
     each with an audience header line. This is the preferred path.
  2. If NEITHER of the two split summaries exists, fall back to the legacy
     single comment built from qa-trello-summary.md → qa-report.md → a
     minimal synthesized body (the original behaviour, unchanged).

Usage:
  python3 qa_post.py <ticket> [--verdict QA_APPROVED] [--card <id>]
                              [--pr <url>] [--out <dir>] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
TRELLO_SH = SKILL_ROOT / "tools" / "trello.sh"

VALID_VERDICTS = ("QA_APPROVED", "QA_APPROVED_WITH_GATES",
                  "QA_REJECTED", "QA_NEEDS_HUMAN")
TRELLO_MAX = 16000

VERDICT_EMOJI = {
    "QA_APPROVED": "✅",
    "QA_APPROVED_WITH_GATES": "✅⚠",
    "QA_REJECTED": "❌",
    "QA_NEEDS_HUMAN": "⚠",
}


def _env(name: str, default: str = "") -> str:
    val = os.environ.get(name, "").strip()
    return val if val else default


HOME = Path.home()
DATA_ROOT = Path(_env("QA_DATA_ROOT", str(HOME / "dserve-qa-skill-data")))
RUNS_DIR = DATA_ROOT / "runs"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def sh(cmd: list[str], cwd: Path | None = None, check: bool = False):
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None,
                          capture_output=True, text=True, check=check)


# ───────── verdict-based card move (ported from _qa_trello_move) ─────────
def _move_target(verdict: str) -> str:
    if verdict == "QA_APPROVED":
        return (os.environ.get("TRELLO_LIST_READY_FOR_PROD")
                or os.environ.get("TRELLO_LIST_QA_APPROVED") or "")
    if verdict == "QA_APPROVED_WITH_GATES":
        return os.environ.get("TRELLO_LIST_QA_APPROVED") or ""
    if verdict == "QA_REJECTED":
        return (os.environ.get("TRELLO_LIST_QA_REJECTED")
                or os.environ.get("TRELLO_LIST_IN_PROGRESS") or "")
    return ""  # QA_NEEDS_HUMAN — leave the card where it is


def _min_trello_body(verdict: str, ticket: str, pr_url: str | None) -> str:
    emoji = VERDICT_EMOJI.get(verdict, "⚠")
    lines = [f"🧪 **QA #{ticket}**", "", f"**Verdict:** {emoji} {verdict}"]
    if pr_url:
        lines += ["", f"📋 Full report on GitHub: {pr_url}"]
    lines += ["", "_(Trello summary was empty — see GitHub PR for details.)_"]
    return "\n".join(lines)


def _read_report(qa_dir: Path, verdict: str, ticket: str) -> tuple[str, str]:
    """Report fallback chain (ported from pipeline.py step 7)."""
    report_path = qa_dir / "qa-report.md"
    if report_path.exists() and report_path.read_text().strip():
        return report_path.read_text(), "qa-report.md"
    skip = ("qa-report.md", "qa-trello-summary.md",
            "qa-summary-dev.md", "qa-summary-qa.md")
    other = [p for p in sorted(qa_dir.glob("*.md"))
             if p.name not in skip
             and p.is_file() and p.stat().st_size > 0]
    if other:
        return ("\n\n---\n\n".join(p.read_text() for p in other),
                "fallback-glob:" + ",".join(p.name for p in other))
    return (f"# QA Report — INCOMPLETE\n\nNo `qa-report.md` was written to "
            f"`{qa_dir}`. Verdict: {verdict}.\n", "stub")


def _truncate(body: str, pr_url: str | None) -> str:
    """Trim a comment body to Trello's limit, appending a PR pointer."""
    if len(body) <= TRELLO_MAX:
        return body
    cut = body[:TRELLO_MAX].rsplit("\n", 1)[0]
    if pr_url:
        cut += f"\n\n---\n*Truncated for Trello — full report on GitHub: {pr_url}*"
    return cut


def _two_summaries(qa_dir: Path) -> tuple[str | None, str | None]:
    """Load the two audience-split summaries written by the agent.

    Returns (dev_body, qa_body); each element is the file's text (str) when
    the file exists and is non-empty, otherwise None. When neither file is
    present the caller falls back to the legacy single-summary path.
    """
    def _load(name: str) -> str | None:
        p = qa_dir / name
        if p.exists():
            txt = p.read_text()
            if txt.strip():
                return txt
        return None

    return _load("qa-summary-dev.md"), _load("qa-summary-qa.md")


def _trello_body(qa_dir: Path, report_md: str, verdict: str,
                 ticket: str, pr_url: str | None) -> tuple[str, str]:
    """LEGACY single-comment Trello body selection + truncation.

    Used only when neither qa-summary-dev.md nor qa-summary-qa.md exists.
    (Ported from pipeline.py step 8.)
    """
    summary_path = qa_dir / "qa-trello-summary.md"
    if summary_path.exists() and summary_path.read_text().strip():
        body = summary_path.read_text()
        if len(body) > TRELLO_MAX:
            body = body[:TRELLO_MAX].rsplit("\n", 1)[0]
            if pr_url:
                body += f"\n\n---\n*Full report on GitHub: {pr_url}*"
        return body, "qa-trello-summary.md"
    if report_md.strip():
        if len(report_md) <= TRELLO_MAX:
            return report_md, "qa-report.md (full)"
        cut = report_md[:TRELLO_MAX].rsplit("\n", 1)[0]
        footer = ["", "---", "*Truncated for Trello's 16k comment limit.*"]
        if pr_url:
            footer.append(f"*Full report on GitHub: {pr_url}*")
        return cut + "\n".join(footer), "qa-report.md (truncated)"
    return _min_trello_body(verdict, ticket, pr_url), "min-synthesized"


def _collect_shots(qa_dir: Path) -> list[tuple[Path, str]]:
    shots: list[tuple[Path, str]] = []
    shot_dir = qa_dir / "screenshots"
    if shot_dir.exists():
        for p in sorted(shot_dir.glob("*.png")):
            shots.append((p, p.name))
    art = qa_dir / "playwright-artifacts"
    if art.exists():
        for p in sorted(art.glob("**/*.png")):
            shots.append((p, f"FAILED-{p.parent.name}-{p.name}"[:120]))
    # also pick up the eshop/cross-system artifact dirs
    for extra in ("eshop-artifacts", "cross-system-artifacts"):
        d = qa_dir / extra
        if d.exists():
            for p in sorted(d.glob("**/*.png")):
                shots.append((p, f"FAILED-{p.parent.name}-{p.name}"[:120]))
    return shots


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("ticket")
    ap.add_argument("--verdict", choices=VALID_VERDICTS, default=None)
    ap.add_argument("--card", default=None, help="Trello card id (default: read qa-ticket.json)")
    ap.add_argument("--pr", default=None, help="PR URL (default: read qa-telemetry.json / qa-pr.json)")
    ap.add_argument("--out", default=None, help="QA_OUT_DIR override")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    import re
    digits = re.sub(r"\D", "", args.ticket) or args.ticket
    qa_dir = Path(args.out) if args.out else (Path(_env("QA_OUT_DIR")) if _env("QA_OUT_DIR")
                                              else RUNS_DIR / digits)
    if not qa_dir.exists():
        log(f"✗ output dir not found: {qa_dir}")
        sys.exit(1)

    # ── resolve verdict ──
    verdict = args.verdict
    telemetry = qa_dir / "qa-telemetry.json"
    if not verdict and telemetry.exists():
        try:
            verdict = (json.loads(telemetry.read_text()).get("verdict") or "").strip() or None
        except Exception:
            pass
    if verdict not in VALID_VERDICTS:
        verdict = "QA_NEEDS_HUMAN"
        log(f"⚠ no valid verdict provided/found — defaulting to {verdict}")

    # ── resolve card id ──
    card_id = args.card
    pr_url = args.pr
    ticket_file = qa_dir / "qa-ticket.json"
    if ticket_file.exists():
        try:
            card = json.loads(ticket_file.read_text())
            card_id = card_id or card.get("id")
        except Exception:
            pass
    if not pr_url:
        for f, key in ((telemetry, "pr_url"), (qa_dir / "qa-pr.json", "url")):
            if f.exists():
                try:
                    pr_url = pr_url or (json.loads(f.read_text()).get(key) or None)
                except Exception:
                    pass

    report_md, rsrc = _read_report(qa_dir, verdict, digits)
    shots = _collect_shots(qa_dir)
    move_to = _move_target(verdict)

    # ── Trello body selection: two audience-split summaries, else legacy ──
    dev_body, qa_body = _two_summaries(qa_dir)
    # Build the (header, body, source-label) list of comments we will post.
    trello_comments: list[tuple[str, str]] = []  # (body, source-label)
    if dev_body is not None or qa_body is not None:
        if dev_body is not None:
            header = f"👨‍💻 **QA #{digits} — Developer summary**\n\n"
            trello_comments.append((_truncate(header + dev_body, pr_url),
                                    "qa-summary-dev.md"))
        if qa_body is not None:
            header = f"🧪 **QA #{digits} — QA / UX summary**\n\n"
            trello_comments.append((_truncate(header + qa_body, pr_url),
                                    "qa-summary-qa.md"))
    else:
        body, tsrc = _trello_body(qa_dir, report_md, verdict, digits, pr_url)
        trello_comments.append((body, tsrc))

    log(f"verdict={verdict}  card={card_id}  pr={pr_url}")
    log(f"report source={rsrc} ({len(report_md)} chars) · "
        f"{len(shots)} screenshot(s) · move→{move_to or '(stay)'}")
    log("trello comments (" + str(len(trello_comments)) + "):")
    for body, tsrc in trello_comments:
        log(f"  • {tsrc} ({len(body)} chars)")

    if args.dry_run:
        log("── DRY RUN — nothing posted ──")
        print(json.dumps({
            "dry_run": True, "verdict": verdict, "card_id": card_id,
            "pr_url": pr_url, "report_chars": len(report_md),
            "trello_comments": [
                {"source": tsrc, "chars": len(body)}
                for body, tsrc in trello_comments
            ],
            "screenshots": [n for _, n in shots],
            "would_move_to": move_to or None,
        }, indent=2))
        return

    posted: list[str] = []

    # 1. Trello comment(s) — one per audience summary (dev + qa), or one legacy.
    if card_id:
        for body, tsrc in trello_comments:
            r = sh([str(TRELLO_SH), "comment", card_id, body[:TRELLO_MAX]])
            if tsrc == "qa-summary-dev.md":
                label = "Trello(dev)"
            elif tsrc == "qa-summary-qa.md":
                label = "Trello(qa)"
            else:
                label = "Trello"
            posted.append(f"✓ {label}" if r.returncode == 0
                          else f"✗ {label} — {(r.stderr or '').strip()[:80]}")
    else:
        posted.append("✗ Trello — no card id")

    # 2. GitHub PR comment (full report — UNCHANGED).
    if pr_url:
        r = sh(["gh", "pr", "comment", pr_url, "--body", report_md])
        posted.append("✓ PR" if r.returncode == 0
                      else f"✗ PR — {(r.stderr or '').strip()[:80]}")
    else:
        posted.append("· PR skipped (no url)")

    # 3. Screenshots → Trello.
    if card_id and shots:
        attached = 0
        for path, name in shots:
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if size == 0 or size > 10 * 1024 * 1024:
                continue
            if sh([str(TRELLO_SH), "attach", card_id, str(path), name]).returncode == 0:
                attached += 1
        if attached:
            posted.append(f"📎 {attached} shot(s)")

    # 4. Move card by verdict.
    if card_id and move_to:
        r = sh([str(TRELLO_SH), "move", card_id, move_to])
        posted.append("➡ moved" if r.returncode == 0 else "✗ move")

    log("posted: " + " · ".join(posted))
    print(json.dumps({"verdict": verdict, "card_id": card_id, "pr_url": pr_url,
                      "posted": posted, "moved_to": move_to or None}, indent=2))


if __name__ == "__main__":
    main()
