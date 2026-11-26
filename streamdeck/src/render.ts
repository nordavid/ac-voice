/**
 * Key faces as SVG strings at 144 x 144 (the @2x key size), pure functions of (view, now).
 * Same visual language as the overlay orb: cyan listening, violet processing, amber choices,
 * green success, red error, grey when the app is down.
 *
 * Stream Deck's SVG renderer is limited: basic shapes, paths, text and solid colors with opacity
 * attributes. No filters, masks, gradients, CSS or rgba(). The glow is faked with stacked discs.
 * Animated faces quantize time so the painter's dedupe works and frames stay small (~1-2 KB).
 */
import type { View } from "./view.js";

export const SIZE = 144;
const CX = 72;
const CY = 72;
/** Orb center when a caption sits below it. */
const CY_CAPTION = 62;
const FONT = "SF Pro Display, Helvetica Neue, Helvetica, Arial, sans-serif";

export const COLORS = {
	bg: "#06080B",
	ink: "#F2F4F7",
	dim: "#8A94A1",
	grey: "#4A535F",
	faint: "#262D36",
	cyan: "#3FD0FF",
	violet: "#A57CFF",
	amber: "#FFB547",
	amberInk: "#1F1505",
	green: "#3DDC84",
	red: "#FF5C5C",
} as const;

/** German captions on the key. Kept to one or two words. */
export const KEY_TEXT = {
	brand: "AC",
	start: "Start",
	starting: "Startet",
	appMissing: "App fehlt",
} as const;

/** Rotation speed of spinners and the processing arc, degrees per second. */
const SPIN_DEG_PER_S = 300;
/** Listening ripples per second. */
const RIPPLE_HZ = 0.9;

// ---------- primitives ----------

const r1 = (x: number) => Math.round(x * 10) / 10;
const r2 = (x: number) => Math.round(x * 100) / 100;
const clamp01 = (x: number) => Math.max(0, Math.min(1, x));

