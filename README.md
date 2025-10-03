# iMessage Exporter (imexporter)

_A cross-platform toolchain for exporting, tracking, and visualising iMessage data._

---

## 🚀 What is this?

**imexporter** is a Python-based Mac utility plus Scriptable widgets for iOS.  
It automatically exports your iMessage history (per contact), stores it as JSON, and syncs to iCloud so that Scriptable widgets on iOS can display **daily stats, history charts, and lifetime totals**.

---

## 📦 Features

- 🔄 Automated export of iMessages from Mac (via launchd)
- 📂 Clean folder structure in iCloud Drive
- 📊 Multiple per-contact stats:
  - Today’s count
  - 30-day trend chart
  - Lifetime totals + daily averages
- 📱 Three Scriptable widgets (medium size)
- ⚙️ CLI interface on Mac with menu for:
  - Adding new numbers
  - Running ad-hoc exports
  - Configuring refresh frequency
  - Viewing config summary
  - (Help menu coming soon)

---

## 📋 Prerequisites

- macOS with iMessage + full disk access granted to Terminal/Python
- Python 3.9+ installed (`brew install python@3.13` recommended)
- iCloud Drive enabled on both Mac and iOS
- [Scriptable](https://scriptable.app/) installed on iOS

---

## 📂 Folder Structure

The Mac app will create this automatically on first run:

iCloud Drive / Documents / Social / Messaging / iMessage /
index.json                     ← master list of contacts
_me/                           ← optional avatar for “you”
avatar.png
+447962786922/                 ← per-contact folder
rollup.json                  ← full rollup of messages
trend_30d.json               ← summary for trend widget
meta.json                    ← metadata
avatar.png                   ← optional avatar for contact

---

## ⚡ Typical Workflow

1. **Install** the repo and run `installer.sh`
2. **First run** will:
   - Create the iCloud folder structure
   - Write `index.json`
   - Ask if you want to add your first number
   - Do an initial export (all history available on your Mac)
3. **Scriptable widgets** can then be added to iOS home screen:
   - _iMessage Today_
   - _iMessage History_
   - _iMessage Stats_
4. **Daily exports** run automatically via launchd, refreshing the JSON files.

---

## 🖼️ Widgets

- [ ] _Placeholder for widget screenshots_  
  (Today, History, Stats)

---

## 🛠️ Settings Menu (Mac CLI)

- **Run Export** — Ad-hoc run, shows last run timestamp
- **Add New Number** — Add and configure a new contact
- **Settings**
  - Change run frequency
  - Change Python instance
  - Config summary
- **Help** — Coming soon
- **Exit**

---

## 🔧 Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues.

---

## 📚 More Info

- GitHub repository: _[placeholder link — fill after push]_  
- Author: Stephen Curtis © 2025
