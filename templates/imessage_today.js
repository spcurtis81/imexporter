/**
 * iMessage Today — Daily DM Widget
 * Auto-refreshes iCloud files before reading rollups to reduce staleness on iOS.
 */

const CFG = {
  bookmarkName: "MessagesStats",

  // If blank or placeholder, script auto-selects first enabled contact from index.json
  contactId: "", // e.g. "+447962786922"

  people: [
    { key: "me",   label: "Ste",  placeholderBg: "#2ecc71" },
    { key: "them", label: "Kate", placeholderBg: "#27ae60" },
  ],

  gradient: { colors: ["#7ed957", "#28a745"], locations: [0, 1], angle: 135 },
  titleIcon: "calendar",
  titleText: "iMessage Today",
  textColor: Color.white(),

  avatarSize: 56,
  nameSize: 16,
  scoreSize: 48,
  titleSize: 16,
  footerSize: 11,

  padTop: 12, padLeft: 24, padBottom: 12, padRight: 24,

  titleGap: 8,
  titleLeftInset: 25,
  titleRightInset: 12,

  nameGap: 6,
  innerGap: 10,

  halfWidth: 170,

  footerBiasPx: 0,

  refreshMinutes: 30,
};

// ─────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────
function fontWith(size, weight){
  switch((weight||"").toLowerCase()){
    case "heavy": return Font.heavySystemFont(size);
    case "bold": return Font.boldSystemFont(size);
    case "semibold": return Font.semiboldSystemFont(size);
    default: return Font.systemFont(size);
  }
}

function todayKey(){
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;
}

function fmtDate(dt){
  if(!dt) return "";
  const y=dt.getFullYear(), m=String(dt.getMonth()+1).padStart(2,"0"), d=String(dt.getDate()).padStart(2,"0");
  const H=String(dt.getHours()).padStart(2,"0"), M=String(dt.getMinutes()).padStart(2,"0");
  return `${y}-${m}-${d} ${H}:${M}`;
}

function initialsFor(name){
  return (name||"?").split(/\s+/).map(s=>s?.[0]?.toUpperCase?.()||"").slice(0,2).join("") || "?";
}

function circleAvatar({text, diameter, bgHex, fg=Color.white()}){
  const ctx = new DrawContext();
  ctx.size = new Size(diameter, diameter);
  ctx.opaque = false;
  ctx.respectScreenScale = true;

  const p = new Path();
  p.addEllipse(new Rect(0,0,diameter,diameter));
  ctx.setFillColor(new Color(bgHex));
  ctx.addPath(p);
  ctx.fillPath();

  const f = Font.semiboldSystemFont(Math.round(diameter*0.44));
  ctx.setFont(f);
  ctx.setTextColor(fg);
  ctx.setTextAlignedCenter();

  const y = Math.round(diameter/2 - f.pointSize/2 + 4);
  ctx.drawTextInRect(text, new Rect(0,y,diameter,f.pointSize+6));
  return ctx.getImage();
}

function isPlaceholderContactId(id){
  if(!id) return true;
  const s = String(id).trim();
  return s === "" || s.includes("PHONE_NUMBER") || s.includes("<<") || s.includes(">>");
}

// ─────────────────────────────────────────────────────────────
// iCloud paths + contact resolution
// ─────────────────────────────────────────────────────────────
async function resolveRootAndIndex(){
  const fm = FileManager.iCloud();
  if(!fm.bookmarkExists(CFG.bookmarkName)){
    throw new Error(`Bookmark "${CFG.bookmarkName}" not found.\nCreate it in Scriptable → Settings → File Bookmarks.\nIt should point at your iMessage folder containing index.json.`);
  }
  const root = fm.bookmarkedPath(CFG.bookmarkName);
  const indexPath = fm.joinPath(root, "index.json");

  if(!fm.fileExists(indexPath)){
    throw new Error(`index.json not found in bookmarked folder.\nBookmark points to:\n${root}\n\nYour bookmark should point to the folder that contains index.json.`);
  }

  // Download + read index.json (sync poke + parse)
  await fm.downloadFileFromiCloud(indexPath);
  const indexRaw = fm.readString(indexPath);
  let index;
  try { index = JSON.parse(indexRaw); }
  catch { throw new Error("index.json exists but is not valid JSON."); }

  return { fm, root, indexPath, index };
}

function pickContactIdFromIndex(index){
  const contacts = Array.isArray(index?.contacts) ? index.contacts : [];
  const enabled = contacts.filter(c => c && (c.enabled === undefined || c.enabled === true));

  // New schema: { number, label, enabled }
  const c1 = enabled.find(c => c.number);
  if (c1?.number) return c1.number;

  // Old schema: { id, path, displayName, ... }
  const c2 = enabled.find(c => c.id);
  if (c2?.id) return c2.id;

  return null;
}

