import type { AppLink } from "./app-link.js";

/** The part of `AppLink` the key edges drive. */
export type PressTarget = Pick<AppLink, "press" | "release">;

/**
 * Turns the key events of the visible voice keys into `press` / `release`, so that every press the app gets
 * also gets a release. The app keeps end-of-utterance detection suspended while a key is down.
 */
export class KeyEdges {
	/** Pressed keys: action id -> the press id sent (or queued) and the key-down time. */
	readonly #down = new Map<string, { pressId: string; at: number }>();

	constructor(
		private readonly link: PressTarget,
		private readonly now: () => number = Date.now,
	) {}

	/** Keys held right now. */
	get held(): number {
		return this.#down.size;
	}

	/** keyDown. Fires on key down, not key up: saves the press duration. */
	down(key: string): void {
		const at = this.now();
		const pressId = this.link.press();
		this.#down.set(key, { pressId, at });
	}

	/** keyUp: the real hold time decides push-to-talk in the app. */
	up(key: string): void {
		const d = this.#down.get(key);
		if (!d) return;
		this.#down.delete(key);
		this.link.release(d.pressId, this.now() - d.at);
	}

	/**
	 * willDisappear (page or profile switch). Stream Deck sends no keyUp for a key that left the page, so a held
	 * key ends here. `heldMs` 0: the finger may still rest on the key, so the app resumes its automatic end of
	 * utterance instead of cutting the sentence (a push-to-talk end needs a hold of 600 ms or more).
	 */
	gone(key: string): void {
		const d = this.#down.get(key);
		if (!d) return;
		this.#down.delete(key);
		this.link.release(d.pressId, 0);
	}
}
