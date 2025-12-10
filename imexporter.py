#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
imexporter.py — iMessage Exporter (DM-only)
MIT © Stephen Curtis

Exports iMessage DM history for selected contacts into JSON/CSV files in iCloud,
builds rollups, and supports auto-run via a LaunchAgent.
"""

import os, sys, json, csv, sqlite3, textwrap, shutil, subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Constants / Paths (these now match your installer + uninstaller)
# ─────────────────────────────────────────────────────────────────────────────

HOME = Path.home()

# Local app folder
APP_DIR = HOME / "Library" / "Application Support" / "imexporter"

# Logs (local)
LOG_DIR = HOME / "Library" / "Logs"
OUT_LOG = LOG_DIR / "imexporter.out"
ERR_LOG = LOG_DIR / "imexporter.err"

# iCloud data folder (unchanged — same structure as before)
ICLOUD_ROOT = HOME / "Library" / "Mobile Documents" / "com~apple~CloudDocs"
DATA_ROOT = ICLOUD_ROOT / "Documents" / "Social" / "Messaging" / "iMessage"

INDEX_JSON = DATA_ROOT / "index.json"
ME_AVATAR = DATA_ROOT / "_me" / "avatar.png"

CONFIG_JSON = APP_DIR / "config.json"

# LaunchAgent (this matches install_imexporter.sh)
LAUNCH_PLIST = HOME / "Library" / "LaunchAgents" / "com.ste.imexporter.plist"

SCRIPT_PATH = Path(__file__).resolve()
PY_DEFAULT = shutil.which("python3") or "/usr/bin/python3"

# macOS Messages database
DB_PATHS = [
    HOME / "Library" / "Messages" / "chat.db",
]

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────

def banner():
    year = datetime.now().year
    print("="*59)
    print(" iMessage Exporter (imexporter)".center(59))
    print("="*59)
    print(f"MIT © Stephen Curtis, {year}")
    print()

# ─────────────────────────────────────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────────────────────────────────────

def ensure_dirs():
    APP_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    (DATA_ROOT / "_me").mkdir(parents=True, exist_ok=True)

def load_config():
    cfg = {
        "python_path": PY_DEFAULT,
        "refresh_minutes": 30
    }
    if CONFIG_JSON.exists():
        try:
            cfg.update(json.loads(CONFIG_JSON.read_text()))
        except Exception:
            pass
    return cfg

def save_config(cfg):
    CONFIG_JSON.write_text(json.dumps(cfg, indent=2))

def print_ok(msg):   print(f"✅ {msg}")
def print_fail(msg): print(f"❌ {msg}")
def print_info(msg): print(f"• {msg}")

def iso_now():
    return datetime.now().astimezone().replace(microsecond=0).isoformat()

def apple_time_to_iso(apple_time):
    if apple_time is None:
        return None
    try:
        t = int(apple_time)
    except Exception:
        return None

    base = datetime(2001, 1, 1, tzinfo=timezone.utc)

    # nanoseconds?
    if abs(t) > 1_000_000_000_000:
        dt = base + timedelta(seconds=t / 1_000_000_000)
    else:
        dt = base + timedelta(seconds=t)

    return dt.astimezone().replace(microsecond=0).isoformat()

def day_key_from_iso(iso):
    return (iso or "")[:10]

# ─────────────────────────────────────────────────────────────────────────────
# Messages DB helpers
# ─────────────────────────────────────────────────────────────────────────────

def find_messages_db():
    for p in DB_PATHS:
        if p.exists():
            return p
    return None

def open_db():
    db_path = find_messages_db()
    if not db_path:
        raise FileNotFoundError("Messages chat.db not found. Check Full Disk Access.")
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn

def fetch_handle_ids_for_number(conn, number):
    like = number.replace(" ", "")
    cur = conn.cursor()
    cur.execute(
        """
        SELECT ROWID, id
        FROM handle
        WHERE id LIKE ? OR id LIKE ?
        """,
        (f"%{like}", f"%{like.replace('+','')}"),
    )
    rows = cur.fetchall()
    return [r["ROWID"] for r in rows]

def fetch_messages_for_handles(conn, handle_ids, since_rowid=None):
    if not handle_ids:
        return []

    params = list(handle_ids)
    handle_clause = ",".join("?" for _ in handle_ids)

    where = f"m.handle_id IN ({handle_clause})"
    if since_rowid is not None:
        where += " AND m.ROWID > ?"
        params.append(since_rowid)

    sql = f"""
    SELECT
        m.ROWID          AS rowid,
        m.date           AS date,
        m.is_from_me     AS is_from_me,
        m.text           AS text
    FROM message m
    WHERE {where}
    ORDER BY m.ROWID ASC
    """

    cur = conn.cursor()
    cur.execute(sql, params)
    return cur.fetchall()

# ─────────────────────────────────────────────────────────────────────────────
# Contact index (index.json)
# ─────────────────────────────────────────────────────────────────────────────

def load_index():
    if not INDEX_JSON.exists():
        return {"contacts": []}
    try:
        return json.loads(INDEX_JSON.read_text())
    except Exception:
        return {"contacts": []}

def save_index(data):
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    INDEX_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False))

def list_contacts():
    idx = load_index()
    return idx.get("contacts", [])

def add_contact(number, label):
    idx = load_index()
    contacts = idx.get("contacts", [])
    existing = next((c for c in contacts if c.get("number") == number), None)
    if existing:
        existing["label"] = label
        existing["enabled"] = True
    else:
        contacts.append({
            "number": number,
            "label": label,
            "enabled": True
        })
    idx["contacts"] = contacts
    save_index(idx)

def disable_contact(number):
    idx = load_index()
    changed = False
    for c in idx.get("contacts", []):
        if c.get("number") == number:
            c["enabled"] = False
            changed = True
    if changed:
        save_index(idx)

# ─────────────────────────────────────────────────────────────────────────────
# State per contact
# ─────────────────────────────────────────────────────────────────────────────

def contact_dir(number):
    d = DATA_ROOT / number
    d.mkdir(parents=True, exist_ok=True)
    return d

def state_path(number):
    return contact_dir(number) / "state.json"

def load_state(number):
    p = state_path(number)
    if not p.exists():
        return {"last_rowid": None, "last_run": None}
    try:
        return json.loads(p.read_text())
    except Exception:
        return {"last_rowid": None, "last_run": None}

def save_state(number, state):
    p = state_path(number)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(p)

# ─────────────────────────────────────────────────────────────────────────────
# Export logic
# ─────────────────────────────────────────────────────────────────────────────

def export_for_contact(conn, number, label):
    handles = fetch_handle_ids_for_number(conn, number)
    if not handles:
        print_fail(f"{number}: no matching handles found in Messages db")
        return

    st = load_state(number)
    last_rowid = st.get("last_rowid")

    rows = fetch_messages_for_handles(conn, handles, since_rowid=last_rowid)

    if not rows and last_rowid is not None:
        # Nothing new
        print_info(f"{number} ({label}): no new messages")
        st["last_run"] = iso_now()
        save_state(number, st)
        return

    if not rows and last_rowid is None:
        # No messages at all
        print_info(f"{number} ({label}): no messages found")
        st["last_run"] = iso_now()
        save_state(number, st)
        return

    # Merge with existing json
    cdir = contact_dir(number)
    json_path = cdir / f"messages_{number}_dm.json"
    csv_path = cdir / f"messages_{number}_dm.csv"
    rollup_path = cdir / "rollup.json"

    existing = []
    if json_path.exists():
        try:
            existing = json.loads(json_path.read_text())
        except Exception:
            existing = []

    new_records = []
    max_rowid = last_rowid or 0

    for r in rows:
        rowid = r["rowid"]
        if rowid > max_rowid:
            max_rowid = rowid

        iso_ts = apple_time_to_iso(r["date"])
        new_records.append({
            "rowid": rowid,
            "date": iso_ts,
            "is_from_me": bool(r["is_from_me"]),
            "text": r["text"],
        })

    merged = existing + new_records

    # Write JSON
    tmp = json_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(merged, indent=2, ensure_ascii=False))
    tmp.replace(json_path)

    # Write CSV
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["rowid", "date", "is_from_me", "text"])
        for msg in merged:
            w.writerow([
                msg["rowid"],
                msg["date"],
                1 if msg["is_from_me"] else 0,
                msg["text"] or "",
            ])

    # Build rollup
    days = {}
    for msg in merged:
        dk = day_key_from_iso(msg["date"])
        if not dk:
            continue
        bucket = days.setdefault(dk, {"me": 0, "them": 0, "total": 0})
        bucket["total"] += 1
        if msg["is_from_me"]:
            bucket["me"] += 1
        else:
            bucket["them"] += 1

    tmp_r = rollup_path.with_suffix(".tmp")
    tmp_r.write_text(json.dumps({"days": days}, indent=2, ensure_ascii=False))
    tmp_r.replace(rollup_path)

    st["last_rowid"] = max_rowid
    st["last_run"] = iso_now()
    save_state(number, st)

    print_ok(f"{number} ({label}): exported {len(new_records)} new messages (total {len(merged)})")

# ─────────────────────────────────────────────────────────────────────────────
# LaunchAgent template + management
# ─────────────────────────────────────────────────────────────────────────────

PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.
0//EN" 
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key> <string>com.ste.imexporter</string>
  <key>StartInterval</key> <integer>{interval}</integer>
  <key>ProgramArguments</key>
  <array>
    <string>{python}</string>
    <string>{script}</string>
    <string>--auto-run</string>
  </array>
  <key>StandardOutPath</key>  <string>{outlog}</string>
  <key>StandardErrorPath</key><string>{errlog}</string>
  <key>KeepAlive</key>        <true/>
</dict>
</plist>
"""