function listLikelyContactFolders(fm, root){
  // Not perfect, but helpful: list directory names at root that look like +44...
  try {
    const items = fm.listContents(root) || [];
    return items
      .filter(n => n && n.startsWith("+")) // your folder style
      .slice(0, 20);
  } catch {
    return [];
  }
}

async function buildPathsForContact({ fm, root, contactId }){
  const contactDir = fm.joinPath(root, contactId);
  const rollupPath = fm.joinPath(contactDir, "rollup.json");
  const meAvatarPath = fm.joinPath(fm.joinPath(root, "_me"), "avatar.png");
  const themAvatarPath = fm.joinPath(contactDir, "avatar.png");
  return { contactDir, rollupPath, meAvatarPath, themAvatarPath };
}

// ─────────────────────────────────────────────────────────────
// iCloud “prefetch poke” (safe)
/// ─────────────────────────────────────────────────────────────
async function safeDownload(fm, path){
  // Avoid "Cannot download ... because file does not exist"
  if(!fm.fileExists(path)) return false;
  await fm.downloadFileFromiCloud(path);
  return true;
}

async function prefetchIcloudFiles({ fm, indexPath, rollupPath, meAvatarPath, themAvatarPath }){
  // Keep it light and safe
  await safeDownload(fm, indexPath);
  await safeDownload(fm, rollupPath);
  await safeDownload(fm, meAvatarPath);
  await safeDownload(fm, themAvatarPath);
}

async function loadRollup(rollupPath, fm, contactId, root){
  if(!fm.fileExists(rollupPath)){
    const options = listLikelyContactFolders(fm, root);
    const hint = options.length ? `\n\nContact folders I can see:\n- ${options.join("\n- ")}` : "";
    throw new Error(
      `rollup.json not found for contact "${contactId}".\nExpected:\n${rollupPath}\n\nThis usually means CFG.contactId is wrong, or the exporter hasn't created rollup.json yet.${hint}`
    );
  }

  await fm.downloadFileFromiCloud(rollupPath);
  const raw = fm.readString(rollupPath);
  if (!raw) throw new Error("rollup.json is empty.");
  const json = JSON.parse(raw);
  const mtime = fm.modificationDate(rollupPath);
  return { json, mtime };
}

async function loadAvatarByPath(path, fallbackText, bgHex, fm){
  try{
    if (fm.fileExists(path)){
      await fm.downloadFileFromiCloud(path);
      const img = fm.readImage(path);
      if (img) return img;
    }
  }catch(_) {}
  return circleAvatar({ text: initialsFor(fallbackText), diameter: CFG.avatarSize, bgHex });
}

// ─────────────────────────────────────────────────────────────
// UI helpers (unchanged)
/// ─────────────────────────────────────────────────────────────
function addHalf(container, {name, avatarImg, score, dir="L"}, halfWidth){
  const half = container.addStack();
  half.layoutHorizontally();
  half.centerAlignContent();
  half.size = new Size(halfWidth, 0);

  const makeMini = () => {
    const mini = half.addStack();
    mini.layoutVertically(); mini.centerAlignContent();
    mini.size = new Size(CFG.avatarSize, 0);

    const av = mini.addImage(avatarImg);
    av.imageSize = new Size(CFG.avatarSize, CFG.avatarSize);
    av.cornerRadius = CFG.avatarSize/2;

    mini.addSpacer(CFG.nameGap);

    const nm = mini.addText(name);
    nm.font = fontWith(CFG.nameSize, "semibold");
    nm.textColor = CFG.textColor;
    nm.textOpacity = 0.95;
    nm.centerAlignText();
    nm.size = new Size(CFG.avatarSize, 0);
  };

  const makeScore = () => {
    const col = half.addStack(); col.layoutVertically(); col.centerAlignContent();
    const sc = col.addText(String(score));
    sc.font = fontWith(CFG.scoreSize, "heavy");
    sc.textColor = CFG.textColor;
    sc.lineLimit = 1;
    sc.minimumScaleFactor = 0.6;
  };

  if (dir === "L") { makeMini(); half.addSpacer(CFG.innerGap); makeScore(); }
  else            { makeScore(); half.addSpacer(CFG.innerGap); makeMini(); }
}

function addTitleRow(widget){
  const row = widget.addStack(); row.layoutHorizontally();

  const content = row.addStack();
  content.layoutHorizontally(); content.centerAlignContent();
  content.setPadding(0, CFG.titleLeftInset, 0, CFG.titleRightInset);

  const iconImg = SFSymbol.named(CFG.titleIcon).image;
  const icon = content.addImage(iconImg);
  icon.imageSize = new Size(16,16);
  icon.tintColor = CFG.textColor;

  content.addSpacer(8);
  const label = content.addText(CFG.titleText);
  label.font = fontWith(CFG.titleSize, "semibold");
  label.textColor = CFG.textColor;
  label.textOpacity = 0.96;

  row.addSpacer();
}

