#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
imexporter.py — iMessage Exporter (DM-only)
MIT © Stephen Curtis

What this app does
------------------
• Exports iMessage DM history for selected contacts from the local Messages DB.
• Writes per-contact files in iCloud so Scriptable widgets can consume them.
• Appends only NEW rows using a simple state file (no duplicates).
• Builds per-day rollups: days[YYYY-MM-DD] => { me, them, total }.
• Provides a simple CLI menu for: Run Export, Add New Number, Settings, Help.
• Manages a LaunchAgent (interval) to auto-run every N minutes.
• Records last run timestamps and prints clear progress lines.

Important
---------
• The *first run* for a contact can import “All available” *on your Mac right now*.
  If iCloud later downloads older history, subsequent runs will include it too.
• You must grant **Full Disk Access** to:
    - your chosen python3 interpreter
    - your Terminal app
    - /bin/zsh
  (System Settings → Privacy & Security → Full Disk Access)
"""

import os, sys, json, csv, sqlite3, textwrap, shutil, subprocess, time
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Constants / Paths
# ─────────────────────────────────────────────────────────────────────────────
HOME = Path.home()
APP_DIR = HOME / "Library" / "Application Support" / "messages_export_v2"
LOG_DIR = HOME / "Library" / "Logs"
OUT_LOG = LOG_DIR / "messages_export_v2.out"
ERR_LOG = LOG_DIR / "messages_export_v2.err"

ICLOUD_ROOT = HOME / "Library" / "Mobile Documents" / "com~apple~CloudDocs"
DATA_ROOT = ICLOUD_ROOT / "Documents" / "Social" / "Messaging" / "iMessage"

INDEX_JSON = DATA_ROOT / "index.json"
ME_AVATAR = DATA_ROOT / "_me" / "avatar.png"

CONFIG_JSON = APP_DIR / "config.json"
LAUNCH_PLIST = HOME / "Library" / "LaunchAgents" / "com.ste.messages_export_v2.plist"

SCRIPT_PATH = Path(__file__).resolve()
PY_DEFAULT = shutil.which("python3") or "/usr/bin/python3"

# ─────────────────────────────────────────────────────────────────────────────
# CLI Banner
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
    (APP_DIR).mkdir(parents=True, exist_ok=True)
    (LOG_DIR).mkdir(parents=True, exist_ok=True)
    (DATA_ROOT).mkdir(parents=True, exist_ok=True)
    (DATA_ROOT / "_me").mkdir(parents=True, exist_ok=True)

def load_config():
    cfg = {
        "python_path": PY_DEFAULT,
        "refresh_minutes": 30,
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
def print_info(msg): print(f"•  {msg}")

def iso_now():
    return datetime.now().astimezone().replace(microsecond=0).isoformat()

def apple_time_to_iso(apple_time):
    """
    Messages 'date' is Apple Absolute Time.
    Newer macOS: nanoseconds since 2001-01-01.
    Older: seconds since 2001-01-01.
    We auto-detect by magnitude.
    """
    if apple_time is None:
        return None
    try:
        t = int(apple_time)
    except Exception:
        return None

    base = datetime(2001,1,1, tzinfo=timezone.utc)
    # Heuristic
    if abs(t) > 1_000_000_000_000:  # > ~2001s in ns
        dt = base + timedelta(seconds=t/1_000_000_000)
    else:
        dt = base + timedelta(seconds=t)
    return dt.astimezone().replace(microsecond=0).isoformat()

def day_key_from_iso(iso):
    # iso: "YYYY-MM-DDTHH:MM:SS+ZZ:ZZ"
    return (iso or "")[:10] if iso else None

def safe_int(x, default=0):
    try:
        return int(x)
    except Exception:
        return default

def print_last_run(contact_id, state):
    last = state.get("last_run_at")
    if last:
        print_info(f"Last run for {contact_id}: {last}")
    else:
        print_info(f"Last run for {contact_id}: (first run)")

def fda_hints():
    print()
    print_info("If you see 'unable to open database file', grant Full Disk Access to:")
    print("   • Your Terminal")
    print("   • /bin/zsh")
    print("   • Your python3 (see Settings → Config Summary)")
    print("System Settings → Privacy & Security → Full Disk Access")
    print()

# ─────────────────────────────────────────────────────────────────────────────
# Index.json helpers
# ─────────────────────────────────────────────────────────────────────────────
def load_index():
    if INDEX_JSON.exists():
        try:
            return json.loads(INDEX_JSON.read_text())
        except Exception:
            pass
    return {
        "schema": 1,
        "updated_at": iso_now(),
        "contacts": [],
        "meAvatar": "_me/avatar.png"
    }

def save_index(idx):
    idx["updated_at"] = iso_now()
    INDEX_JSON.write_text(json.dumps(idx, indent=2))

def ensure_contact_in_index(contact_id, display_name=None):
    idx = load_index()
    # Normalized folder name (we keep contact_id as folder)
    folder = contact_id
    exists = False
    for c in idx["contacts"]:
        if c.get("id") == contact_id:
            exists = True
            # Update name if provided
            if display_name:
                c["displayName"] = display_name
            c["last_updated"] = iso_now()
            break
    if not exists:
        idx["contacts"].append({
            "id": contact_id,
            "displayName": display_name or contact_id,
            "path": f"{folder}/",
            "last_updated": iso_now()
        })
    save_index(idx)

# ─────────────────────────────────────────────────────────────────────────────
# DB handling
# ─────────────────────────────────────────────────────────────────────────────
def find_messages_db():
    """
    Standard path:
      ~/Library/Messages/chat.db
    If not found, try candidate paths for newer OS migrations.
    """
    candidates = [
        HOME / "Library" / "Messages" / "chat.db",
        HOME / "Library" / "Group Containers" / "chatkit" / "Library" / "Messages" / "chat.db",  # rare
    ]
    for p in candidates:
        if p.exists():
            return p
    return candidates[0]  # default, even if missing (so user sees path)

def open_db_readonly(db_path: Path):
    uri = f"file:{db_path}?mode=ro"
    return sqlite3.connect(uri, uri=True)

# ─────────────────────────────────────────────────────────────────────────────
# Export queries (DM-only)
# ─────────────────────────────────────────────────────────────────────────────
SQL_MESSAGES_FOR_HANDLE = """
SELECT
  m.ROWID            AS rowid,
  m.date             AS date_apple,
  m.is_from_me       AS is_from_me,
  m.text             AS text,
  m.handle_id        AS handle_id
