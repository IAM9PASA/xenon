// Renders the Xenon logo SVGs to PNG with resvg (borrowed from tools/hud_art).
// Usage: node assets/render_logo.js
const fs = require("fs");
const path = require("path");
const { Resvg } = require("D:/coding/roblox work/tools/hud_art/node_modules/@resvg/resvg-js");

const dir = __dirname;
const jobs = [
	["xenon_logo.svg", "xenon_logo_512.png", 512],
	["xenon_logo.svg", "xenon_logo_256.png", 256],
	["xenon_icon.svg", "xenon_icon_32.png", 32],
];

for (const [src, out, size] of jobs) {
	const svg = fs.readFileSync(path.join(dir, src), "utf8");
	const png = new Resvg(svg, { fitTo: { mode: "width", value: size }, background: "rgba(0,0,0,0)" }).render().asPng();
	fs.writeFileSync(path.join(dir, out), png);
	console.log(`${out} (${size}px, ${png.length} bytes)`);
}