export function escapeXml(s: string): string {
	return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

/** Advance of the narrowest glyph in `textWidth`, in em. */
const NARROWEST_EM = 0.3;

/** Rough advance width for truncation; the key font is not measurable here. */
export function textWidth(s: string, size: number, bold = false): number {
	let w = 0;
	for (const ch of s) {
		if ("il.,:;|!'`".includes(ch)) w += NARROWEST_EM;
		else if ("mwMW@%".includes(ch)) w += 0.88;
		else if (ch >= "A" && ch <= "Z") w += 0.66;
		else if (ch >= "0" && ch <= "9") w += 0.58;
		else w += 0.55;
	}
	return w * size * (bold ? 1.06 : 1);
}

/**
 * Truncates at the end with an ellipsis ("Ticket nicht gef…"). Linear in the input: the app's message may be
 * up to 64 KB, and only the first `max / narrowest glyph` characters can ever fit.
 */
export function fitEnd(s: string, size: number, max: number, bold = false): string {
	const flat = s.replace(/\s+/g, " ").trim();
	if (textWidth(flat, size, bold) <= max) return flat;
	const fits = Math.max(1, Math.floor(max / (NARROWEST_EM * size)) + 1);
	const chars = Array.from(flat.slice(0, 2 * fits)).slice(0, fits);
	while (chars.length > 1 && textWidth(chars.join("") + "…", size, bold) > max) chars.pop();
	return chars.join("").trimEnd() + "…";
}

interface Paint {
	fill?: string;
	fillOpacity?: number;
	stroke?: string;
	strokeWidth?: number;
	strokeOpacity?: number;
}

function paintAttrs(p: Paint): string {
	let a = ` fill="${p.fill ?? "none"}"`;
	if (p.fill && p.fillOpacity !== undefined && p.fillOpacity < 1) a += ` fill-opacity="${r2(p.fillOpacity)}"`;
	if (p.stroke) {
		a += ` stroke="${p.stroke}" stroke-width="${r1(p.strokeWidth ?? 1)}"`;
		if (p.strokeOpacity !== undefined && p.strokeOpacity < 1) a += ` stroke-opacity="${r2(p.strokeOpacity)}"`;
	}
	return a;
}

function circle(cx: number, cy: number, r: number, p: Paint): string {
	return `<circle cx="${r1(cx)}" cy="${r1(cy)}" r="${r1(Math.max(0, r))}"${paintAttrs(p)}/>`;
}

function polar(cx: number, cy: number, r: number, deg: number): [number, number] {
	const rad = ((deg - 90) * Math.PI) / 180;
	return [r2(cx + r * Math.cos(rad)), r2(cy + r * Math.sin(rad))];
}

/** Clockwise arc, 0 deg = 12 o'clock. */
function arc(cx: number, cy: number, r: number, from: number, to: number, color: string, width: number, opacity = 1): string {
	const sweep = to - from;
	if (sweep <= 0.5) return "";
	if (sweep >= 359.5) return circle(cx, cy, r, { stroke: color, strokeWidth: width, strokeOpacity: opacity });
	const [sx, sy] = polar(cx, cy, r, from);
	const [ex, ey] = polar(cx, cy, r, to);
	const op = opacity < 1 ? ` stroke-opacity="${r2(opacity)}"` : "";
	return `<path d="M ${sx} ${sy} A ${r} ${r} 0 ${sweep > 180 ? 1 : 0} 1 ${ex} ${ey}" fill="none" stroke="${color}" stroke-width="${width}" stroke-linecap="round"${op}/>`;
}

function text(x: number, y: number, s: string, size: number, fill: string, bold = false, opacity = 1): string {
	const op = opacity < 1 ? ` fill-opacity="${r2(opacity)}"` : "";
	return `<text x="${x}" y="${y}" font-family="${FONT}" font-size="${size}" font-weight="${bold ? "bold" : "normal"}" fill="${fill}" text-anchor="middle"${op}>${escapeXml(s)}</text>`;
}

function caption(s: string, color: string, size = 18): string {
	return text(CX, 131, fitEnd(s, size, 128), size, color);
}

/** Face names; the background rect carries `id="face-<name>"` (a plain SVG id, used by the e2e harness). */
export type FaceName = "offline" | "missing" | "launching" | "idle" | "mic-starting" | "listening" | "processing" | "choices" | "success" | "error";

export function svgDoc(face: FaceName, body: string, background: string = COLORS.bg): string {
	return `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}"><rect id="face-${face}" width="${SIZE}" height="${SIZE}" fill="${background}"/>${body}</svg>`;
}

/** The orb: a core disc with a faked glow (stacked translucent discs) and, on solid cores, a soft highlight. */
export function orb(cx: number, cy: number, r: number, color: string, core: number, glow: number): string {
	return (
		circle(cx, cy, r + 16, { fill: color, fillOpacity: 0.05 * glow }) +
		circle(cx, cy, r + 10, { fill: color, fillOpacity: 0.09 * glow }) +
		circle(cx, cy, r + 5, { fill: color, fillOpacity: 0.15 * glow }) +
		circle(cx, cy, r, { fill: color, fillOpacity: core }) +
		(core >= 0.5 ? circle(cx - r * 0.32, cy - r * 0.36, r * 0.38, { fill: "#FFFFFF", fillOpacity: 0.2 }) : "")
	);
}

function check(cx: number, cy: number, color: string): string {
	return `<path d="M ${cx - 17} ${cy + 1} L ${cx - 5} ${cy + 13} L ${cx + 18} ${cy - 11}" fill="none" stroke="${color}" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>`;
}

function cross(cx: number, cy: number, color: string): string {
	return `<path d="M ${cx - 13} ${cy - 13} L ${cx + 13} ${cy + 13} M ${cx + 13} ${cy - 13} L ${cx - 13} ${cy + 13}" fill="none" stroke="${color}" stroke-width="8" stroke-linecap="round"/>`;
}

/** Spinner angle, quantized to 6 degrees. */
function spin(now: number, speed = SPIN_DEG_PER_S): number {
	return Math.round((((now / 1000) * speed) % 360) / 6) * 6;
}

/** Remaining share of the choices window, 0..1. */
export function choicesLeft(v: View, now: number): number {
	const deadline = v.state?.deadline;
	if (deadline === undefined) return 1;
	const start = v.windowStart ?? v.state?.since ?? now;
	return clamp01((deadline - now) / Math.max(1, deadline - start));
}

// ---------- faces ----------

/** Idle: dim cyan orb with "AC". */
export function faceIdle(): string {
	return svgDoc("idle",
		circle(CX, CY, 50, { stroke: COLORS.cyan, strokeWidth: 2, strokeOpacity: 0.2 }) +
			orb(CX, CY, 30, COLORS.cyan, 0.26, 0.45) +
			text(CX, CY + 10, KEY_TEXT.brand, 28, COLORS.ink, true, 0.92),
	);
}

/** Offline: grey orb, "Start" (a press launches the app), or the launch error in red. */
export function faceOffline(error?: string): string {
	return svgDoc(error ? "missing" : "offline",
		circle(CX, CY_CAPTION, 42, { stroke: COLORS.grey, strokeWidth: 2, strokeOpacity: 0.6 }) +
			circle(CX, CY_CAPTION, 30, { fill: COLORS.faint }) +
			text(CX, CY_CAPTION + 10, KEY_TEXT.brand, 28, COLORS.grey, true) +
			(error ? caption(error, COLORS.red, 17) : caption(KEY_TEXT.start, COLORS.dim)),
	);
}

/** Launching (or connected without a snapshot yet): grey orb with a cyan spinner. */
export function faceLaunching(now: number): string {
	const a = spin(now);
	return svgDoc("launching",
		circle(CX, CY_CAPTION, 42, { stroke: COLORS.faint, strokeWidth: 4 }) +
			arc(CX, CY_CAPTION, 42, a, a + 80, COLORS.cyan, 4) +
			circle(CX, CY_CAPTION, 30, { fill: COLORS.faint }) +
			text(CX, CY_CAPTION + 10, KEY_TEXT.brand, 28, COLORS.grey, true) +
			caption(KEY_TEXT.starting, COLORS.dim),
	);
}

/** Listening: cyan core plus ripples that expand outward; the level scales core, brightness and width. */
export function faceListening(level: number, micReady: boolean, now: number): string {
	const t = now / 1000;
	if (!micReady) {
		// Engine starting: a slow breathing ring, no ripples yet.
		const breathe = 0.3 + 0.12 * Math.sin(t * Math.PI * 2 * 0.8);
		return svgDoc("mic-starting", circle(CX, CY, 44, { stroke: COLORS.cyan, strokeWidth: 3, strokeOpacity: breathe }) + orb(CX, CY, 24, COLORS.cyan, 0.35, 0.35));
	}
	const lvl = clamp01(level);
	let rings = "";
	for (let i = 0; i < 3; i++) {
		const p = (t * RIPPLE_HZ + i / 3) % 1;
		const r = 30 + p * 32 + lvl * 6;
		const opacity = (1 - p) * (0.3 + 0.6 * lvl);
		rings += circle(CX, CY, r, { stroke: COLORS.cyan, strokeWidth: 3.5 - p * 2, strokeOpacity: Math.round(opacity * 50) / 50 });
	}
	return svgDoc("listening", rings + orb(CX, CY, 20 + lvl * 9, COLORS.cyan, 0.85, 0.6 + 0.4 * lvl));
}

/** Processing: violet orb with a rotating arc and a slower counter arc. */
export function faceProcessing(now: number): string {
	const a = spin(now);
	const b = 360 - spin(now, SPIN_DEG_PER_S * 0.6);
	return svgDoc("processing",
		circle(CX, CY, 46, { stroke: COLORS.violet, strokeWidth: 5, strokeOpacity: 0.18 }) +
			arc(CX, CY, 46, a, a + 110, COLORS.violet, 5) +
			arc(CX, CY, 35, b, b + 60, COLORS.violet, 3, 0.55) +
			orb(CX, CY, 20, COLORS.violet, 0.85, 0.8),
	);
}

/** Choices: amber orb with the number of visible choices and a countdown ring. */
/** A small list glyph (three bullets with lines), centered on cx/cy. */
function listGlyph(cx: number, cy: number, color: string): string {
	let d = "";
	for (const dy of [-10, 0, 10]) d += `M ${cx - 4} ${cy + dy} L ${cx + 13} ${cy + dy} `;
	const dots = [-10, 0, 10].map((dy) => `<circle cx="${cx - 12}" cy="${cy + dy}" r="3" fill="${color}"/>`).join("");
	return `<path d="${d.trim()}" fill="none" stroke="${color}" stroke-width="5" stroke-linecap="round"/>${dots}`;
}

/**
 * Choices: the ring counts down, the glyph says "the overlay shows a list". A count here read like
 * "press to pick", but a press cancels. A cross would look like the error face.
 */
export function faceChoices(left: number): string {
	return svgDoc("choices",
		circle(CX, CY, 54, { stroke: COLORS.amber, strokeWidth: 6, strokeOpacity: 0.18 }) +
			arc(CX, CY, 54, 0, Math.round(360 * clamp01(left) * 2) / 2, COLORS.amber, 6) +
			orb(CX, CY, 30, COLORS.amber, 0.92, 0.7) +
			listGlyph(CX, CY, COLORS.amberInk),
	);
}

export function faceSuccess(): string {
	return svgDoc("success",
		circle(CX, CY, 46, { stroke: COLORS.green, strokeWidth: 5, strokeOpacity: 0.9 }) +
			orb(CX, CY, 28, COLORS.green, 0.16, 0.5) +
			check(CX, CY, COLORS.green),
	);
}

/** Error: red ring and cross, plus the app's message as a small caption when there is one. */
export function faceError(message?: string): string {
	const cy = message ? CY_CAPTION : CY;
	return svgDoc("error",
		circle(CX, cy, message ? 42 : 46, { stroke: COLORS.red, strokeWidth: 5, strokeOpacity: 0.9 }) +
			orb(CX, cy, 26, COLORS.red, 0.16, 0.5) +
			cross(CX, cy, COLORS.red) +
			(message ? caption(message, COLORS.red, 15) : ""),
	);
}

/** The voice key face for a view at time `now` (epoch ms). */
export function renderVoice(v: View, now: number): string {
	if (v.link === "launching" || (v.link === "online" && !v.state)) return faceLaunching(now);
	if (v.link === "offline" || !v.state) return faceOffline(v.linkError);
	const s = v.state;
	switch (s.phase) {
		case "idle":
			return faceIdle();
		case "listening":
			return faceListening(v.level, s.micReady === true, now);
		case "processing":
			return faceProcessing(now);
		case "choices":
			return faceChoices(choicesLeft(v, now));
		case "success":
			return faceSuccess();
		case "error":
			return faceError(s.message);
	}
}

/** True when the face changes over time and needs the animation tick. Static faces paint once. */
export function isAnimated(v: View, now: number): boolean {
	if (v.link === "launching" || (v.link === "online" && !v.state)) return true;
	if (v.link !== "online" || !v.state) return false;
	switch (v.state.phase) {
		case "listening":
		case "processing":
			return true;
		case "choices":
			return v.state.deadline !== undefined && v.state.deadline > now;
		default:
			return false;
	}
}

/**
 * Identity of the face apart from animation. A change paints at once (key latency); an unchanged key
 * while animating waits for the next tick (frame cap).
 */
export function faceKey(v: View): string {
	const s = v.link === "online" ? v.state : undefined;
	return [v.link, v.linkError ?? "", s?.phase ?? "", s?.micReady ? 1 : 0, s?.choices?.length ?? 0, s?.phase === "error" ? (s.message ?? "") : "", v.windowStart ?? ""].join("|");
}

export function toDataUrl(svg: string): string {
	return `data:image/svg+xml;charset=utf8,${encodeURIComponent(svg)}`;
}