FROM message m
JOIN handle h ON h.ROWID = m.handle_id
WHERE h.id IN ({placeholders})
ORDER BY m.ROWID ASC;
"""

SQL_ATTACHMENTS_FOR_ROWID = """
SELECT a.filename, a.mime_type
FROM attachment a
JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
WHERE maj.message_id = ?
"""

def normalize_number_variants(num: str):
    """
    Build simple variants for the phone number, to improve matching in handle.id.
    Assumes num is E.164 like +4479...
    """
    raw = num.strip()
    variants = { raw }
    # Add version without spaces/dashes
    variants.add(raw.replace(" ", "").replace("-", ""))
    # Local-only digits (strip + and leading zeros)
    digits = "".join(ch for ch in raw if ch.isdigit())
    if digits:
        variants.add(digits)
    return sorted(variants)

def fetch_dm_rows(conn, number: str, min_rowid=None, since_days=None):
    """
    Fetch messages for a *specific handle* (DM-only).
    We filter by handle.id variants and optionally by rowid/since_days.
    """
    # Build base query with placeholders for variants
    variants = normalize_number_variants(number)
    placeholders = ",".join(["?"] * len(variants))
    sql = SQL_MESSAGES_FOR_HANDLE.format(placeholders=placeholders)

    params = list(variants)

    # We’ll post-filter by rowid and since date in Python (simplifies the SQL).
    cur = conn.cursor()
    cur.execute(sql, params)
    rows = cur.fetchall()

    # Convert and filter
    out = []
    cutoff_dt = None
    if since_days is not None and since_days > 0:
        cutoff_dt = datetime.now(timezone.utc) - timedelta(days=since_days)
    for (rowid, date_apple, is_from_me, text, handle_id) in rows:
        if min_rowid is not None and rowid <= min_rowid:
            continue
        iso = apple_time_to_iso(date_apple)
        if cutoff_dt and iso:
            try:
                if datetime.fromisoformat(iso) < cutoff_dt:
                    continue
            except Exception:
                pass
        out.append({
            "rowid": rowid,
            "date": iso,
            "is_from_me": int(is_from_me or 0),
            "text": text or "",
            "handle_id": handle_id
        })
    return out

def fetch_attachments_for_row(conn, rowid):
    cur = conn.cursor()
    cur.execute(SQL_ATTACHMENTS_FOR_ROWID, (rowid,))
    return [{"filename": r[0], "mime_type": r[1]} for r in cur.fetchall()]

# ─────────────────────────────────────────────────────────────────────────────
# Per-contact FS
# ─────────────────────────────────────────────────────────────────────────────
def contact_dir(contact_id: str) -> Path:
    return DATA_ROOT / contact_id

def ensure_contact_fs(contact_id: str):
    d = contact_dir(contact_id)
    d.mkdir(parents=True, exist_ok=True)
    return d

def paths_for_contact(contact_id: str):
    d = ensure_contact_fs(contact_id)
    safe_id = contact_id
    csv_path  = d / f"messages_{safe_id}_dm.csv"
    json_path = d / f"messages_{safe_id}_dm.json"
    rollup    = d / "rollup.json"
    state     = d / "state.json"
    return d, csv_path, json_path, rollup, state

def load_state(state_path: Path):
    if state_path.exists():
        try:
            return json.loads(state_path.read_text())
        except Exception:
            pass
    return {"last_rowid": 0, "last_run_at": None}

def save_state(state_path: Path, state):
    state["last_run_at"] = iso_now()
    state_path.write_text(json.dumps(state, indent=2))

def append_csv(csv_path: Path, rows):
    new_file = not csv_path.exists()
    with csv_path.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new_file:
            w.writerow(["rowid", "date", "is_from_me", "text", "attachments"])
        for r in rows:
            # Single-line text field (strip newlines)
            txt = (r.get("text") or "").replace("\r"," ").replace("\n"," ").strip()
            atts = r.get("attachments", [])
            att_str = ";".join(a.get("filename","") or "" for a in atts)
            w.writerow([r.get("rowid"), r.get("date"), r.get("is_from_me"), txt, att_str])

def append_json(json_path: Path, rows):
    """
    Keep an ever-growing JSON array (append new rows).
    For large data sets this grows; fine for personal scale.
    """
    data = []
    if json_path.exists():
        try:
            data = json.loads(json_path.read_text())
        except Exception:
            data = []
    # Extend and write back
    data.extend(rows)
    json_path.write_text(json.dumps(data, indent=2))

def load_rollup(rollup_path: Path):
    if rollup_path.exists():
        try:
            return json.loads(rollup_path.read_text())
        except Exception:
            pass
    return {"days": {}, "updated_at": iso_now()}

def save_rollup(rollup_path: Path, roll):
    roll["updated_at"] = iso_now()
    rollup_path.write_text(json.dumps(roll, indent=2))

def update_rollup(rollup_path: Path, new_rows):
    roll = load_rollup(rollup_path)
    days = roll.setdefault("days", {})
    for r in new_rows:
        dk = day_key_from_iso(r.get("date"))
        if not dk:
            continue
        v = days.get(dk) or {"me": 0, "them": 0, "total": 0}
        if r.get("is_from_me"):
            v["me"] += 1
        else:
            v["them"] += 1
        v["total"] = v.get("me", 0) + v.get("them", 0)
        days[dk] = v
    save_rollup(rollup_path, roll)

# ─────────────────────────────────────────────────────────────────────────────
# Export logic
# ─────────────────────────────────────────────────────────────────────────────
def export_contact(conn, contact_id: str, import_scope: str = "incremental", days: int = None):
    """
    import_scope:
      - "all"           : ignore state.rowid (but still append & state update)
      - "last_n_days"   : only include messages within N days
      - "none"          : do nothing (setup only)
      - "incremental"   : default; only rowid > last_rowid
    """
    d, csv_path, json_path, rollup_path, state_path = paths_for_contact(contact_id)
    state = load_state(state_path)
    print_last_run(contact_id, state)

    if import_scope == "none":
        print_info(f"{contact_id}: setup only (no import)")
        return 0

    min_rowid = None
    since_days = None

    if import_scope == "all":
        min_rowid = None
        print_info("Initial import: all available messages currently on this Mac.")
    elif import_scope == "last_n_days":
        since_days = max(0, int(days or 0))
        print_info(f"Initial import: last {since_days} day(s).")
    else:
        # incremental
        min_rowid = safe_int(state.get("last_rowid"), 0)

    # Fetch rows (DM-only)
    rows = fetch_dm_rows(conn, contact_id, min_rowid=min_rowid, since_days=since_days)

    # Attachments for each
    enriched = []
    for r in rows:
        atts = fetch_attachments_for_row(conn, r["rowid"])
        r["attachments"] = atts
        enriched.append(r)

    if not enriched:
        print("Checked at {}: 0 new messages".format(datetime.now().replace(microsecond=0).isoformat()))
        # Still update last_run time
        save_state(state_path, state)
        return 0

    # Append to CSV & JSON
    append_csv(csv_path, enriched)
    append_json(json_path, enriched)

    # Update rollup
    update_rollup(rollup_path, enriched)

    # Update state
    max_rowid = max(r["rowid"] for r in enriched)
    state["last_rowid"] = max(state.get("last_rowid", 0), max_rowid)
    save_state(state_path, state)

    print(f"Appended {len(enriched)} new messages")
    print(f"   CSV   : {csv_path}")
    print(f"   JSON  : {json_path}")
    print(f"   ROLLUP: {rollup_path}")
    print(f"   State : last_rowid={state['last_rowid']}")
    return len(enriched)

# ─────────────────────────────────────────────────────────────────────────────
# LaunchAgent
# ─────────────────────────────────────────────────────────────────────────────
PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key> <string>com.ste.messages_export_v2</string>
  <key>StartInterval</key> <integer>{interval}</integer>
  <key>ProgramArguments</key>
  <array>
    <string>{python}</string>
    <string>{script}</string>
    <string>--auto-run</string>
  </array>
  <key>StandardOutPath</key> <string>{outlog}</string>
  <key>StandardErrorPath</key> <string>{errlog}</string>
  <key>KeepAlive</key> <true/>
</dict>
</plist>
"""

