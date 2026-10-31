// Serves the camera test page on http://localhost:5173 (localhost counts as a secure context,
// which getUserMedia requires). Usage: node tools/webcam-test/serve.js
const http = require('http');
const fs = require('fs');
const path = require('path');

const page = path.join(__dirname, 'index.html');
http
  .createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(fs.readFileSync(page));
  })
  .listen(5173, () => console.log('CamNexo camera test on http://localhost:5173'));
