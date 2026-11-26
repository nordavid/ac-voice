import { faceKey, isAnimated, renderVoice, toDataUrl } from "./render.js";
import type { View } from "./view.js";

/** The part of an SDK KeyAction the painter needs. */
export interface KeyTarget {
	readonly id: string;
	setImage(image: string): Promise<void>;
}

export interface PainterOptions {
	/** Animation tick; 100 ms caps animated faces at 10 fps. */
	tickMs?: number;
	now?: () => number;
	setInterval?: (fn: () => void, ms: number) => unknown;
	clearInterval?: (handle: unknown) => void;
}

/**
 * Pushes the voice face to every visible key.
 * - A face change (phase, link, error) paints at once, so key latency stays below a millisecond.
 * - Animated faces repaint only on the tick: at most 10 setImage per second per key, whatever the rate of
 *   level or transcript updates.
 * - The tick runs only while the face animates; static faces are sent once.
 * - Identical SVGs are never sent twice (per key).
 */
export class Painter {
	readonly #keys = new Map<string, KeyTarget>();
	readonly #last = new Map<string, string>();
	readonly #tickMs: number;
	readonly #now: () => number;
	readonly #setInterval: (fn: () => void, ms: number) => unknown;
	readonly #clearInterval: (handle: unknown) => void;
	#timer: unknown;
	#lastKey = "";

	constructor(
		private readonly view: () => View,
		opts: PainterOptions = {},
	) {
		this.#tickMs = opts.tickMs ?? 100;
		this.#now = opts.now ?? Date.now;
		this.#setInterval = opts.setInterval ?? ((fn, ms) => setInterval(fn, ms));
		this.#clearInterval = opts.clearInterval ?? ((h) => clearInterval(h as NodeJS.Timeout));
	}

	get animating(): boolean {
		return this.#timer !== undefined;
	}

	get size(): number {
		return this.#keys.size;
	}

	add(key: KeyTarget): void {
		this.#keys.set(key.id, key);
		this.#last.delete(key.id);
		this.#paint(true);
	}

	remove(id: string): void {
		this.#keys.delete(id);
		this.#last.delete(id);
		if (this.#keys.size === 0) this.#stop();
	}

	/** The view changed. Paints now when the face changed, else leaves animated faces to the tick. */
	update(): void {
		const v = this.view();
		const key = faceKey(v);
		const changed = key !== this.#lastKey;
		this.#paint(changed || !isAnimated(v, this.#now()));
	}

	dispose(): void {
		this.#stop();
		this.#keys.clear();
		this.#last.clear();
	}

	#paint(push: boolean): void {
		const now = this.#now();
		const v = this.view();
		this.#lastKey = faceKey(v);
		if (push && this.#keys.size > 0) {
			const svg = renderVoice(v, now);
			for (const [id, key] of this.#keys) this.#push(id, key, svg);
		}
		if (this.#keys.size > 0 && isAnimated(v, now)) this.#start();
		else this.#stop();
	}

	#push(id: string, key: KeyTarget, svg: string): void {
		if (this.#last.get(id) === svg) return;
		this.#last.set(id, svg);
		key.setImage(toDataUrl(svg)).catch(() => this.#last.delete(id));
	}

	#start(): void {
		if (this.#timer !== undefined) return;
		this.#timer = this.#setInterval(() => this.#paint(true), this.#tickMs);
	}

	#stop(): void {
		if (this.#timer === undefined) return;
		this.#clearInterval(this.#timer);
		this.#timer = undefined;
	}
}
