# 📨 iMessage Exporter (imexporter)

Export iMessage DM history for specific contacts into tidy JSON/CSV files in iCloud, so you can build widgets, dashboards, and nerdy stats about your chats.

- Per-contact message history: `messages_<number>_dm.json` + `.csv`
- Per-day rollups: `rollup.json`
- Simple state file to avoid duplicates: `state.json`
- Auto-run via LaunchAgent at a configurable interval
- All data lives in **iCloud Drive** so macOS, iOS, Scriptable, and other tools can read it

---

## 💡 What it does

For each contact you configure, imexporter:

- Reads the local **Messages database** (`chat.db`) on your Mac  
- Finds all direct (1-to-1) messages to/from that phone number  
- Writes/updates files under:

```
iCloud Drive
└─ Documents
   └─ Social
      └─ Messaging
         └─ iMessage
            ├─ <+number>/
            │  ├ messages_<number>_dm.json
            │  ├ messages_<number>_dm.csv
            │  ├ rollup.json
            │  └ state.json
            ├─ index.json
            ├─ templates/
            └─ _me/
```

- On each run, **only new messages** are appended using `state.json`
- Daily totals are rebuilt into `rollup.json` for fast dashboards

> ⚠️ This tool only runs on **macOS**.  
> You must grant **Full Disk Access** to Python so it can read `~/Library/Messages/chat.db`.

---

## 📦 Requirements

- macOS (Ventura / Sonoma / Sequoia tested)
- Python 3 (Homebrew or system Python)
- iCloud Drive enabled and signed in
- Basic comfort with Terminal

---

## 🚀 Installation

### Install from GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/spcurtis81/imexporter/main/install_imexporter.sh   -o /tmp/install_imexporter.sh   && chmod +x /tmp/install_imexporter.sh   && /tmp/install_imexporter.sh
```

### Install from local clone

```bash
git clone https://github.com/spcurtis81/imexporter.git
cd imexporter
chmod +x install_imexporter.sh
./install_imexporter.sh
```

---

## 🔐 Full Disk Access (required)

Grant **Full Disk Access** to:

- Your chosen Python interpreter (e.g. `/opt/homebrew/bin/python3`)
- Your terminal app (Terminal, iTerm, etc.)

Path:

```
System Settings → Privacy & Security → Full Disk Access
```

---

## 🕹 First run & configuration

```bash
/opt/homebrew/bin/python3 "$HOME/Library/Application Support/imexporter/imexporter.py"
```

Use the menu to:
- Add / enable contacts
- Run exports
- Configure the LaunchAgent

---

## 📁 iCloud data location

```
~/Library/Mobile Documents/com~apple~CloudDocs/
Documents/Social/Messaging/iMessage/
```

---

## 📱 iOS & Scriptable widgets

Scriptable widgets explicitly refresh iCloud files using
`downloadFileFromiCloud()` to reduce stale data on iOS.

Tapping a widget may briefly open Scriptable — this is an iOS limitation.

---

## 🧹 Uninstalling

```bash
chmod +x uninstall_imexporter.sh
./uninstall_imexporter.sh
```

Choose whether to:
- Remove app only (recommended)
- Remove app + iCloud data (destructive)

---

## 🧾 License

MIT © Stephen Curtis
