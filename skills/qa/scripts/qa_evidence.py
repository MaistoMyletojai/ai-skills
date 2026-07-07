#!/usr/bin/env python3
"""qa_evidence.py — shared UI-screenshot-evidence gate for the QA skill.

Enforces the hard rule: **any ticket that changes UI or affects UI
functionality MUST ship a genuine QA-captured screenshot as evidence.** The
ticket's own design / mockup / Figma images do NOT count — evidence must be a
screenshot the QA run actually produced (a Playwright `shotWithHighlight`
capture, or an equivalent live capture the agent recorded).

Both `qa_attach.py` and `qa_post.py` import this and refuse to publish a
UI-affecting run that has no genuine capture (overridable only with an
explicit `--allow-no-shots`, which must be a loud, documented exception).

Naming convention (authoritative):
  • Genuine QA captures  → `ac-<n>-*`, `eshop-ac-<n>-*`, `orders-ac-<n>-*`,
                            `cross-system-*`  (produced by the tier runners)
  • Reference / design   → any name containing design|reference|ref-|mockup|
                            figma|ticket|spec-image  → NEVER counted as
                            evidence (attached only as context)
"""
from __future__ import annotations

import json
import re
from pathlib import Path

# Names a tier runner produces for a real, highlighted capture.
_CAPTURE_RE = re.compile(
    r"^(eshop-|orders-)?ac-\d+[-.].*\.(png|jpg|jpeg)$|^cross-system.*\.(png|jpg|jpeg)$",
    re.IGNORECASE,
)

# Substrings that mark an image as a design/reference copy (NOT evidence),
# even if it otherwise matches the capture pattern.
_REFERENCE_MARKERS = ("design", "reference", "ref-", "mockup",
                      "figma", "ticket", "spec-image", "prefix")

# AC tiers / surfaces that mean "this ticket touches UI".
_UI_TIERS = {"admin-ui", "eshop-ui", "orders-ui", "cross-system"}
_UI_SURFACES = {"admin-ui", "eshop-ui", "orders-ui", "eshop", "admin", "orders"}

# evidence_source values that are NOT the real running application. Screenshots
# from these are staged/synthetic and must never count as QA evidence.
_FORBIDDEN_SOURCES = {"harness", "isolated", "mock", "mocked", "staged",
                      "component", "storybook", "synthetic"}


def _is_reference(name: str) -> bool:
    n = (name or "").lower()
    return any(m in n for m in _REFERENCE_MARKERS)


def genuine_shots(qa_dir: Path) -> list[Path]:
    """Screenshots that count as real QA evidence (captures, not design refs)."""
    shot_dir = Path(qa_dir) / "screenshots"
    if not shot_dir.is_dir():
        return []
    out: list[Path] = []
    for p in sorted(shot_dir.iterdir()):
        if not p.is_file():
            continue
        if _is_reference(p.name):
            continue
        if _CAPTURE_RE.search(p.name):
            try:
                if p.stat().st_size > 0:
                    out.append(p)
            except OSError:
                pass
    return out


def reference_shots(qa_dir: Path) -> list[Path]:
    """Design / reference images present but NOT counted as evidence."""
    shot_dir = Path(qa_dir) / "screenshots"
    if not shot_dir.is_dir():
        return []
    return [p for p in sorted(shot_dir.iterdir())
            if p.is_file() and _is_reference(p.name)]


def ui_change_expected(qa_dir: Path) -> bool:
    """Does this run touch UI? Read telemetry; fall back to AC tiers/surface."""
    tel = Path(qa_dir) / "qa-telemetry.json"
    if not tel.exists():
        return False
    try:
        data = json.loads(tel.read_text())
    except Exception:
        return False
    # Explicit signal wins.
    if isinstance(data.get("ui_change"), bool):
        return data["ui_change"]
    if str(data.get("surface", "")).lower() in _UI_SURFACES:
        return True
    for ac in data.get("acceptance_criteria", []) or []:
        if str(ac.get("tier", "")).lower() in _UI_TIERS:
            return True
    return False


def _evidence_source(qa_dir: Path) -> str:
    """Read qa-telemetry.json `evidence_source` (default 'real-app' if absent)."""
    tel = Path(qa_dir) / "qa-telemetry.json"
    if not tel.exists():
        return "real-app"
    try:
        return str(json.loads(tel.read_text()).get("evidence_source", "real-app")).lower().strip()
    except Exception:
        return "real-app"


def check_ui_evidence(qa_dir: Path) -> tuple[bool, str, dict]:
    """Gate result: (ok, reason, details).

    ok == False  → this is a UI-affecting run with NO genuine screenshot.
    Callers must refuse to publish unless the operator passes --allow-no-shots.
    """
    qa_dir = Path(qa_dir)
    ui = ui_change_expected(qa_dir)
    shots = genuine_shots(qa_dir)
    refs = reference_shots(qa_dir)
    source = _evidence_source(qa_dir)
    details = {
        "ui_change_expected": ui,
        "genuine_shots": [p.name for p in shots],
        "reference_only": [p.name for p in refs],
        "evidence_source": source,
    }
    # Staged/synthetic evidence (isolated harness, mocked store, fabricated
    # props) is never acceptable — it doesn't exercise the real running app.
    if ui and source in _FORBIDDEN_SOURCES:
        reason = (
            f"Evidence source is '{source}' — staged/synthetic renders (isolated "
            "harness, mocked redux store, fabricated props) are NOT QA evidence. "
            "Capture the ACTUAL running application driven through its real flow "
            "against the real backend. If the state can't be reached on QA infra, "
            "set the verdict to QA_NEEDS_HUMAN and say what's needed — do not "
            "synthesize."
        )
        return False, reason, details
    if ui and not shots:
        reason = (
            "UI-affecting ticket has NO genuine QA screenshot. "
            "Design/reference images do not count"
            + (f" (found reference-only: {', '.join(p.name for p in refs)})" if refs else "")
            + ". Capture a real screenshot of the changed UI (run the eshop/"
            "admin/orders tier with a shotWithHighlight capture; for gated or "
            "hard-to-reach UI, force the state via API mock / redux injection / "
            "isolated render). If truly un-capturable, re-run with "
            "--allow-no-shots AND set the verdict to QA_NEEDS_HUMAN."
        )
        return False, reason, details
    return True, "ok", details
