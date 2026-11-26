/**
 * Renders the plugin's static images as PNG (1x and @2x) and preview/gallery.png with every key face.
 *   npm run icons
 * Sizes follow the manifest schema: plugin icon 256, category icon 28, action icon 20, key 72 (each plus @2x).
 */
import { Resvg } from "@resvg/resvg-js";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { glyphSvg, keySvg, marketplaceSvg } from "../src/icons.js";
import type { StateMsg } from "../src/protocol.js";
import { renderVoice } from "../src/render.js";
import type { View } from "../src/view.js";

const root = path.resolve(import.meta.dirname, "..");
const sd = path.join(root, "io.github.nordavid.acvoice.streamdeck.sdPlugin");

function png(svg: string, width: number): Buffer {
	return new Resvg(svg, { fitTo: { mode: "width", value: width }, font: { loadSystemFonts: true } }).render().asPng();
}

function write(file: string, data: Buffer): void {
	mkdirSync(path.dirname(file), { recursive: true });
	writeFileSync(file, data);
	console.log(`wrote ${path.relative(root, file)} (${data.length} bytes)`);
}

/** Writes name.png at `size` and name@2x.png at twice the size. */
function pair(rel: string, svg: (px: number) => string, size: number): void {
	write(path.join(sd, `${rel}.png`), png(svg(size), size));
	write(path.join(sd, `${rel}@2x.png`), png(svg(size * 2), size * 2));
}

pair("imgs/plugin/marketplace", marketplaceSvg, 256);
pair("imgs/plugin/category-icon", glyphSvg, 28);
pair("imgs/actions/voice/icon", glyphSvg, 20);
pair("imgs/actions/voice/key", () => keySvg(), 72);

// Gallery of all faces for a visual check without hardware.
const now = 1_732_440_005_000;
const st = (phase: StateMsg["phase"], extra: Partial<StateMsg> = {}): StateMsg => ({ v: 1, t: "state", seq: 1, phase, since: now - 1000, ...extra });
const online = (state: StateMsg, extra: Partial<View> = {}): View => ({ link: "online", state, level: 0, ...extra });
const choices = st("choices", {
	since: now - 2000,
	deadline: now + 3000,
	choices: [1, 2, 3, 4].map((n) => ({ n, label: `Wahl ${n}` })),
});
const faces: { label: string; svg: string }[] = [
	{ label: "offline", svg: renderVoice({ link: "offline", level: 0 }, now) },
	{ label: "app missing", svg: renderVoice({ link: "offline", linkError: "App fehlt", level: 0 }, now) },
	{ label: "launching", svg: renderVoice({ link: "launching", level: 0 }, now) },
	{ label: "idle", svg: renderVoice(online(st("idle")), now) },
	{ label: "listening (mic starting)", svg: renderVoice(online(st("listening", { micReady: false })), now) },
	{ label: "listening, quiet", svg: renderVoice(online(st("listening", { micReady: true }), { level: 0.05 }), now) },
	{ label: "listening, loud", svg: renderVoice(online(st("listening", { micReady: true }), { level: 0.9 }), now + 300) },
	{ label: "processing", svg: renderVoice(online(st("processing")), now) },
	{ label: "choices, 60 % left", svg: renderVoice(online(choices, { windowStart: now - 2000 }), now) },
	{ label: "choices, 10 % left", svg: renderVoice(online(choices, { windowStart: now - 2000 }), now + 2500) },
	{ label: "success", svg: renderVoice(online(st("success", { message: "WWT: Website Relaunch" })), now) },
	{ label: "error", svg: renderVoice(online(st("error")), now) },
	{ label: "error + message", svg: renderVoice(online(st("error", { message: "Nichts gehört" })), now) },
];
const cols = 5;
const cell = 160;
const rows = Math.ceil(faces.length / cols);
const gallery =
	`<svg xmlns="http://www.w3.org/2000/svg" width="${cols * cell}" height="${rows * (cell + 24)}"><rect width="100%" height="100%" fill="#202227"/>` +
	faces
		.map((k, i) => {
			const x = (i % cols) * cell + 8;
			const y = Math.floor(i / cols) * (cell + 24) + 8;
			const inner = k.svg.replace(/^<svg[^>]*>/, "").replace(/<\/svg>$/, "");
			return `<g transform="translate(${x},${y})"><svg width="144" height="144" viewBox="0 0 144 144">${inner}</svg><text x="72" y="164" font-family="Helvetica" font-size="12" fill="#cccccc" text-anchor="middle">${k.label}</text></g>`;
		})
		.join("") +
	`</svg>`;
write(path.join(root, "preview", "gallery.png"), png(gallery, cols * cell));
console.log(`${faces.length} faces in preview/gallery.png`);