def write_launch_agent(refresh_minutes: int, python_path: str):
    payload = PLIST_TEMPLATE.format(
        interval=max(60, int(refresh_minutes)*60),
        python=python_path,
        script=str(SCRIPT_PATH),
        outlog=str(OUT_LOG),
        errlog=str(ERR_LOG),
    )
    LAUNCH_PLIST.write_text(payload)
    print_ok(f"Wrote LaunchAgent plist with interval={refresh_minutes} min")
    print_info(f"{LAUNCH_PLIST}")

def reload_launch_agent():
    label = "com.ste.messages_export_v2"
    # Try unload then load (ignore errors)
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(LAUNCH_PLIST)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(LAUNCH_PLIST)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print_ok("Reloaded LaunchAgent")

# ─────────────────────────────────────────────────────────────────────────────
# Settings menu
# ─────────────────────────────────────────────────────────────────────────────
def settings_menu():
    cfg = load_config()
    while True:
        print()
        print("Settings")
        print("--------")
        print("1) Change run frequency (minutes)")
        print("2) Scan/select Python interpreter")
        print("3) Config Summary")
        print("4) Back")
        choice = input("> ").strip()
        if choice == "1":
            try:
                n = int(input("Enter minutes (>=1) [current {}]: ".format(cfg["refresh_minutes"])).strip() or cfg["refresh_minutes"])
                cfg["refresh_minutes"] = max(1, n)
                save_config(cfg)
                write_launch_agent(cfg["refresh_minutes"], cfg["python_path"])
                reload_launch_agent()
            except Exception as e:
                print_fail(f"Invalid value: {e}")
        elif choice == "2":
            pths = scan_pythons()
            if not pths:
                print_fail("No python3 interpreters found; keeping current.")
                continue
            for i,p in enumerate(pths,1):
                print(f"  {i}) {p}")
            pick = input("Select [1-{}] (Enter keeps current={}): ".format(len(pths), cfg["python_path"])).strip()
            if pick:
                try:
                    idx = max(1, min(len(pths), int(pick))) - 1
                    cfg["python_path"] = pths[idx]
                    save_config(cfg)
                    write_launch_agent(cfg["refresh_minutes"], cfg["python_path"])
                    reload_launch_agent()
                except Exception as e:
                    print_fail(f"Selection error: {e}")
        elif choice == "3":
            config_summary()
        elif choice == "4":
            break
        else:
            print("…")

