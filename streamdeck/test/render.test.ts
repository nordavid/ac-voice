import { Resvg } from "@resvg/resvg-js";
import { describe, expect, it } from "vitest";
import { glyphSvg, keySvg, marketplaceSvg } from "../src/icons.js";
import type { StateMsg } from "../src/protocol.js";
import { choicesLeft, COLORS, escapeXml, faceKey, fitEnd, isAnimated, renderVoice, SIZE, textWidth, toDataUrl } from "../src/render.js";
import type { View } from "../src/view.js";

/** Parses and renders like Stream Deck would; system fonts are skipped to keep the suite fast. */
const rasterize = (svg: string) => new Resvg(svg, { font: { loadSystemFonts: false } }).render();
const NOW = 1_732_440_005_000;
const st = (phase: StateMsg["phase"], extra: Partial<StateMsg> = {}): StateMsg => ({ v: 1, t: "state", seq: 1, phase, since: NOW - 1000, ...extra });
const online = (state: StateMsg, extra: Partial<View> = {}): View => ({ link: "online", state, level: 0, ...extra });
const choices = (n: number, extra: Partial<StateMsg> = {}) =>
	st("choices", { since: NOW - 2000, deadline: NOW + 4000, choices: Array.from({ length: n }, (_, i) => ({ n: i + 1, label: `L${i + 1}` })), ...extra });

const views: Record<string, View> = {
	offline: { link: "offline", level: 0 },
	missing: { link: "offline", linkError: "App fehlt", level: 0 },
	launching: { link: "launching", level: 0 },
	onlineNoState: { link: "online", level: 0 },
	idle: online(st("idle")),
	micStarting: online(st("listening", { micReady: false })),
	listening: online(st("listening", { micReady: true }), { level: 0.6 }),
	processing: online(st("processing")),
	choices: online(choices(4), { windowStart: NOW - 2000 }),
	success: online(st("success", { message: "WWT: Website Relaunch" })),
	error: online(st("error", { message: "Nichts gehört" })),
	errorBare: online(st("error")),
};

