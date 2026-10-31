// Generates every icon and logo file from brand/camnexo-logo-source.webp.
//   cd brand && npm install && node generate.js
const fs = require("fs");
const path = require("path");
const sharp = require("sharp");

const root = path.resolve(__dirname, "..");
const src = path.join(__dirname, "camnexo-logo-source.webp");
const DARK = "#0B0E17";

const out = (...p) => path.join(root, ...p);
const write = async (file, buf) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, buf); };

// Square, tightly cropped logo with transparent background, used as the master.
async function master() {
  const trimmed = await sharp(src).trim({ threshold: 2 }).toBuffer({ resolveWithObject: true });
  const { width: w, height: h } = trimmed.info;
  const side = Math.max(w, h);
  return sharp(trimmed.data)
    .extend({ top: Math.floor((side - h) / 2), bottom: Math.ceil((side - h) / 2), left: Math.floor((side - w) / 2), right: Math.ceil((side - w) / 2), background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png().toBuffer();
}

// The logo scaled to `fill` of a `size` square canvas, transparent background.
async function logoOnCanvas(m, size, fill) {
  const inner = Math.round(size * fill);
  const logo = await sharp(m).resize(inner, inner, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } }).png().toBuffer();
  return sharp({ create: { width: size, height: size, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: logo, gravity: "center" }]).png().toBuffer();
}

// Dark rounded tile with the logo on it. radius is a fraction of size (0.5 = circle, 0 = square).
async function tile(m, size, fill, radius) {
  const r = Math.round(size * radius);
  const bg = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}"><defs><radialGradient id="g" cx="50%" cy="35%" r="75%"><stop offset="0" stop-color="#1A2140"/><stop offset="1" stop-color="${DARK}"/></radialGradient></defs><rect width="${size}" height="${size}" rx="${r}" fill="url(#g)"/></svg>`);
  const logo = await logoOnCanvas(m, size, fill);
  return sharp(bg).composite([{ input: logo }]).png().toBuffer();
}

// Writes an .ico containing PNG images (Windows Vista and newer).
function ico(images) {
  const head = Buffer.alloc(6); head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(images.length, 4);
  let offset = 6 + images.length * 16;
  const dir = [], data = [];
  for (const { size, buf } of images) {
    const e = Buffer.alloc(16);
    e.writeUInt8(size >= 256 ? 0 : size, 0); e.writeUInt8(size >= 256 ? 0 : size, 1);
    e.writeUInt16LE(1, 4); e.writeUInt16LE(32, 6); e.writeUInt32LE(buf.length, 8); e.writeUInt32LE(offset, 12);
    dir.push(e); data.push(buf); offset += buf.length;
  }
  return Buffer.concat([head, ...dir, ...data]);
}

