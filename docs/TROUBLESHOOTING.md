# Troubleshooting — iMessage Exporter

---

## ❌ Common Errors

### 1. `sqlite3.OperationalError: unable to open database file`
- Cause: Python does not have **Full Disk Access**.
- Fix: System Settings → Privacy & Security → Full Disk Access. Add:
  - Terminal (or iTerm, etc.)
  - Python (`/opt/homebrew/bin/python3`)
  - Your editor if it runs scripts.

---

### 2. Scriptable widget shows “Rollup not found”
- Cause: Bookmark not set in Scriptable.
- Fix:
  1. Open Scriptable → Settings → File Bookmarks
  2. Add a bookmark pointing to `iCloud Drive / Documents / Social / Messaging / iMessage`
  3. Set the bookmark name to **`MessagesStats`**

---

### 3. Widget updates slowly
- Cause: iCloud Drive sync lag.
- Fix: Ensure iCloud sync is enabled on both Mac and iOS. Sometimes toggling “Optimize Mac Storage” can help.

---

### 4. First run doesn’t show old messages
- Only messages already downloaded to your Mac are included.
- Messages that exist only in iCloud (but not yet synced to your Mac) won’t appear until they’re cached locally.

---

## 🔍 Debugging Checklist

- [ ] Folder structure exists in iCloud (`Documents/Social/Messaging/iMessage`)
- [ ] `index.json` contains your contact(s)
- [ ] `rollup.json` is updating when exports run
- [ ] Scriptable bookmark points at the right folder
- [ ] Full Disk Access is granted to Python/Terminal

---

## 📝 Still stuck?

Open an issue on GitHub with:
- macOS version
- Python version
- Error output
- Screenshot if relevant