def scan_pythons():
    candidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.*/bin/python3",
        "/usr/bin/python3",
    ]
    found = []
    for pat in candidates:
        for p in sorted(Path("/").glob(pat.lstrip("/"))):
            if os.access(p, os.X_OK):
                found.append(str(p))
    envp = shutil.which("python3")
    if envp and envp not in found:
        found.append(envp)
    # Dedup
    dedup = []
    for p in found:
        if p not in dedup:
            dedup.append(p)
    return dedup

def config_summary():
    cfg = load_config()
    print()
    print("Config Summary")
    print("--------------")
    print(f"Python:          {cfg['python_path']}")
    print(f"Refresh minutes: {cfg['refresh_minutes']}")
    print(f"App dir:         {APP_DIR}")
    print(f"Logs:            {OUT_LOG} / {ERR_LOG}")
    print(f"Data root:       {DATA_ROOT}")
    print(f"Index file:      {INDEX_JSON}")
    # FDA hints
    print()
    print("Full Disk Access (recommended):")
    print("  • Your Terminal")
    print("  • /bin/zsh")
    print(f"  • {cfg['python_path']}")
    # List contacts
    idx = load_index()
    print()
    print("Contacts:")
    if not idx.get("contacts"):
        print("  (none)")
    else:
        for c in idx["contacts"]:
            print(f"  - {c.get('displayName','?')} [{c.get('id','?')}] -> {c.get('path')}")

