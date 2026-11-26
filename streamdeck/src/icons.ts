/**
 * Static plugin images (rendered to PNG by scripts/build-icons.ts). Not part of the plugin bundle.
 * Stream Deck guidelines: list icons (action, category) are a white glyph on transparency;
 * the plugin icon is a full-color tile.
 */
import { COLORS, faceIdle, orb } from "./render.js";

/** White orb glyph on transparency, drawn in a 40 x 40 box: outer ring, two arcs, solid core. */
export function glyphSvg(size: number): string {
	return (
		`<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 40 40">` +
		`<circle cx="20" cy="20" r="17" fill="none" stroke="#FFFFFF" stroke-width="2.4" stroke-opacity="0.55"/>` +
		`<path d="M 20 8.5 A 11.5 11.5 0 0 1 31.5 20" fill="none" stroke="#FFFFFF" stroke-width="2.4" stroke-linecap="round"/>` +
		`<path d="M 20 31.5 A 11.5 11.5 0 0 1 8.5 20" fill="none" stroke="#FFFFFF" stroke-width="2.4" stroke-linecap="round"/>` +
		`<circle cx="20" cy="20" r="6.5" fill="#FFFFFF"/>` +
		`</svg>`
	);
}

/** Plugin icon: the listening orb on a dark rounded tile. */
export function marketplaceSvg(size: number): string {
	const ripples = [
		{ r: 44, w: 3, o: 0.55 },
		{ r: 54, w: 2.5, o: 0.35 },
		{ r: 63, w: 2, o: 0.18 },
	]
		.map((x) => `<circle cx="72" cy="72" r="${x.r}" fill="none" stroke="${COLORS.cyan}" stroke-width="${x.w}" stroke-opacity="${x.o}"/>`)
		.join("");
	return (
		`<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 144 144">` +
		`<rect width="144" height="144" rx="30" fill="${COLORS.bg}"/>` +
		ripples +
		orb(72, 72, 28, COLORS.cyan, 0.9, 1) +
		`</svg>`
	);
}

/** Default key image until the plugin paints: the idle face. */
export function keySvg(): string {
	return faceIdle();
}
