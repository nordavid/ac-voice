import { describe, expect, it } from "vitest";
import { KeyEdges, type PressTarget } from "../src/keys.js";

function fakeLink() {
	const calls: (["press", string] | ["release", string, number])[] = [];
	let n = 0;
	const link: PressTarget = {
		press: () => {
			const id = `sd-${++n}`;
			calls.push(["press", id]);
			return id;
		},
		release: (pressId, heldMs) => void calls.push(["release", pressId, heldMs]),
	};
	return { link, calls };
}

describe("KeyEdges", () => {
	it("sends press on key down and release with the real hold time on key up", () => {
		let t = 1000;
		const { link, calls } = fakeLink();
		const keys = new KeyEdges(link, () => t);
		keys.down("a");
		t += 812;
		keys.up("a");
		expect(calls).toEqual([
			["press", "sd-1"],
			["release", "sd-1", 812],
		]);
		expect(keys.held).toBe(0);
	});

	it("ignores a key up without a key down", () => {
		const { link, calls } = fakeLink();
		const keys = new KeyEdges(link, () => 0);
		keys.up("a");
		keys.gone("a");
		expect(calls).toEqual([]);
	});

	// Review finding 2: willDisappear dropped the held key without a release, so the app kept end-of-utterance
	// detection suspended until its 8 s limit.
	it("releases a held key that disappears, with heldMs 0, and sends nothing for a later key up", () => {
		let t = 0;
		const { link, calls } = fakeLink();
		const keys = new KeyEdges(link, () => t);
		keys.down("a");
		t += 2500;
		keys.gone("a");
		t += 100;
		keys.up("a");
		expect(calls).toEqual([
			["press", "sd-1"],
			["release", "sd-1", 0],
		]);
		expect(keys.held).toBe(0);
	});

	it("tracks keys on several pages and devices apart", () => {
		let t = 0;
		const { link, calls } = fakeLink();
		const keys = new KeyEdges(link, () => t);
		keys.down("a");
		t = 10;
		keys.down("b");
		t = 50;
		keys.gone("a");
		t = 70;
		keys.up("b");
		expect(calls).toEqual([
			["press", "sd-1"],
			["press", "sd-2"],
			["release", "sd-1", 0],
			["release", "sd-2", 60],
		]);
	});
});