describe("faces", () => {
	it.each(Object.entries(views))("%s renders a 144 px SVG that resvg parses", (_name, v) => {
		const svg = renderVoice(v, NOW);
		expect(svg.startsWith(`<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}"`)).toBe(true);
		expect(svg.endsWith("</svg>")).toBe(true);
		const img = rasterize(svg);
		expect([img.width, img.height]).toEqual([SIZE, SIZE]);
		expect(svg.length).toBeLessThan(3000);
	});

	it("tags every face with its name", () => {
		const face = (v: View) => /<rect id="face-([a-z-]+)"/.exec(renderVoice(v, NOW))?.[1];
		expect(Object.fromEntries(Object.entries(views).map(([k, v]) => [k, face(v)]))).toEqual({
			offline: "offline",
			missing: "missing",
			launching: "launching",
			onlineNoState: "launching",
			idle: "idle",
			micStarting: "mic-starting",
			listening: "listening",
			processing: "processing",
			choices: "choices",
			success: "success",
			error: "error",
			errorBare: "error",
		});
	});

	it.each(Object.entries(views))("%s uses only features the Stream Deck renderer supports", (_name, v) => {
		const svg = renderVoice(v, NOW);
		for (const banned of ["<filter", "<mask", "Gradient", "rgba(", "<style", "style=", "<image", "clip-path", "NaN", "undefined"]) {
			expect(svg, banned).not.toContain(banned);
		}
	});

	it("uses the overlay colors per phase", () => {
		const has = (v: View, c: string) => renderVoice(v, NOW).includes(c);
		expect(has(views.idle!, COLORS.cyan)).toBe(true);
		expect(has(views.listening!, COLORS.cyan)).toBe(true);
		expect(has(views.processing!, COLORS.violet)).toBe(true);
		expect(has(views.choices!, COLORS.amber)).toBe(true);
		expect(has(views.success!, COLORS.green)).toBe(true);
		expect(has(views.error!, COLORS.red)).toBe(true);
		expect(has(views.offline!, COLORS.cyan)).toBe(false);
		expect(has(views.offline!, COLORS.grey)).toBe(true);
	});

	it("shows minimal German captions", () => {
		expect(renderVoice(views.idle!, NOW)).toContain(">AC</text>");
		expect(renderVoice(views.offline!, NOW)).toContain(">Start</text>");
		expect(renderVoice(views.missing!, NOW)).toContain(">App fehlt</text>");
		expect(renderVoice(views.launching!, NOW)).toContain(">Startet</text>");
		expect(renderVoice(views.error!, NOW)).toContain(">Nichts gehört</text>");
		// Choices show a list glyph, not a count: the key cancels, the overlay lists the choices.
		expect(renderVoice(views.choices!, NOW)).toContain(`stroke="${COLORS.amberInk}"`);
		// Listening, processing, choices and success carry no text.
		for (const v of [views.listening!, views.processing!, views.choices!, views.success!]) expect(renderVoice(v, NOW)).not.toContain("<text");
	});

	it("shows the online-without-snapshot gap as the launching spinner, never as offline", () => {
		expect(renderVoice(views.onlineNoState!, NOW)).toBe(renderVoice(views.launching!, NOW));
	});

	it("escapes the error message", () => {
		const svg = renderVoice(online(st("error", { message: `A&B <x> "q"` })), NOW);
		expect(svg).toContain("A&amp;B &lt;x&gt; &quot;q&quot;");
		expect(() => rasterize(svg)).not.toThrow();
		expect(escapeXml("'")).toBe("&apos;");
	});

	it("truncates long captions with an ellipsis", () => {
		const s = fitEnd("Ticket 412 in WWT nicht gefunden", 15, 128);
		expect(s.endsWith("…")).toBe(true);
		expect(s.length).toBeLessThan(30);
		expect(fitEnd("Kurz", 15, 128)).toBe("Kurz");
	});

	/** The quadratic version before the review: the reference for the cut. */
	const fitEndReference = (s: string, size: number, max: number, bold = false): string => {
		const flat = s.replace(/\s+/g, " ").trim();
		if (textWidth(flat, size, bold) <= max) return flat;
		const chars = Array.from(flat);
		while (chars.length > 1 && textWidth(chars.join("") + "…", size, bold) > max) chars.pop();
		return chars.join("").trimEnd() + "…";
	};

	it("cuts exactly like the reference on mixed text, emoji and narrow glyphs", () => {
		let seed = 7;
		const rnd = () => ((seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31);
		const alphabet = ["i", "l", ".", "m", "W", "A", "7", "ö", "ß", " ", "\t", "😀", "👩‍💻", "e\u0301", "…"];
		for (let k = 0; k < 400; k++) {
			const len = Math.floor(rnd() * 120);
			const s = Array.from({ length: len }, () => alphabet[Math.floor(rnd() * alphabet.length)]).join("");
			const size = [10, 15, 18, 22][k % 4]!;
			const max = [20, 64, 128][k % 3]!;
			const bold = k % 5 === 0;
			expect(fitEnd(s, size, max, bold), JSON.stringify([s, size, max, bold])).toBe(fitEndReference(s, size, max, bold));
		}
		expect(fitEnd("i".repeat(1000), 18, 128)).toBe(fitEndReference("i".repeat(1000), 18, 128));
	});

	// Review finding 5: the app may send a message up to the 64 KB line limit; the old cut took seconds and
	// blocked every key, ping and key event of the plugin.
	it("cuts a 64 KB error message in linear time", () => {
		const long = "Fehler ".repeat(9400); // ~64 KB
		const t = performance.now();
		const s = fitEnd(long, 15, 128); // the error face's caption
		const svg = renderVoice(online(st("error", { message: long })), NOW);
		const ms = performance.now() - t;
		expect(s).toBe("Fehler Fehler…");
		expect(s).toBe(fitEndReference(long.slice(0, 200), 15, 128));
		expect(svg).toContain(">Fehler Fehler…</text>");
		expect(ms).toBeLessThan(100);
	});
});

describe("animation", () => {
	it("animates only listening, processing, launching and a running countdown", () => {
		const animated = Object.fromEntries(Object.entries(views).map(([k, v]) => [k, isAnimated(v, NOW)]));
		expect(animated).toEqual({
			offline: false,
			missing: false,
			launching: true,
			onlineNoState: true,
			idle: false,
			micStarting: true,
			listening: true,
			processing: true,
			choices: true,
			success: false,
			error: false,
			errorBare: false,
		});
		expect(isAnimated(views.choices!, NOW + 5000)).toBe(false);
		expect(isAnimated(online(choices(2, { deadline: undefined })), NOW)).toBe(false);
	});

	it("keeps static faces identical over time (painter dedupe)", () => {
		for (const k of ["offline", "missing", "idle", "success", "error"]) {
			expect(renderVoice(views[k]!, NOW), k).toBe(renderVoice(views[k]!, NOW + 12_345));
		}
	});

	it("moves animated faces over time", () => {
		for (const k of ["launching", "listening", "processing", "choices"]) {
			expect(renderVoice(views[k]!, NOW), k).not.toBe(renderVoice(views[k]!, NOW + 300));
		}
	});

	it("drives the listening rings with the level", () => {
		const quiet = renderVoice(online(st("listening", { micReady: true }), { level: 0 }), NOW);
		const loud = renderVoice(online(st("listening", { micReady: true }), { level: 1 }), NOW);
		expect(quiet).not.toBe(loud);
		const radii = (svg: string) => [...svg.matchAll(/r="([\d.]+)"/g)].map((m) => Number(m[1]));
		expect(Math.max(...radii(loud))).toBeGreaterThan(Math.max(...radii(quiet)));
	});

	it("runs the countdown from the window start to the deadline", () => {
		const v = views.choices!;
		expect(choicesLeft(v, NOW - 2000)).toBe(1);
		expect(choicesLeft(v, NOW + 1000)).toBeCloseTo(0.5);
		expect(choicesLeft(v, NOW + 9000)).toBe(0);
		expect(renderVoice(v, NOW)).not.toBe(renderVoice(v, NOW + 1000));
	});

	it("changes the face key only on face changes", () => {
		const a = faceKey(online(st("listening", { micReady: true, transcript: "Öffne" }), { level: 0.1 }));
		const b = faceKey(online(st("listening", { micReady: true, transcript: "Öffne WWT", seq: 2 }), { level: 0.9 }));
		expect(a).toBe(b);
		expect(faceKey(online(st("listening", { micReady: false })))).not.toBe(a);
		expect(faceKey(views.processing!)).not.toBe(a);
		expect(faceKey(views.offline!)).not.toBe(faceKey(views.missing!));
	});
});

describe("static images", () => {
	it("renders the icons", () => {
		for (const [svg, px] of [
			[glyphSvg(20), 20],
			[glyphSvg(56), 56],
			[marketplaceSvg(256), 256],
			[keySvg(), 144],
		] as const) {
			const img = rasterize(svg);
			expect(img.width).toBe(px);
		}
	});

	it("encodes data URLs for setImage", () => {
		const url = toDataUrl(renderVoice(views.idle!, NOW));
		expect(url.startsWith("data:image/svg+xml;charset=utf8,%3Csvg")).toBe(true);
		expect(decodeURIComponent(url.slice("data:image/svg+xml;charset=utf8,".length))).toBe(renderVoice(views.idle!, NOW));
	});
});
