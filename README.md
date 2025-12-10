# 📨 iMessage Exporter (imexporter)

Export iMessage DM history for specific contacts into tidy JSON/CSV files in iCloud, so you can build widgets, dashboards, and nerdy stats about your chats.

- Per-contact message history: `messages_<number>_dm.json` + `.csv`
- Per-day rollups: `rollup.json`
- Simple state file to avoid duplicates: `state.json`
- Auto-run via LaunchAgent at a configurable interval
- All data lives in iCloud Drive so your other tools can read it easily

---

## 💡 What it does

For each contact you configure:

- Reads the local `chat.db` Messages database on your Mac  
- Finds all messages to/from that phone number (DMs only)  
- Writes/updates files under:

  ```
  iCloud Drive
    └ Documents
      └ Social
        └ Messaging
          └ iMessage
             ├ <+number>/
             │  ├ messages_<number>_dm.json
             │  ├ messages_<number>_dm.csv
             │  ├ rollup.json
             │  └ state.json
             ├ index.json
             ├ templates/
             └ _me/
  ```

- The exporter only appends **new** messages after the last exported row, so it’s fast and avoids duplicates.

> ⚠️ This tool only works on **macOS**, and you must grant Full Disk Access to the Python interpreter so it can read `~/Library/Messages/chat.db`.

---

## 📦 Requirements

- macOS (Ventura / Sonoma / Sequoia tested)
- Python 3 (Homebrew or system)
- iCloud Drive enabled and signed in
- A bit of terminal comfort

---

## 🚀 Installation

You have two ways to install:

### Option 1 — One-liner from GitHub (remote install)

```
curl -fsSL https://raw.githubusercontent.com/spcurtis81/imexporter/main/install_imexporter.sh   -o /tmp/install_imexporter.sh && chmod +x /tmp/install_imexporter.sh && /tmp/install_imexporter.sh
```

### Option 2 — From a local clone / ZIP of this repo

```
git clone https://github.com/spcurtis81/imexporter.git
cd imexporter
chmod +x install_imexporter.sh
./install_imexporter.sh
```

---

## 🔐 Full Disk Access

Grant Full Disk Access to:

- your Python interpreter  
- your terminal app

`System Settings → Privacy & Security → Full Disk Access`

---

## 🕹 First run & configuration

Run the app once:

```
/opt/homebrew/bin/python3 "$HOME/Library/Application Support/imexporter/imexporter.py"
```

### 1. Add contacts  
### 2. Run Export Now  
### 3. Configure auto-run (LaunchAgent)

Check LaunchAgent status:

```
launchctl list | grep com.ste.imexporter
launchctl print gui/$(id -u)/com.ste.imexporter
```

---

## 📁 Where the data lives

```
~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Social/Messaging/iMessage/
```

Each contact folder contains:

- `messages_<number>_dm.json`
- `messages_<number>_dm.csv`
- `rollup.json`
- `state.json`

---

## 🧹 Uninstalling

From the repo root:

```
chmod +x uninstall_imexporter.sh
./uninstall_imexporter.sh
```

Options:

1. **Remove app only** (keeps iCloud data)
2. **Remove app + iCloud data** (requires typing `DELETE`)
0. Cancel

---

## 🧾 License

MIT License.

---

## 🐛 Issues

Open issues at:

https://github.com/spcurtis81/imexporter/issues