# ─────────────────────────────────────────────────────────────────────────────
# Add new contact flow
# ─────────────────────────────────────────────────────────────────────────────
def add_new_number():
    print()
    print("Add New Number")
    print("--------------")
    print("Enter number in E.164 format (e.g. +447962786922).")
    contact_id = input("Contact number: ").strip()
    if not contact_id:
        print_fail("No number entered")
        return
    display = input("Display name (optional): ").strip() or contact_id

    # Create FS + index entry
    ensure_contact_fs(contact_id)
    ensure_contact_in_index(contact_id, display)

    # Import scope
    print()
    print("Initial import scope:")
    print("  1) All available on this Mac now")
    print("  2) Last N days")
    print("  3) None (setup only)")
    sel = (input("> ").strip() or "1")
    scope = "all"
    days = None
    if sel == "2":
        scope = "last_n_days"
        try:
            days = int(input("Enter N days: ").strip())
        except Exception:
            days = 30
    elif sel == "3":
        scope = "none"

    # Optional avatar hint
    d = contact_dir(contact_id)
    print()
    print_info(f"You can drop an avatar here (optional): {d/'avatar.png'}")

    # Run first import
    dbp = find_messages_db()
    try:
        conn = open_db_readonly(dbp)
    except Exception as e:
        print_fail(f"DB open failed: {e}")
        fda_hints()
        return
    try:
        print()
        print_info(f"Using DB: {dbp}")
        export_contact(conn, contact_id, import_scope=scope, days=days)
    finally:
        conn.close()

