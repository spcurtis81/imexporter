# 📘 iMessage Exporter — User Guide

A lightweight, privacy-first macOS + iOS toolkit for exporting, analysing, and visualising your personal iMessage history using iCloud Drive and Scriptable widgets.

---

## 🔍 What This Tool Does

**imexporter runs on your Mac** and reads your local iMessage database (`chat.db`).
It **never uploads data anywhere** — everything stays on your devices.

It generates structured JSON and CSV files in **iCloud Drive**, which are then read by **Scriptable widgets** on iPhone or iPad to show:

- 📅 Messages today  
- 📈 Message trends over time  
- 📊 Lifetime stats (totals, averages, records)

---

## 🧰 What You’ll Need

| Requirement | Purpose |
|---|---|
| macOS + Python 3 | Runs the exporter |
| iCloud Drive | Syncs data to iOS |
| iPhone / iPad | Displays widgets |
| Scriptable app | Renders dashboards |
| Terminal (basic) | Install & config |

---

## ⚙️ Installing on macOS

```bash
curl -fsSL https://raw.githubusercontent.com/spcurtis81/imexporter/main/install_imexporter.sh \
  -o /tmp/install_imexporter.sh && \
chmod +x /tmp/install_imexporter.sh && \
/tmp/install_imexporter.sh
```

### What the installer does
- Creates:
  - `~/Library/Application Support/imexporter`
  - `~/Library/LaunchAgents/com.ste.imexporter.plist`
- Creates iCloud data folder:
  ```
  iCloud Drive / Documents / Social / Messaging / iMessage
  ```
- Lets you choose a Python interpreter
- Installs Scriptable widget templates
- Prepares (but does **not** auto-enable) the LaunchAgent

---

## 🔐 Full Disk Access (REQUIRED)

Grant **Full Disk Access** to:
- Your chosen Python interpreter (e.g. `/opt/homebrew/bin/python3`)
- Your terminal app

Path:

```
System Settings → Privacy & Security → Full Disk Access
```

Without this, exports will silently fail.

---

## ▶️ First Run & Adding a Contact

```bash
/opt/homebrew/bin/python3 \
"$HOME/Library/Application Support/imexporter/imexporter.py"
```

Menu options:
1. Run Export Now  
2. Add / Enable Contact  
3. List Contacts  
4. Settings  
5. Help  

### Adding a contact
- Enter phone number in **E.164 format** (e.g. `+4479…`)
- Choose a display name
- The exporter creates the contact folder and `state.json`

---

## 📁 iCloud File Structure (Authoritative)

```
iCloud Drive
└─ Documents
   └─ Social
      └─ Messaging
         └─ iMessage
            ├─ index.json
            ├─ _me/
            │  └─ avatar.png
            ├─ +447962786922/
            │  ├ messages_+447962786922_dm.json
            │  ├ messages_+447962786922_dm.csv
            │  ├ rollup.json
            │  └ state.json
            └─ templates/
```

Do not manually edit these files unless you know what you’re doing.

---

## 📱 iOS Widgets & Scriptable (IMPORTANT)

### File Bookmark (required)

In Scriptable:
1. Settings → File Bookmarks  
2. Add a bookmark pointing to:
   ```
   iCloud Drive / Documents / Social / Messaging / iMessage
   ```
3. Name it **exactly**:
   ```
   MessagesStats
   ```

### Widgets
Scripts:
- `imessage_today.js`
- `imessage_trend.js`
- `imessage_stats.js`

Each widget:
- Auto-detects the active contact from `index.json`
- Calls `downloadFileFromiCloud()` before reading data (reduces stale iOS sync)
- May briefly open Scriptable when tapped (iOS limitation)

This is expected.

---

## 🪞 Avatars (Optional)

- Your avatar:
  ```
  ... / iMessage / _me / avatar.png
  ```
- Contact avatar:
  ```
  ... / iMessage / <number> / avatar.png
  ```

If missing, widgets fall back to initials.

---

## ⚙️ Settings Menu

From the CLI you can:
- Enable / disable auto-run
- Change refresh interval
- List contacts and data paths
- View configuration summary

---

## 🧹 Uninstalling

```bash
./uninstall_imexporter.sh
```

Choose:
1. Remove app only (**recommended**)  
2. Remove app + iCloud data (destructive)

You’ll be prompted before deletion.

---

## 🧾 Troubleshooting

- Widgets stale → iOS iCloud delay (Scriptable forces refresh)
- “File not found” → bookmark misnamed or wrong folder
- Export runs but files unchanged → Full Disk Access missing
- Duplicate contacts → legacy entries in `index.json`

---

## 📬 Support

GitHub: https://github.com/spcurtis81/imexporter  
Issues: include macOS version + installer output
