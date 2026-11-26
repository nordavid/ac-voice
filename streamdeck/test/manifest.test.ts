import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { APP_MISSING } from "../src/app-link.js";
import { APP_BUNDLE_ID, PLUGIN_UUID, PLUGIN_VERSION, VOICE_ACTION_UUID } from "../src/config.js";
import { KEY_TEXT } from "../src/render.js";

const root = path.resolve(import.meta.dirname, "..");
const sd = path.join(root, "io.github.nordavid.acvoice.streamdeck.sdPlugin");
const manifest = JSON.parse(fs.readFileSync(path.join(sd, "manifest.json"), "utf8"));
const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const inspector = fs.readFileSync(path.join(sd, "ui", "voice.html"), "utf8");

/** Visible German text of the property inspector (markup, style and script removed). */
function inspectorText(): string[] {
	const body = inspector.replace(/<style[\s\S]*?<\/style>/g, "").replace(/<script[\s\S]*?<\/script>/g, "");
	const html = body.split(/<[^>]+>/).map((s) => s.trim()).filter(Boolean);
	const labels = [...inspector.matchAll(/^\s+\w+: "([^"]+)",$/gm)].map((m) => m[1]!);
	return [...html, ...labels];
}

describe("manifest", () => {
	it("declares the plugin, one voice action and the monitored app", () => {
		expect(manifest.UUID).toBe(PLUGIN_UUID);
		expect(PLUGIN_UUID).toBe("io.github.nordavid.acvoice.streamdeck");
		expect(path.basename(sd)).toBe(`${PLUGIN_UUID}.sdPlugin`);
		expect(manifest.Actions).toHaveLength(1);
		expect(manifest.Actions[0].UUID).toBe(VOICE_ACTION_UUID);
		expect(manifest.Actions[0].Name).toBe("AC Voice");
		expect(manifest.Actions[0].Controllers).toEqual(["Keypad"]);
		expect(manifest.Actions[0].UserTitleEnabled).toBe(false);
		expect(manifest.Actions[0].States).toEqual([{ Image: "imgs/actions/voice/key", ShowTitle: false }]);
		expect(manifest.ApplicationsToMonitor).toEqual({ mac: [APP_BUNDLE_ID] });
		expect(manifest.Nodejs.Version).toBe("24");
		expect(manifest.SDKVersion).toBe(3);
		expect(manifest.CodePath).toBe("bin/plugin.js");
	});

	it("keeps versions in sync", () => {
		expect(pkg.version).toBe(PLUGIN_VERSION);
		expect(manifest.Version).toBe(`${PLUGIN_VERSION}.0`);
	});

	it("pins exact dependency versions", () => {
		for (const [name, v] of Object.entries({ ...pkg.dependencies, ...pkg.devDependencies })) {
			expect(v, name).toMatch(/^\d+\.\d+\.\d+$/);
		}
	});

	it("ships every referenced image as 1x and 2x PNG", () => {
		const refs = [manifest.Icon, manifest.CategoryIcon, manifest.Actions[0].Icon, manifest.Actions[0].States[0].Image];
		for (const ref of refs) {
			for (const suffix of [".png", "@2x.png"]) expect(fs.existsSync(path.join(sd, ref + suffix)), ref + suffix).toBe(true);
		}
		expect(fs.existsSync(path.join(sd, manifest.Actions[0].PropertyInspectorPath))).toBe(true);
	});
});

describe("German UI text (company style)", () => {
	const texts = [
		manifest.Description,
		manifest.Actions[0].Tooltip,
		manifest.Name,
		manifest.Category,
		...Object.values(KEY_TEXT),
		APP_MISSING,
		...inspectorText(),
	] as string[];

	it("has the inspector texts", () => {
		expect(texts).toContain("Tippe auf die Taste und sprich. AC Voice erkennt das Satzende selbst.");
		expect(texts).toContain("Tippe und sprich. Oder halte die Taste beim Sprechen.");
		expect(texts).toContain("App läuft nicht. Ein Tastendruck startet sie.");
		expect(texts).toContain("Verbunden. AC Voice antwortet gerade nicht.");
	});

	it("closes German quotes with “", () => {
		const quoted = inspectorText().filter((t) => t.startsWith("„"));
		expect(quoted.length).toBeGreaterThanOrEqual(5);
		for (const t of quoted) expect(t).toMatch(/^„[^"“]+“$/);
	});

	it.each(texts.map((t) => [t]))("%s", (t) => {
		expect(t).not.toMatch(/[–—]/); // plain hyphen only
		expect(t.toLowerCase()).not.toMatch(/\b(könnte|sollte|würde|wäre|könnten|sollten|würden)\b/);
		expect(t).not.toMatch(/\bwird\b|\bwerden\b|\bwurde\b/); // no passive
		expect(t).not.toMatch(/\w: \w/); // no colon inside a sentence
		expect(t).not.toMatch(/[a-zäöü]Innen\b|[*:_]in(nen)?\b/); // no gendering
	});
});
