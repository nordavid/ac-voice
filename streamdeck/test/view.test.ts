import { describe, expect, it } from "vitest";
import type { StateMsg } from "../src/protocol.js";
import { fromStreamDeck, linkErrorText, parseLang } from "../src/i18n.js";
import { ViewModel } from "../src/view.js";

const st = (seq: number, phase: StateMsg["phase"], extra: Partial<StateMsg> = {}): StateMsg => ({ v: 1, t: "state", seq, phase, since: 1000, ...extra });
const list = (labels: string[]) => labels.map((label, i) => ({ n: i + 1, label }));

describe("ViewModel", () => {
	it("clears the snapshot when the link drops", () => {
		const m = new ViewModel(() => 5000);
		m.status("online");
		m.state(st(1, "listening", { micReady: true }));
		m.level(0.8);
		m.status("offline");
		expect(m.view).toEqual({ link: "offline", linkError: undefined, level: 0, state: undefined, windowStart: undefined, lang: "de" });
		m.status("offline", "App fehlt");
		expect(m.view.linkError).toBe("App fehlt");
	});

	it("smooths the level with fast attack and slow release, only while listening", () => {
		const m = new ViewModel();
		m.status("online");
		m.state(st(1, "idle"));
		m.level(0.9);
		expect(m.view.level).toBe(0);
		m.state(st(2, "listening", { micReady: true }));
		m.level(0.9);
		expect(m.view.level).toBe(0.9);
		m.level(0);
		expect(m.view.level).toBeCloseTo(0.54);
		m.level(5);
		expect(m.view.level).toBe(1);
		m.level(Number.NaN);
		expect(m.view.level).toBeCloseTo(0.6);
		m.state(st(3, "processing"));
		expect(m.view.level).toBe(0);
	});

	it("restarts the countdown for a new list but not for a deadline extension", () => {
		let now = 10_000;
		const m = new ViewModel(() => now);
		m.status("online");
		m.state(st(1, "choices", { choices: list(["A", "B", "C", "D"]), deadline: 16_000 }));
		expect(m.view.windowStart).toBe(10_000);
		now = 12_000;
		m.state(st(2, "choices", { choices: list(["A", "B", "C", "D"]), deadline: 17_000 }));
		expect(m.view.windowStart).toBe(10_000);
		now = 13_000;
		m.state(st(3, "choices", { choices: list(["B", "C"]), deadline: 19_000 }));
		expect(m.view.windowStart).toBe(13_000);
		m.state(st(4, "success"));
		expect(m.view.windowStart).toBeUndefined();
		now = 20_000;
		m.state(st(5, "choices", { choices: list(["B", "C"]), deadline: 26_000 }));
		expect(m.view.windowStart).toBe(20_000);
	});

	it("follows the Stream Deck language until the app names its own, and keeps the app's", () => {
		const m = new ViewModel(() => 0, "en");
		expect(m.view.lang).toBe("en");
		m.fallback("de");
		expect(m.view.lang).toBe("de");
		m.status("online");
		m.state(st(1, "idle", { lang: "en" }));
		expect(m.view.lang).toBe("en");
		// An app restart drops the link; its language stays until the next snapshot says otherwise.
		m.status("offline");
		expect(m.view.lang).toBe("en");
		m.fallback("de");
		expect(m.view.lang).toBe("en");
		m.status("online");
		m.state(st(1, "idle", { lang: "de-DE" }));
		expect(m.view.lang).toBe("de");
		// An older app sends no language, an unknown one changes nothing.
		m.state(st(2, "idle"));
		m.state(st(3, "idle", { lang: "fr" }));
		expect(m.view.lang).toBe("de");
	});
});

describe("languages", () => {
	it("maps codes the way the app does", () => {
		expect([parseLang("de"), parseLang("de-AT"), parseLang("de_DE"), parseLang("EN-us"), parseLang("fr"), parseLang(7)]).toEqual([
			"de",
			"de",
			"de",
			"en",
			undefined,
			undefined,
		]);
		expect([fromStreamDeck("de"), fromStreamDeck("en"), fromStreamDeck("zh_CN"), fromStreamDeck(undefined)]).toEqual(["de", "en", "en", "en"]);
		expect(linkErrorText("app-missing", "de")).toBe("App fehlt");
		expect(linkErrorText("app-missing", "en")).toBe("App missing");
	});
});