// White single-colour version for the Android notification bar.
function statusSvg(size) {
  const s = size;
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 96 96">
    <circle cx="48" cy="44" r="36" fill="none" stroke="#fff" stroke-width="8"/>
    <path fill="#fff" fill-rule="evenodd" d="M48 22a22 22 0 1 0 .01 0zM48 35a9 9 0 1 1-.01 0z"/>
    <rect x="30" y="82" width="36" height="8" rx="4" fill="#fff"/></svg>`);
}

(async () => {
  const m = await master();
  const meta = await sharp(m).metadata();
  console.log("master", meta.width, "x", meta.height);
  await write(path.join(__dirname, "camnexo-logo.png"), m);

  const png = (size) => sharp(m).resize(size, size).png().toBuffer();

  // ------------------------------------------------------------- Android phone app
  const res = out("apps", "mobile", "android", "app", "src", "main", "res");
  const legacy = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
  for (const [d, px] of Object.entries(legacy)) {
    await write(path.join(res, `mipmap-${d}`, "ic_launcher.png"), await tile(m, px, 0.8, 0.22));
    await write(path.join(res, `mipmap-${d}`, "ic_launcher_foreground.png"), await logoOnCanvas(m, Math.round(px * 108 / 48), 0.6));
  }
  await write(path.join(res, "values", "ic_launcher_background.xml"),
    `<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">${DARK}</color>\n</resources>\n`);
  await write(path.join(res, "mipmap-anydpi-v26", "ic_launcher.xml"),
    `<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n    <background android:drawable="@color/ic_launcher_background"/>\n    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n</adaptive-icon>\n`);
  const stat = { mdpi: 24, hdpi: 36, xhdpi: 48, xxhdpi: 72, xxxhdpi: 96 };
  for (const [d, px] of Object.entries(stat)) {
    await write(path.join(res, `drawable-${d}`, "ic_stat_camnexo.png"), await sharp(statusSvg(px)).png().toBuffer());
  }
  await write(out("apps", "mobile", "assets", "brand", "logo.png"), await png(256));
  await write(path.join(__dirname, "play-store-icon-512.png"), await sharp(await tile(m, 512, 0.8, 0)).flatten({ background: DARK }).png().toBuffer());

  // ------------------------------------------------------------ Windows desktop app
  const icoImages = [];
  for (const size of [16, 24, 32, 48, 64, 128, 256]) icoImages.push({ size, buf: await png(size) });
  await write(out("apps", "desktop", "windows", "runner", "resources", "app_icon.ico"), ico(icoImages));
  await write(out("apps", "desktop", "assets", "brand", "logo.png"), await png(256));

  // --------------------------------------------------------- macOS and iOS icon sets
  // Replace each existing image in the set with the logo at the same size.
  const sets = [
    { dir: out("apps", "desktop", "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset"), alpha: true },
    { dir: out("apps", "mobile", "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset"), alpha: false },
  ];
  for (const set of sets) {
    if (!fs.existsSync(set.dir)) continue;
    for (const f of fs.readdirSync(set.dir).filter((n) => n.endsWith(".png"))) {
      const { width } = await sharp(path.join(set.dir, f)).metadata();
      const img = set.alpha ? await logoOnCanvas(m, width, 0.84) : await sharp(await tile(m, width, 0.8, 0)).flatten({ background: DARK }).png().toBuffer();
      await write(path.join(set.dir, f), img);
      console.log("icon set", path.basename(path.dirname(path.dirname(set.dir))), f, width);
    }
  }

  // ----------------------------------------------------------------------- website
  const web = out("web", "assets");
  await write(path.join(web, "logo.png"), await png(192));
  await write(path.join(web, "favicon-32.png"), await png(32));
  await write(path.join(web, "favicon.ico"), ico(await Promise.all([16, 32, 48].map(async (size) => ({ size, buf: await png(size) })))));
  await write(path.join(web, "apple-touch-icon.png"), await sharp(await tile(m, 180, 0.8, 0)).flatten({ background: DARK }).png().toBuffer());
  await write(path.join(web, "icon-512.png"), await png(512));
  // Social preview image (1200 x 630).
  const w = 1200, h = 630;
  const bg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><defs>
    <radialGradient id="a" cx="18%" cy="10%" r="60%"><stop offset="0" stop-color="#3b82f6" stop-opacity=".45"/><stop offset="1" stop-color="#3b82f6" stop-opacity="0"/></radialGradient>
    <radialGradient id="b" cx="95%" cy="40%" r="55%"><stop offset="0" stop-color="#8b5cf6" stop-opacity=".45"/><stop offset="1" stop-color="#8b5cf6" stop-opacity="0"/></radialGradient>
    </defs><rect width="${w}" height="${h}" fill="#07090f"/><rect width="${w}" height="${h}" fill="url(#a)"/><rect width="${w}" height="${h}" fill="url(#b)"/>
    <text x="80" y="290" font-family="Segoe UI, Arial, sans-serif" font-size="92" font-weight="800" fill="#f3f5fb" letter-spacing="-3">CamNexo</text>
    <text x="84" y="365" font-family="Segoe UI, Arial, sans-serif" font-size="38" fill="#98a1b8">Use your phone as a webcam.</text>
    <text x="84" y="425" font-family="Segoe UI, Arial, sans-serif" font-size="28" fill="#6b7489">Wireless, no account, your video stays on your network.</text></svg>`);
  const big = await sharp(m).resize(430, 430).png().toBuffer();
  await write(path.join(web, "og-image.png"), await sharp(bg).composite([{ input: big, left: 700, top: 100 }]).png().toBuffer());

  console.log("done");
})().catch((e) => { console.error(e); process.exit(1); });
