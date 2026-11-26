import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { APP_BUNDLE_ID, PLUGIN_UUID, PLUGIN_VERSION, VOICE_ACTION_UUID } from "../src/config.js";
import { KEY_TEXTS } from "../src/render.js";

const root = path.resolve(import.meta.dirname, "..");
const sd = path.join(root, "io.github.nordavid.acvoice.streamdeck.sdPlugin");
const manifest = JSON.parse(fs.readFileSync(path.join(sd, "manifest.json"), "utf8"));
/** Stream Deck's German localization of the manifest; the manifest itself is English (every other language). */
const de = JSON.parse(fs.readFileSync(path.join(sd, "de.json"), "utf8"));
const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const inspector = fs.readFileSync(path.join(sd, "ui", "voice.html"), "utf8");

/** Visible text of the property inspector's section in `lang` (markup removed) plus its status labels. */
function inspectorText(lang: "de" | "en"): string[] {
	const section = new RegExp(`<section lang="${lang}">([\\s\\S]*?)</section>`).exec(inspector)?.[1] ?? "";
	const html = section.split(/<[^>]+>/).map((s) => s.trim()).filter(Boolean);
	const block = new RegExp(`^\\t+${lang}: \\{$([\\s\\S]*?)^\\t+\\},$`, "m").exec(inspector)?.[1] ?? "";
	const labels = [...block.matchAll(/^\s+\w+: "([^"]+)",$/gm)].map((m) => m[1]!);
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

	it("localizes the manifest for German Stream Decks", () => {
		expect(de[VOICE_ACTION_UUID]).toEqual({ Name: manifest.Actions[0].Name, Tooltip: expect.any(String) });
		expect(de.Name).toBe(manifest.Name);
		expect(de.Category).toBe(manifest.Category);
		expect(de.Description).not.toBe(manifest.Description);
		// The SDK's i18n reads "Localization" from the same file; it must be an object.
		expect(de.Localization).toEqual({});
	});

	it("has the inspector in both languages, side by side", () => {
		const count = (lang: string, tag: string) =>
			(new RegExp(`<section lang="${lang}">([\\s\\S]*?)</section>`).exec(inspector)?.[1] ?? "").split(`<${tag}`).length - 1;
		for (const tag of ["h2", "p", "li"]) expect(count("en", tag), tag).toBe(count("de", tag));
		expect(inspectorText("de").length).toBeGreaterThan(10);
		expect(inspectorText("en").length).toBe(inspectorText("de").length);
	});
});

describe("German UI text (company style)", () => {
	const texts = [
		de.Description,
		de[VOICE_ACTION_UUID].Tooltip,
		de.Name,
		de.Category,
		...Object.values(KEY_TEXTS.de),
		...inspectorText("de"),
	] as string[];

	it("has the inspector texts", () => {
		expect(texts).toContain("Tippe auf die Taste und sprich. AC Voice erkennt das Satzende selbst.");
		expect(texts).toContain("Tippe und sprich. Oder halte die Taste beim Sprechen.");
		expect(texts).toContain("App läuft nicht. Ein Tastendruck startet sie.");
		expect(texts).toContain("Verbunden. AC Voice antwortet gerade nicht.");
		expect(texts).toContain("App fehlt");
	});

	it("closes German quotes with “", () => {
		const quoted = inspectorText("de").filter((t) => t.startsWith("„"));
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

describe("English UI text", () => {
	const texts = [
		manifest.Description,
		manifest.Actions[0].Tooltip,
		manifest.Name,
		manifest.Category,
		...Object.values(KEY_TEXTS.en),
		...inspectorText("en"),
	] as string[];

	it("has the inspector texts", () => {
		expect(texts).toContain("Tap the key and speak. AC Voice detects the end of the sentence by itself.");
		expect(texts).toContain("Tap and speak. Or hold the key while you speak.");
		expect(texts).toContain("App is not running. A key press starts it.");
		expect(texts).toContain("Connected. AC Voice is not responding right now.");
		expect(texts).toContain("App missing");
	});

	it("gives examples with the English command words", () => {
		const examples = inspectorText("en").filter((t) => t.startsWith("“"));
		expect(examples).toEqual(["“open the WWT project”", "“WWT Relaunch”", "“open WWT ticket 412”", "“ticket 47285”", "“my tasks”"]);
		const all = texts.join(" ");
		for (const word of ["“number two”", "“more”", "“cancel”"]) expect(all).toContain(word);
	});

	it.each(texts.map((t) => [t]))("%s", (t) => {
		expect(t).not.toMatch(/[–—!„]/); // plain hyphen, no exclamation mark, English quotes
		expect(t).not.toMatch(/[äöüÄÖÜß]/); // nothing German left
		expect(t.toLowerCase()).not.toMatch(/\b(would|could|should|might)\b/);
		expect(t).not.toMatch(/\w: \w/); // no colon inside a sentence
		if (/^[a-z]/i.test(t)) expect(t[0]).toBe(t[0]!.toUpperCase()); // sentence case
	});
});
