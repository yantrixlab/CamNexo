// Draws the ready-made background pictures (1920 x 1080 JPEG) used by the desktop app's Effects panel.
//   cd brand && npm install && node generate-backgrounds.js
const fs = require("fs");
const path = require("path");
const sharp = require("sharp");

const out = path.resolve(__dirname, "..", "apps", "desktop", "assets", "backgrounds");
fs.mkdirSync(out, { recursive: true });

const W = 1920, H = 1080;

// A soft blob: a blurred circle.
const blob = (x, y, r, color, opacity) =>
  `<circle cx="${x}" cy="${y}" r="${r}" fill="${color}" opacity="${opacity}" filter="url(#b)"/>`;

function svg(defs, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs><filter id="b" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="70"/></filter>
  <filter id="s" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="22"/></filter>${defs}</defs>${body}</svg>`;
}

const linear = (id, stops, x2 = 1, y2 = 1) =>
  `<linearGradient id="${id}" x1="0" y1="0" x2="${x2}" y2="${y2}">${stops.map(([o, c]) => `<stop offset="${o}" stop-color="${c}"/>`).join("")}</linearGradient>`;

const designs = {
  aurora: svg(linear("g", [[0, "#0f172a"], [0.5, "#312e81"], [1, "#0e7490"]]),
    `<rect width="${W}" height="${H}" fill="url(#g)"/>` + blob(400, 300, 380, "#38bdf8", 0.5) + blob(1500, 250, 420, "#a78bfa", 0.5) +
    blob(1100, 900, 460, "#2dd4bf", 0.42) + blob(250, 950, 300, "#818cf8", 0.4)),
  sunset: svg(linear("g", [[0, "#7c2d12"], [0.45, "#db2777"], [1, "#4c1d95"]], 0.3, 1),
    `<rect width="${W}" height="${H}" fill="url(#g)"/>` + blob(1450, 330, 380, "#fbbf24", 0.6) + blob(380, 260, 340, "#fb7185", 0.45) +
    blob(900, 950, 480, "#f97316", 0.35)),
  ocean: svg(linear("g", [[0, "#082f49"], [0.55, "#0369a1"], [1, "#0f766e"]], 0.2, 1),
    `<rect width="${W}" height="${H}" fill="url(#g)"/>` + blob(300, 220, 360, "#7dd3fc", 0.4) + blob(1600, 700, 460, "#5eead4", 0.38) +
    blob(900, 1000, 420, "#38bdf8", 0.35)),
  forest: svg(linear("g", [[0, "#052e16"], [0.6, "#166534"], [1, "#365314"]]),
    `<rect width="${W}" height="${H}" fill="url(#g)"/>` + blob(350, 280, 320, "#86efac", 0.35) + blob(1500, 300, 380, "#bef264", 0.3) +
    blob(1000, 950, 440, "#4ade80", 0.28) + blob(1750, 880, 200, "#fde68a", 0.3)),
  graphite: svg(`<radialGradient id="g" cx="50%" cy="40%" r="80%"><stop offset="0" stop-color="#3f3f46"/><stop offset="1" stop-color="#0a0a0c"/></radialGradient>`,
    `<rect width="${W}" height="${H}" fill="url(#g)"/>` + blob(1600, 200, 300, "#94a3b8", 0.12) + blob(300, 900, 340, "#64748b", 0.12)),
  studio: svg(`<radialGradient id="g" cx="50%" cy="35%" r="75%"><stop offset="0" stop-color="#f4f4f5"/><stop offset="0.6" stop-color="#d4d4d8"/><stop offset="1" stop-color="#71717a"/></radialGradient>`,
    `<rect width="${W}" height="${H}" fill="url(#g)"/><rect x="0" y="840" width="${W}" height="240" fill="#52525b" opacity="0.35" filter="url(#s)"/>`),
  office: svg(linear("g", [[0, "#e7e0d6"], [1, "#c9bfae"]], 0, 1),
    `<rect width="${W}" height="${H}" fill="url(#g)"/>` +
    // shelves and objects, blurred like they are out of focus
    `<g filter="url(#s)"><rect x="80" y="170" width="520" height="22" fill="#8b6f4e"/><rect x="80" y="430" width="520" height="22" fill="#8b6f4e"/>
     <rect x="120" y="70" width="60" height="100" fill="#b45309"/><rect x="190" y="95" width="48" height="75" fill="#1d4ed8"/><rect x="250" y="60" width="70" height="110" fill="#65a30d"/>
     <rect x="360" y="110" width="110" height="60" fill="#be185d"/><rect x="130" y="330" width="90" height="100" fill="#0f766e"/><rect x="240" y="350" width="70" height="80" fill="#a16207"/>
     <circle cx="470" cy="385" r="48" fill="#7c3aed" opacity="0.8"/><rect x="1180" y="120" width="560" height="560" rx="18" fill="#f8fafc" opacity="0.85"/>
     <rect x="1215" y="155" width="490" height="490" rx="8" fill="#93c5fd" opacity="0.55"/><circle cx="1500" cy="820" r="110" fill="#16a34a" opacity="0.55"/></g>` +
    blob(900, 120, 300, "#fff7ed", 0.7)),
  paper: svg(`<radialGradient id="g" cx="50%" cy="40%" r="80%"><stop offset="0" stop-color="#fffdf7"/><stop offset="1" stop-color="#e8e0d0"/></radialGradient>`,
    `<rect width="${W}" height="${H}" fill="url(#g)"/>` + blob(1500, 300, 280, "#fde68a", 0.25) + blob(350, 800, 320, "#fbcfe8", 0.22)),
};

(async () => {
  for (const [name, markup] of Object.entries(designs)) {
    const file = path.join(out, `${name}.jpg`);
    await sharp(Buffer.from(markup)).jpeg({ quality: 86, mozjpeg: true }).toFile(file);
    console.log(name, (fs.statSync(file).size / 1024).toFixed(0) + " KB");
  }
})().catch((e) => { console.error(e); process.exit(1); });
