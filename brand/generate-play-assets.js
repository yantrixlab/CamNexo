// Draws the Google Play feature graphic (1024 x 500) from the logo.
//   cd brand && npm install && node generate-play-assets.js
const path = require("path");
const sharp = require("sharp");

const out = path.resolve(__dirname, "..", "docs", "play-store", "graphics", "feature-graphic-1024x500.png");
const W = 1024, H = 500;

(async () => {
  const logo = await sharp(path.join(__dirname, "camnexo-logo.png")).resize(300, 300).png().toBuffer();
  const bg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><defs>
    <radialGradient id="a" cx="15%" cy="0%" r="70%"><stop offset="0" stop-color="#3b82f6" stop-opacity=".5"/><stop offset="1" stop-color="#3b82f6" stop-opacity="0"/></radialGradient>
    <radialGradient id="b" cx="95%" cy="50%" r="60%"><stop offset="0" stop-color="#8b5cf6" stop-opacity=".5"/><stop offset="1" stop-color="#8b5cf6" stop-opacity="0"/></radialGradient>
  </defs><rect width="${W}" height="${H}" fill="#07090f"/><rect width="${W}" height="${H}" fill="url(#a)"/><rect width="${W}" height="${H}" fill="url(#b)"/>
  <text x="64" y="215" font-family="Segoe UI, Arial, sans-serif" font-size="78" font-weight="800" fill="#f3f5fb" letter-spacing="-2">CamNexo</text>
  <text x="68" y="285" font-family="Segoe UI, Arial, sans-serif" font-size="34" fill="#c7d2fe">Your phone is the best webcam you own</text>
  <text x="68" y="340" font-family="Segoe UI, Arial, sans-serif" font-size="24" fill="#8e97ae">Wireless. No account. Works in Zoom, Meet, Teams and OBS.</text></svg>`);
  await sharp(bg).composite([{ input: logo, left: 680, top: 100 }]).png().toFile(out);
  console.log("wrote", out);
})().catch((e) => { console.error(e); process.exit(1); });