# ─────────────────────────────────────────────────────────────────────────────
# Menu + auto-run
# ─────────────────────────────────────────────────────────────────────────────
def run_export_all():
    idx = load_index()
    contacts = [c.get("id") for c in idx.get("contacts", [])]
    if not contacts:
        print_info("No contacts configured yet.")
        return

    dbp = find_messages_db()
    try:
        conn = open_db_readonly(dbp)
    except Exception as e:
        print_fail(f"DB open failed: {e}")
        fda_hints()
        return

    try:
        print_info(f"Using DB: {dbp}")
        total_new = 0
        for cid in contacts:
            print()
            print_info(f"→ Exporting {cid}")
            n = export_contact(conn, cid, import_scope="incremental")
            total_new += n
        print()
        print_ok(f"Done. Total new messages this run: {total_new}")
    finally:
        conn.close()

def help_placeholder():
    print()
    print("HELP — Coming soon")
    print("Docs: GitHub README and wiki (to be linked).")

def menu():
    ensure_dirs()
    cfg = load_config()
    # Ensure index exists
    if not INDEX_JSON.exists():
        save_index(load_index())

    # Initial setup checklist (visual)
    print("Setup Checklist")
    print("---------------")
    print_ok(f"App dir: {APP_DIR}")
    print_ok(f"Logs dir: {LOG_DIR}")
    print_ok(f"Data root: {DATA_ROOT}")
    print_ok(f"Index: {INDEX_JSON}")
    print_ok(f"Python: {cfg['python_path']}")
    print()

    while True:
        print("Main Menu")
        print("---------")
        print("1) Run Export (all contacts)")
        print("2) Add New Number")
        print("3) Settings")
        print("4) Help")
        print("5) Exit")
        choice = input("> ").strip()
        if choice == "1":
            # Show last run for each contact briefly
            idx = load_index()
            for c in idx.get("contacts", []):
                cid = c.get("id")
                state_path = paths_for_contact(cid)[-1]  # state.json
                st = load_state(state_path)
                print_last_run(cid, st)
            print()
            run_export_all()
        elif choice == "2":
            add_new_number()
        elif choice == "3":
            settings_menu()
        elif choice == "4":
            help_placeholder()
        elif choice == "5":
            break
        else:
            print("…")
        print()

def auto_run():
    """For LaunchAgent: just run export all, minimal chatter."""
    ensure_dirs()
    cfg = load_config()
    idx = load_index()
    contacts = [c.get("id") for c in idx.get("contacts", [])]
    if not contacts:
        return
    dbp = find_messages_db()
    try:
        conn = open_db_readonly(dbp)
    except Exception:
        return
    try:
        total_new = 0
        for cid in contacts:
            n = export_contact(conn, cid, import_scope="incremental")
            total_new += n
        # Light line for logs
        print(f"Checked at {datetime.now().replace(microsecond=0).isoformat()}: {total_new} new total")
    finally:
        conn.close()

# ─────────────────────────────────────────────────────────────────────────────
# Entry
# ─────────────────────────────────────────────────────────────────────────────
def main():
    banner()
    if "--auto-run" in sys.argv:
        auto_run()
        return
    menu()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n(Interrupted)")