def write_launch_agent(refresh_minutes, python):
    plist = PLIST_TEMPLATE.format(
        interval=max(60, refresh_minutes * 60),
        python=python,
        script=str(SCRIPT_PATH),
        outlog=str(OUT_LOG),
        errlog=str(ERR_LOG),
    )
    LAUNCH_PLIST.write_text(plist)
    print_ok("LaunchAgent plist written")

def reload_launch_agent():
    label = "com.ste.imexporter"
    # stop if running
    subprocess.run(
        ["launchctl", "bootout", f"gui/{os.getuid()}/{LAUNCH_PLIST}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    # load fresh
    subprocess.run(
        ["launchctl", "bootstrap", f"gui/{os.getuid()}", str(LAUNCH_PLIST)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    subprocess.run(
        ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    print_ok("LaunchAgent reloaded")

# ─────────────────────────────────────────────────────────────────────────────
# Settings menu
# ─────────────────────────────────────────────────────────────────────────────

def scan_pythons():
    cands = []
    for p in [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]:
        if Path(p).exists():
            cands.append(p)
    which = shutil.which("python3")
    if which and which not in cands:
        cands.append(which)
    return cands

def pick_python_menu(cfg):
    cands = scan_pythons()
    print()
    print("Select python3 interpreter:")
    for i, p in enumerate(cands, start=1):
        print(f"{i}) {p}")
    print("0) Cancel")
    try:
        choice = int(input("> ").strip() or "0")
    except ValueError:
        return
    if choice <= 0 or choice > len(cands):
        return
    chosen = cands[choice - 1]
    cfg["python_path"] = chosen
    save_config(cfg)
    write_launch_agent(cfg["refresh_minutes"], cfg["python_path"])
    reload_launch_agent()

def settings_menu():
    cfg = load_config()
    while True:
        print()
        print("Settings")
        print("--------")
        print("1) Change run frequency (minutes)")
        print("2) Scan/select Python interpreter")
        print("3) Config summary")
        print("0) Back")
        choice = input("> ").strip()
        if choice == "1":
            try:
                mins = int(input("Minutes (min 1): ").strip())
            except ValueError:
                print_fail("Invalid number")
                continue
            if mins < 1:
                mins = 1
            cfg["refresh_minutes"] = mins
            save_config(cfg)
            write_launch_agent(cfg["refresh_minutes"], cfg["python_path"])
            reload_launch_agent()
        elif choice == "2":
            pick_python_menu(cfg)
        elif choice == "3":
            print(json.dumps(cfg, indent=2))
            print(f"App dir:   {APP_DIR}")
            print(f"Data root: {DATA_ROOT}")
        elif choice == "0":
            return

# ─────────────────────────────────────────────────────────────────────────────
# NEW: Safe + robust run_export() that skips malformed contacts
# ─────────────────────────────────────────────────────────────────────────────

def run_export(auto=False):
    ensure_dirs()
    idx = load_index()

    # NEW: validate contacts before running
    raw = idx.get("contacts", [])
    contacts = []

    for c in raw:
        number = c.get("number")
        if not number:
            print_fail("Skipping malformed contact in index.json (missing 'number')")
            continue
        if not c.get("enabled", True):
            continue
        contacts.append(c)

    if not contacts:
        print_info("No enabled contacts with valid numbers found. Nothing to export.")
        return

    conn = open_db()
    try:
        changed = 0
        for c in contacts:
            num = c["number"]
            label = c.get("label", num)
            before = load_state(num)
            before_id = before.get("last_rowid")
            export_for_contact(conn, num, label)
            after = load_state(num)
            if after.get("last_rowid") != before_id:
                changed += 1
        print_info(f"Checked at {iso_now()}: {changed} contacts had new messages")
    finally:
        conn.close()

# ─────────────────────────────────────────────────────────────────────────────
# CLI menus
# ─────────────────────────────────────────────────────────────────────────────

def add_contact_menu():
    print()
    print("Add / Enable Contact")
    print("--------------------")
    num = input("Enter phone number (E.164, e.g. +4479...): ").strip()
    if not num:
        print("Cancelled.")
        return
    label = input("Display name: ").strip() or num
    add_contact(num, label)
    print_ok(f"Saved contact {label} ({num})")

def list_contacts_menu():
    contacts = list_contacts()
    if not contacts:
        print("No contacts configured.")
        return
    print()
    print("Configured contacts:")
    for c in contacts:
        flag = "✅" if c.get("enabled", True) else "❌"
        print(f"{flag} {c.get('label')} ({c.get('number')})")

# ─────────────────────────────────────────────────────────────────────────────
# Main CLI
# ─────────────────────────────────────────────────────────────────────────────

def main():
    ensure_dirs()
    banner()

    if "--auto-run" in sys.argv:
        run_export(auto=True)
        return 0

    while True:
        print("Main Menu")
        print("---------")
        print("1) Run Export Now")
        print("2) Add / Enable Contact")
        print("3) List Contacts")
        print("4) Settings")
        print("5) Help")
        print("0) Quit")
        choice = input("> ").strip()

        if choice == "1":
            run_export()
        elif choice == "2":
            add_contact_menu()
        elif choice == "3":
            list_contacts_menu()
        elif choice == "4":
            settings_menu()
        elif choice == "5":
            print()
            print("Help")
            print("----")
            print(textwrap.dedent("""
                • Add contacts using option 2 (E.164 format, e.g. +4479...).
                • Data is written under iCloud Drive:
                    Documents/Social/Messaging/iMessage/
                • Each contact gets:
                    messages_<number>_dm.json
                    messages_<number>_dm.csv
                    rollup.json
                    state.json
                • Use Settings to choose Python and auto-run interval.
            """).strip())
        elif choice == "0":
            return 0
        else:
            print("Unknown option.")

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        print("Interrupted.")
        sys.exit(1)