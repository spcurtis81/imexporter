Absolutely — here’s the complete, ready-to-commit README.md, fully restated and verified from top to bottom ✅

⸻

📦 iMessage Exporter (imexporter)

A lightweight, privacy-friendly macOS + iOS toolkit for exporting, analysing, and visualising your personal iMessage history — right inside iCloud Drive and Scriptable widgets on your iPhone or iPad.

⸻

💡 What It Does

imexporter runs on your Mac and safely reads your local iMessage database (no external uploads).
It generates clean, per-contact JSON files that sync automatically via iCloud Drive, where your Scriptable widgets can show:
	•	📅 Daily message counts (today widget)
	•	📈 Trends over time (history widget)
	•	📊 Lifetime stats (totals, averages, records)

All of this runs locally — your data never leaves your devices.

⸻

🧰 What You’ll Need

Requirement	Purpose
macOS with Python 3	Runs the exporter CLI
iCloud Drive enabled	Syncs the JSON output to iOS
iPhone / iPad with Scriptable app	Displays widgets
Terminal access (basic use)	To install and run the app
GitHub access (optional)	To fetch updates manually


⸻

⚙️ Installing on Mac

Open Terminal and run:

curl -fsSL https://raw.githubusercontent.com/spcurtis81/imexporter/main/install_imexporter.sh \
  -o /tmp/install_imexporter.sh && \
chmod +x /tmp/install_imexporter.sh && \
/tmp/install_imexporter.sh

🧭 During installation

You’ll see:
	•	A friendly banner and progress checklist
	•	Automatic creation of folders in ~/Library/Application Support/imexporter
	•	Creation of iCloud directories at
iCloud Drive / Documents / Social / Messaging / iMessage
	•	A scan for installed Python interpreters (you’ll choose one)
	•	Download of the latest imexporter.py CLI and Scriptable templates

If any step fails, the installer clearly shows [FAILED: reason].

⸻

👥 Adding a Contact

After install, run:

imexporter

You’ll get a simple menu:

1. Run Export
2. Add New Number
3. Settings
4. Help
5. Exit

➕ Add your first contact
	•	Choose option 2
	•	Follow the on-screen instructions to enter a phone number
	•	The app will ask if you want to:
	•	Export all available messages
	•	Export the last N days
	•	Or just set up the structure (no export yet)
	•	Once complete, you’ll see the contact appear in your iCloud folder.

⸻

📁 Where Your Files Go

All data lives in iCloud Drive under:

Documents / Social / Messaging / iMessage

Each contact has its own folder, for example:

iMessage/
 ├── index.json             ← master list of contacts
 ├── _me/                   ← your own avatar and metadata
 │    └── avatar.png
 ├── +447962786922/
 │    ├── rollup.json       ← per-day message counts
 │    ├── trend_30d.json    ← cached trend data (optional)
 │    ├── meta.json         ← timestamps, stats
 │    └── avatar.png        ← contact’s image
 └── a94a8fe5d3.../
      └── (another contact)

The installer automatically creates this structure if it doesn’t exist.

⸻

🧩 Setting Up Widgets (on iOS)
	1.	Install Scriptable from the App Store.
	2.	Open Scriptable → Settings → File Bookmarks
	•	Tap ➕
	•	Browse to:
iCloud Drive / Documents / Social / Messaging / iMessage
	•	Name the bookmark: MessagesStats
	3.	Copy the three widgets from your Mac (in scriptable/):
	•	imessage_today.js
	•	imessage_trend.js
	•	imessage_stats.js
	4.	Paste them into Scriptable (Files → Scriptable folder).
	5.	Add a Medium widget to your home screen and assign one of the scripts.

That’s it — your live data should appear within seconds!

⸻

🪞 Avatars

Each person can have a circular avatar image (PNG recommended).
Store them here:

iCloud Drive / Documents / Social / Messaging / iMessage / <number> / avatar.png

Your own avatar lives in:

iCloud Drive / Documents / Social / Messaging / iMessage / _me / avatar.png

If no avatar is found, the widgets draw a clean initials-based placeholder automatically.

⸻

⚙️ Settings Menu

Run imexporter and choose option 3 (Settings) to:
	•	Change update frequency (default 30 minutes)
	•	Rescan Python interpreters
	•	View a Config Summary, showing:
	•	Python instance path
	•	Full Disk Access (FDA) status for required services
	•	Current refresh interval
	•	Contact list and data locations

⸻

🔄 Updating the App

You can safely update any time:

cd ~/Documents/Coding/Projects/imexporter
git pull

Then re-run the installer to ensure dependencies are aligned:

./install_imexporter.sh

This preserves your existing data and contacts.

⸻

🧹 Uninstalling

If you ever want to remove imexporter completely:

# Remove app and data folders
rm -rf ~/Library/Application\ Support/imexporter
rm -f ~/Library/LaunchAgents/com.ste.imexporter.plist
rm -f ~/Library/Logs/imexporter*.log

# (Optional) Remove iCloud data
rm -rf ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/Social/Messaging/iMessage

Your message database on your Mac remains untouched.

⸻

🧾 Need Help?
	•	💬 GitHub: spcurtis81/imexporter
	•	📧 Issues: please include the install log (from Terminal)
	•	📘 Wiki: coming soon — will include sample widgets & screenshots

⸻

✅ You’re All Set!

Your Mac now keeps your iMessage stats in sync automatically,
and your iPhone widgets keep them beautifully visualised.

Enjoy your new iMessage insights!

⸻

Would you like me to append a Troubleshooting appendix next (covering permissions, FDA, Scriptable setup, and widget sync issues)?
It would appear right after the “Need Help?” section — ideal for first-time or non-technical users.