function addScoresRow(widget, left, right, scoreLeft, scoreRight, halfWidth){
  const mid = widget.addStack();
  mid.layoutHorizontally(); mid.centerAlignContent();

  mid.addSpacer();
  addHalf(mid, { name:left.name,  avatarImg:left.avatar,  score:scoreLeft,  dir:"L" }, halfWidth);
  mid.addSpacer();
  addHalf(mid, { name:right.name, avatarImg:right.avatar, score:scoreRight, dir:"R" }, halfWidth);
  mid.addSpacer();
}

function addFooterRow(widget, updatedText){
  const row = widget.addStack(); row.layoutHorizontally();

  if (CFG.footerBiasPx >= 0) {
    row.addSpacer();
    if (CFG.footerBiasPx) row.addSpacer(CFG.footerBiasPx);
  } else {
    row.addSpacer(Math.abs(CFG.footerBiasPx));
    row.addSpacer();
  }

  const foot = row.addText(`Updated: ${updatedText || ""}`);
  foot.font = Font.italicSystemFont(CFG.footerSize);
  foot.textColor = new Color("#ffffff", 0.88);
  foot.centerAlignText();

  row.addSpacer();
}

function buildWidget({ left, right, scoreLeft, scoreRight, updatedText }){
  const w = new ListWidget();
  w.setPadding(CFG.padTop, CFG.padLeft, CFG.padBottom, CFG.padRight);

  const grad = new LinearGradient();
  grad.colors = CFG.gradient.colors.map(hex => new Color(hex));
  grad.locations = CFG.gradient.locations;
  grad.angle = CFG.gradient.angle;
  w.backgroundGradient = grad;

  addTitleRow(w);
  w.addSpacer(CFG.titleGap);

  addScoresRow(w, left, right, scoreLeft, scoreRight, CFG.halfWidth);

  w.addSpacer();
  addFooterRow(w, updatedText);

  w.refreshAfterDate = new Date(Date.now() + CFG.refreshMinutes*60*1000);
  return w;
}

// ─────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────
async function run(){
  try{
    const { fm, root, indexPath, index } = await resolveRootAndIndex();

    // Resolve contactId (auto if blank)
    let contactId = CFG.contactId;
    if (isPlaceholderContactId(contactId)) {
      const picked = pickContactIdFromIndex(index);
      if (!picked) {
        throw new Error(`No usable contacts found in index.json.\nMake sure your exporter has added at least one enabled contact.`);
      }
      contactId = picked;
    }

    const { rollupPath, meAvatarPath, themAvatarPath } = await buildPathsForContact({ fm, root, contactId });

    // iCloud prefetch poke (safe)
    await prefetchIcloudFiles({ fm, indexPath, rollupPath, meAvatarPath, themAvatarPath });

    const { json, mtime } = await loadRollup(rollupPath, fm, contactId, root);

    const k = todayKey();
    const today = (json && json.days && json.days[k]) || { me:0, them:0 };

    const leftScore  = Number.isFinite(today.me)   ? today.me   : 0;
    const rightScore = Number.isFinite(today.them) ? today.them : 0;

    const updated = (json && json.updated_at)
      ? json.updated_at.replace("T"," ").slice(0,16)
      : fmtDate(mtime);

    const leftAvatar  = await loadAvatarByPath(meAvatarPath,  CFG.people[0].label, CFG.people[0].placeholderBg,  fm);
    const rightAvatar = await loadAvatarByPath(themAvatarPath, CFG.people[1].label, CFG.people[1].placeholderBg, fm);

    const widget = buildWidget({
      left:  { name: CFG.people[0].label, avatar: leftAvatar },
      right: { name: CFG.people[1].label, avatar: rightAvatar },
      scoreLeft: leftScore,
      scoreRight: rightScore,
      updatedText: updated
    });

    Script.setWidget(widget);
    if (config.runsInApp) await widget.presentMedium();
  } catch (err){
    const w = new ListWidget();
    w.backgroundColor = new Color("#222");
    const t = w.addText("iMessage Today");
    t.font = Font.semiboldSystemFont(14);
    t.textColor = Color.white();

    w.addSpacer(6);

    const e = w.addText(String(err));
    e.font = Font.systemFont(12);
    e.textColor = Color.red();
    e.minimumScaleFactor = 0.6;
    e.lineLimit = 6;

    Script.setWidget(w);
    if (config.runsInApp) await w.presentMedium();
  }
  Script.complete();
}

await run();