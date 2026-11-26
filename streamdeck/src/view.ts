import { type Lang, parseLang } from "./i18n.js";
import type { StateMsg } from "./protocol.js";

/** Link state as the key shows it. `launching`: the app is starting, or connected without a snapshot yet. */
export type LinkStatus = "offline" | "launching" | "online";

/** Everything the key face depends on, besides the clock. */
export interface View {
	link: LinkStatus;
	/** Why the app cannot start: a reason code (`APP_MISSING`) or a text. */
	linkError?: string;
	/** Latest snapshot of this connection; undefined while not online. */
	state?: StateMsg;
	/** Smoothed mic level 0..1, only while listening. */
	level: number;
	/** Epoch ms when the current choice list appeared; the countdown ring runs from here to `state.deadline`. */
	windowStart?: number;
	/** Language of the key captions: the app's (`state.lang`) once a snapshot named it, else the fallback. */
	lang: Lang;
}

/** Folds link events into the `View`. Pure apart from the injected clock. */
export class ViewModel {
	readonly view: View;
	#listKey = "";
	/** The language the app named last. The app keeps it for its whole run, so it outlives a dropped link. */
	#appLang?: Lang;

	/** `fallback`: the language before the app names its own (the Stream Deck language, `fromStreamDeck`). */
	constructor(
		private readonly now: () => number = Date.now,
		fallback: Lang = "de",
	) {
		this.view = { link: "offline", level: 0, lang: fallback };
	}

	/** A new Stream Deck language. The app's language still wins once known. */
	fallback(lang: Lang): void {
		this.view.lang = this.#appLang ?? lang;
	}

	status(link: LinkStatus, error?: string): void {
		this.view.link = link;
		this.view.linkError = error;
		if (link !== "online") {
			// A snapshot from a dead connection is stale; the next connect sends a fresh one.
			this.view.state = undefined;
			this.view.level = 0;
			this.view.windowStart = undefined;
			this.#listKey = "";
		}
	}

	state(s: StateMsg): void {
		const lang = parseLang(s.lang);
		if (lang) {
			this.#appLang = lang;
			this.view.lang = lang;
		}
		if (s.phase !== "listening") this.view.level = 0;
		if (s.phase === "choices") {
			// A new list (first one, "mehr", narrowed) restarts the ring. A deadline extension while the user
			// speaks keeps the start, so the ring grows back a little instead of jumping to full.
			const key = (s.choices ?? []).map((c) => `${c.n}:${c.label}`).join("|");
			if (this.view.state?.phase !== "choices" || key !== this.#listKey || this.view.windowStart === undefined) {
				this.view.windowStart = Math.min(this.now(), s.deadline ?? Number.POSITIVE_INFINITY);
			}
			this.#listKey = key;
		} else {
			this.view.windowStart = undefined;
			this.#listKey = "";
		}
		this.view.state = s;
	}

	/** Fast attack, slow release, so short syllables still show and the rings do not flicker. */
	level(rms: number): void {
		if (this.view.state?.phase !== "listening") return;
		const x = Math.max(0, Math.min(1, Number.isFinite(rms) ? rms : 0));
		this.view.level = x >= this.view.level ? x : this.view.level * 0.6 + x * 0.4;
	}
}
