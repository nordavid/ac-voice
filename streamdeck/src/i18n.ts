/**
 * The plugin's own words in the app language. The app sends its language with every snapshot (`state.lang`, the
 * Swift `AppLanguage`); before the first snapshot, and with an app that does not send it, the plugin follows the
 * Stream Deck language. Same rule as the app: German stays German, every other language gets English.
 */
export type Lang = "de" | "en";

/** "de", "de-DE", "de_DE" -> "de"; "en", "en-US" -> "en"; anything else -> undefined. */
export function parseLang(code: unknown): Lang | undefined {
	if (typeof code !== "string") return undefined;
	const primary = code.trim().toLowerCase().split(/[-_]/)[0];
	return primary === "de" || primary === "en" ? primary : undefined;
}

/** The plugin language for a Stream Deck language ("de", "en", "fr", "zh_CN", ...). */
export function fromStreamDeck(language: unknown): Lang {
	return parseLang(language) === "de" ? "de" : "en";
}

/**
 * Why the app cannot start, as `AppLink` reports it (`View.linkError`). A reason code, not a caption: the key
 * names it in the current language (`KeyText.appMissing`).
 */
export const APP_MISSING = "app-missing";

/** Captions on the key, one or two words each. */
export interface KeyText {
	brand: string;
	/** Offline: a press starts the app. */
	start: string;
	/** The app is starting, or connected without a snapshot yet. */
	starting: string;
	/** LaunchServices cannot find the app. */
	appMissing: string;
}

export const KEY_TEXTS: Readonly<Record<Lang, Readonly<KeyText>>> = {
	de: { brand: "AC", start: "Start", starting: "Startet", appMissing: "App fehlt" },
	en: { brand: "AC", start: "Start", starting: "Starting", appMissing: "App missing" },
};

/** The caption for a link error: a known reason code in `lang`, anything else as it is. */
export function linkErrorText(error: string, lang: Lang): string {
	return error === APP_MISSING ? KEY_TEXTS[lang].appMissing : error;
}
