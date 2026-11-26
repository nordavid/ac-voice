import { describe, expect, it } from "vitest";
import { type KeyTarget, Painter } from "../src/painter.js";
import type { StateMsg } from "../src/protocol.js";
import { ViewModel } from "../src/view.js";

/** Deterministic clock and interval for the painter. */
function harness() {
	let now = 1_000_000;
	let tick: (() => void) | undefined;
	let intervalMs = 0;
	const model = new ViewModel(() => now);
	const images: { key: string; at: number; url: string }[] = [];
	const key = (id: string): KeyTarget => ({
		id,
		setImage: async (url: string) => {
			images.push({ key: id, at: now, url });
		},
	});
	const painter = new Painter(() => model.view, {
		now: () => now,
		setInterval: (fn, ms) => {
			tick = fn;
			intervalMs = ms;
			return 1;
		},
		clearInterval: () => {
			tick = undefined;
		},
	});
	/** Advances the clock, firing ticks every interval and calling `between` every `stepMs`. */
	const run = (ms: number, stepMs = 10, between?: () => void) => {
		let nextTick = now + intervalMs;
		const end = now + ms;
		while (now < end) {
			now += stepMs;
			between?.();
			if (tick && now >= nextTick) {
				tick();
				nextTick += intervalMs;
			}
			if (!tick) nextTick = now + intervalMs;
		}
	};
	const st = (seq: number, phase: StateMsg["phase"], extra: Partial<StateMsg> = {}): StateMsg => ({ v: 1, t: "state", seq, phase, since: now, ...extra });
	return { model, painter, images, key, run, st, getNow: () => now, ticking: () => tick !== undefined, intervalMs: () => intervalMs };
}

describe("Painter", () => {
	it("paints a new key at once and dedupes static faces", () => {
		const h = harness();
		h.painter.add(h.key("k1"));
		expect(h.images).toHaveLength(1);
		expect(h.ticking()).toBe(false);
		h.painter.update();
		h.painter.update();
		expect(h.images).toHaveLength(1);
		h.painter.add(h.key("k2"));
		expect(h.images.map((i) => i.key)).toEqual(["k1", "k2"]);
	});

	it("paints face changes immediately", () => {
		const h = harness();
		h.painter.add(h.key("k"));
		h.model.status("online");
		h.painter.update();
		h.model.state(h.st(1, "idle"));
		h.painter.update();
		const before = h.images.length;
		h.model.state(h.st(2, "listening", { micReady: false }));
		h.painter.update();
		expect(h.images.length).toBe(before + 1);
		expect(h.images.at(-1)!.at).toBe(h.getNow());
	});

	it("caps animation at 10 fps no matter how fast levels and partials arrive", () => {
		const h = harness();
		h.painter.add(h.key("k"));
		h.model.status("online");
		h.model.state(h.st(1, "listening", { micReady: true }));
		h.painter.update();
		expect(h.ticking()).toBe(true);
		expect(h.intervalMs()).toBe(100);
		const start = h.images.length;
		let seq = 2;
		let n = 0;
		// Levels at 100 Hz and a transcript partial every 50 ms for 2 s.
		h.run(2000, 10, () => {
			h.model.level((n++ % 10) / 10);
			if (n % 5 === 0) {
				h.model.state(h.st(seq++, "listening", { micReady: true, transcript: `partial ${n}` }));
				h.painter.update();
			}
		});
		const frames = h.images.length - start;
		expect(frames).toBeGreaterThanOrEqual(15);
		expect(frames).toBeLessThanOrEqual(20);
	});

	it("stops the tick on static faces and when the countdown ends", () => {
		const h = harness();
		h.painter.add(h.key("k"));
		h.model.status("online");
		h.model.state(h.st(1, "processing"));
		h.painter.update();
		expect(h.ticking()).toBe(true);
		h.model.state(h.st(2, "success"));
		h.painter.update();
		expect(h.ticking()).toBe(false);
		const after = h.images.length;
		h.run(1000);
		expect(h.images.length).toBe(after);

		h.model.state(h.st(3, "choices", { choices: [{ n: 1, label: "A" }, { n: 2, label: "B" }], deadline: h.getNow() + 1000 }));
		h.painter.update();
		expect(h.ticking()).toBe(true);
		h.run(1500);
		expect(h.ticking()).toBe(false);
		const last = decodeURIComponent(h.images.at(-1)!.url);
		expect(last).not.toContain(" A 54 54 "); // the countdown arc (an SVG arc command on r 54) is gone at 0 s
		expect(last).toContain('id="face-choices"');
	});

	it("stops when the last key disappears", () => {
		const h = harness();
		h.painter.add(h.key("k"));
		h.model.status("launching");
		h.painter.update();
		expect(h.ticking()).toBe(true);
		h.painter.remove("k");
		expect(h.ticking()).toBe(false);
		expect(h.painter.size).toBe(0);
	});

	it("re-sends after a failed setImage", async () => {
		let fail = true;
		const urls: string[] = [];
		const model = new ViewModel();
		const p = new Painter(() => model.view, { setInterval: () => 1, clearInterval: () => {} });
		p.add({
			id: "k",
			setImage: (url) => {
				urls.push(url);
				return fail ? Promise.reject(new Error("socket closed")) : Promise.resolve();
			},
		});
		await new Promise((r) => setImmediate(r));
		fail = false;
		p.update();
		expect(urls).toHaveLength(2);
		expect(urls[0]).toBe(urls[1]);
	});
});
