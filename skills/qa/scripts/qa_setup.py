#!/usr/bin/env python3
"""qa_setup.py — first-run check / doctor for the dserve-qa-runner skill.

Run AFTER `source scripts/lib.sh` (so config + defaults are in the env).

It answers two questions the skill asks at Step 0:
  1. Is this a FIRST RUN? (no config file yet)
  2. Which variables / credentials / tools are MISSING?

It enumerates EVERY variable the whole skill flow touches — grouped, with
required-ness, whether it's a secret, where it comes from, and its current
status — then prints a human checklist (stderr) + a machine summary (stdout
JSON). Exit codes:
  0 — ready for at least a local OR remote run (core creds present)
  3 — first run or core requirements missing → the skill must ASK the user
      for the listed variables and write config/qa-skill.env before running

It does NOT collect secrets itself — the skill (the model) asks the user and
writes config/qa-skill.env / seeds Keychain. Use `--init` to scaffold an
empty config file from the example.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

SKILL_ROOT = Path(os.environ.get("QA_AGENT_ROOT", "")) or Path(__file__).resolve().parent.parent
TOOLS = SKILL_ROOT / "tools"


def _set(name: str) -> bool:
    return bool((os.environ.get(name) or "").strip())


def _run(cmd: list[str]) -> bool:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).returncode == 0
    except Exception:
        return False


def _trello_ok() -> bool:
    """Live probe: can trello.sh authenticate? (env creds or Keychain)."""
    try:
        p = subprocess.run([str(TOOLS / "trello.sh"), "me"],
                           capture_output=True, text=True, timeout=20)
        return p.returncode == 0 and '"id"' in (p.stdout or "")
    except Exception:
        return False


def _tablet_ok() -> bool:
    if _set("QA_TABLET_TOKEN"):
        return True
    return _run([str(TOOLS / "kc.sh"), "autodev_qa_tablet_token"])


def _dir_ok(name: str) -> bool:
    v = (os.environ.get(name) or "").strip()
    return bool(v) and Path(v).is_dir()


def _git_repo(name: str) -> bool:
    v = (os.environ.get(name) or "").strip()
    return bool(v) and (Path(v) / ".git").exists()


def _aspnet8() -> bool:
    try:
        out = subprocess.run(["dotnet", "--list-runtimes"], capture_output=True,
                             text=True, timeout=20).stdout
        return any(l.startswith("Microsoft.AspNetCore.App 8.") for l in out.splitlines())
    except Exception:
        return False


def _playwright_ok() -> bool:
    rt = (os.environ.get("QA_PLAYWRIGHT_RUNTIME") or "").strip()
    return bool(rt) and (Path(rt) / "node_modules" / "@playwright" / "test").is_dir()


def main() -> None:
    init = "--init" in sys.argv
    config_path = (os.environ.get("QA_SKILL_ENV_FILE", "").strip()
                   or str(SKILL_ROOT / "config" / "qa-skill.env"))
    example = SKILL_ROOT / "config" / "qa-skill.env.example"
    first_run = not Path(config_path).exists()

    secrets_path = str(SKILL_ROOT / "config" / ".secrets")
    secrets_example = SKILL_ROOT / "config" / ".secrets.example"
    if init:
        if first_run and example.exists():
            shutil.copyfile(example, config_path)
            print(f"scaffolded {config_path} from the example — fill it in.", file=sys.stderr)
        else:
            print(f"config already exists at {config_path} — not overwriting.", file=sys.stderr)
        if not Path(secrets_path).exists() and secrets_example.exists():
            shutil.copyfile(secrets_example, secrets_path)
            try:
                os.chmod(secrets_path, 0o600)
            except OSError:
                pass
            print(f"scaffolded {secrets_path} (chmod 600) — fill in the secrets, "
                  f"it is gitignored.", file=sys.stderr)
        else:
            print(f"secrets file already exists at {secrets_path} — not overwriting.", file=sys.stderr)
        return

    # ── Variable spec: every var the whole flow touches ──
    # need: all | ui | eshop | local | remote | optional
    groups = [
        ("Trello (required for every run)", [
            ("TRELLO_CREDENTIALS", "all", True,
             "THIRD-PARTY → config/.secrets: TRELLO_API_KEY + TRELLO_TOKEN "
             "(or Keychain autodev_qa_trello_key / autodev_qa_trello_token)",
             _trello_ok()),
            ("TRELLO_BOARD_ID", "all", False,
             "board id to resolve #NNNN card refs (trello.com → board → ?fields)",
             _set("TRELLO_BOARD_ID")),
        ]),
        ("GitHub (required — PR resolution)", [
            ("GITHUB_AUTH", "all", True,
             "`gh auth login` (the gh CLI). Optional fallback: GH_TOKEN env / "
             "Keychain autodev_qa_gh_token",
             _run(["gh", "auth", "status"])),
        ]),
        ("Admin UI tier (required to run admin-ui AC live)", [
            ("QA_ADMIN_EMAIL", "ui", False, "config/qa-skill.env: Blazor Admin login email (MasterAdmin QA user)", _set("QA_ADMIN_EMAIL")),
            ("QA_ADMIN_PASSWORD", "ui", True, "config/qa-skill.env: Blazor Admin login password (our system)", _set("QA_ADMIN_PASSWORD")),
        ]),
        ("Eshop tier (required to run eshop AC)", [
            ("QA_TABLET_TOKEN", "eshop", True,
             "config/qa-skill.env: eshop tabletToken JWT (our system; or Keychain "
             "autodev_qa_tablet_token)",
             _tablet_ok()),
        ]),
        ("orders-dashboard / KDS tier (required to run orders-dashboard AC)", [
            ("QA_ORDERS_EMAIL", "orders", False, "config/qa-skill.env: KDS login email (POST /users/authenticate)", _set("QA_ORDERS_EMAIL")),
            ("QA_ORDERS_PASSWORD", "orders", True, "config/qa-skill.env: KDS login password (our system)", _set("QA_ORDERS_PASSWORD")),
            ("ORDERS_REPO_QA", "orders", False, "orders-dashboard QA worktree (LOCAL mode — must exist)", _git_repo("ORDERS_REPO_QA")),
            ("ORDERS_REPO_SLUG", "orders", False, "GitHub owner/repo (REMOTE mode; default set)", _set("ORDERS_REPO_SLUG")),
            ("QA_ORDERS_DEV_URL", "orders", False, "deployed KDS dashboard dev URL (REMOTE mode)", _set("QA_ORDERS_DEV_URL")),
        ]),
        ("Local mode (required when repos ARE cloned locally)", [
            ("MAIN_REPO_DIR", "local", False, "dserve-backend source clone (must exist)", _git_repo("MAIN_REPO_DIR")),
            ("WEB_REPO_DIR", "local", False, "self-service-web source clone (must exist)", _git_repo("WEB_REPO_DIR")),
            ("MAIN_REPO_QA", "local", False, "dserve-backend QA worktree (must exist)", _git_repo("MAIN_REPO_QA")),
            ("WEB_REPO_QA", "local", False, "self-service-web QA worktree (must exist)", _git_repo("WEB_REPO_QA")),
        ]),
        ("Remote mode (required when NO local repos — test via GitHub + dev)", [
            ("MAIN_REPO_SLUG", "remote", False, "GitHub owner/repo for dserve-backend", _set("MAIN_REPO_SLUG")),
            ("WEB_REPO_SLUG", "remote", False, "GitHub owner/repo for self-service-web", _set("WEB_REPO_SLUG")),
            ("QA_ADMIN_DEV_URL", "remote", False, "deployed Blazor Admin dev URL (remote admin tier)", _set("QA_ADMIN_DEV_URL")),
            ("QA_ESHOP_DEV_URL", "remote", False, "deployed eshop dev URL", _set("QA_ESHOP_DEV_URL")),
        ]),
        ("Optional (have safe defaults)", [
            ("TRELLO_LIST_QA_APPROVED", "optional", False, "list id to move card on approve", _set("TRELLO_LIST_QA_APPROVED")),
            ("TRELLO_LIST_QA_REJECTED", "optional", False, "list id to move card on reject", _set("TRELLO_LIST_QA_REJECTED")),
            ("TRELLO_LIST_READY_FOR_PROD", "optional", False, "list id for ready-for-prod", _set("TRELLO_LIST_READY_FOR_PROD")),
            ("QA_ADMIN_PORT", "optional", False, "local Admin port (default 5080)", _set("QA_ADMIN_PORT")),
            ("QA_ESHOP_PORT", "optional", False, "local Vite port (default 5173)", _set("QA_ESHOP_PORT")),
            ("QA_API_PORT", "optional", False, "local API port (default 5070)", _set("QA_API_PORT")),
            ("QA_VITE_API_URL", "optional", False, "eshop /api target (default ss-dev)", _set("QA_VITE_API_URL")),
            ("QA_ORDERS_PORT", "optional", False, "local orders-dashboard port (default 3000)", _set("QA_ORDERS_PORT")),
            ("QA_ORDERS_API_URL", "optional", False, "orders-dashboard VITE_APP_API_URL (default ss-dev)", _set("QA_ORDERS_API_URL")),
            ("QA_DATA_ROOT", "optional", False, "runs/logs/runtime root (default ~/dserve-qa-skill-data)", _set("QA_DATA_ROOT")),
            ("QA_PLAYWRIGHT_RUNTIME", "optional", False, "Playwright runtime dir", _set("QA_PLAYWRIGHT_RUNTIME")),
            ("BOT_GIT_NAME", "optional", False, "git author name for scratch commits", _set("BOT_GIT_NAME")),
            ("BOT_GIT_EMAIL", "optional", False, "git author email", _set("BOT_GIT_EMAIL")),
        ]),
    ]

    tools = {
        "dotnet (.NET 8 ASP.NET Core)": _aspnet8(),
        "node / npx": bool(shutil.which("npx")),
        "jq": bool(shutil.which("jq")),
        "lsof": bool(shutil.which("lsof")),
        "Playwright runtime installed": _playwright_ok(),
    }

    # ── Render ──
    def mark(ok):
        return "✓" if ok else "✗ MISSING"

    print("", file=sys.stderr)
    print("════════ dserve-qa-runner — setup check ════════", file=sys.stderr)
    print(f"config file: {config_path}  {'(FIRST RUN — not found)' if first_run else '(found)'}", file=sys.stderr)

    out = {"first_run": first_run, "config_path": config_path, "groups": [],
           "tooling": tools, "missing_required_core": [], "missing_for": {}}
    core_ok = True
    for title, items in groups:
        print(f"\n{title}", file=sys.stderr)
        g = {"group": title, "items": []}
        for key, need, secret, desc, ok in items:
            print(f"  [{mark(ok)}] {key}  ({need}{', secret' if secret else ''})", file=sys.stderr)
            print(f"        {desc}", file=sys.stderr)
            g["items"].append({"key": key, "need": need, "secret": secret,
                               "ok": ok, "desc": desc})
            if not ok:
                out["missing_for"].setdefault(need, []).append(key)
                if need == "all":
                    core_ok = False
                    out["missing_required_core"].append(key)
        out["groups"].append(g)

    print("\nTooling (must be installed for the relevant tier):", file=sys.stderr)
    for name, ok in tools.items():
        print(f"  [{mark(ok)}] {name}", file=sys.stderr)

    ready = core_ok and not first_run
    out["ready"] = ready
    print("", file=sys.stderr)
    if first_run:
        print("→ FIRST RUN: no config file. The skill must ASK the user for the "
              "variables above (at minimum the 'all'-required ones, plus the set "
              "for the mode they'll use: local OR remote), then write the config "
              "file at the path above and re-run this check.", file=sys.stderr)
    elif not core_ok:
        print(f"→ MISSING CORE REQUIREMENTS: {', '.join(out['missing_required_core'])} "
              "— ask the user and update the config.", file=sys.stderr)
    else:
        print("→ READY (core creds present). Confirm the per-mode group "
              "(local vs remote) before running.", file=sys.stderr)

    print(json.dumps(out, indent=2))
    sys.exit(0 if ready else 3)


if __name__ == "__main__":
    main()
