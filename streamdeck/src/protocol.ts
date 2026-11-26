/**
 * ac-voice IPC protocol v1: one UTF-8 JSON object per line ("\n") over a Unix domain socket.
 * Source of truth: Sources/ACVoiceCore/IPC.swift. The app owns the state machine; the plugin forwards
 * key edges and renders the `state` snapshots the app pushes.
 *
 * Encoding mirrors `IPC.line` byte for byte (sorted keys, absent optionals omitted, no escaped slashes),
 * decoding mirrors the Swift tolerance rules: unknown `t` values and unknown fields are ignored, numbers
 * may arrive as floats and are rounded half away from zero, a wrong type in an optional field drops only
 * that field. test/fixtures/ipc-v1.json is generated from the Swift codec and pins both directions.
 */

export const PROTOCOL_VERSION = 1;
/** Longest accepted line in bytes, newline excluded (`IPC.maxLineBytes`). Longer lines are dropped. */
export const MAX_LINE_BYTES = 65_536;

export const PHASES = ["idle", "listening", "processing", "choices", "success", "error"] as const;
/** Wire phases (`IPC.Phase`). The app maps retry to listening and opening to processing. */
export type Phase = (typeof PHASES)[number];

export interface Choice {
	/** 1-based number the user can say ("zwei") or click in the overlay. */
	n: number;
	/** Short label, at most 12 characters by contract. */
	label: string;
	/** Full name, e.g. "WWT: Website Relaunch [AGIL]". */
	detail?: string;
}

/** App -> plugin: full snapshot (`IPC.State`), sent on connect and on every change. */
export interface StateMsg {
	v: 1;
	t: "state";
	/** Monotonic per app run. The plugin drops snapshots with seq <= the last one of this connection. */
	seq: number;
	phase: Phase;
	/** Epoch ms when the phase started. */
	since: number;
	transcript?: string;
	/** Live target preview while listening ("WWT: Website Relaunch"). */
	preview?: string;
	choices?: Choice[];
	/** Candidates in total when more than shown. */
	total?: number;
	/** Epoch ms, end of the choices window. */
	deadline?: number;
	/** Status for success / error / hints, in the app language. */
	message?: string;
	/** listening only: false while the engine starts, true once the mic is hot. */
	micReady?: boolean;
	/** App language ("de", "en"). Older apps omit it; the plugin then follows the Stream Deck language. */
	lang?: string;
}

/** App -> plugin: smoothed mic level 0..1 while listening (`IPC.Level`). Not part of the snapshot. */
export interface LevelMsg {
	v: 1;
	t: "level";
	rms: number;
}

/** App -> plugin: answer to `ping` (`IPC.Pong`). */
export interface PongMsg {
	v: 1;
	t: "pong";
	id: string;
}

export type AppMsg = StateMsg | LevelMsg | PongMsg;

/**
 * Plugin -> app (`IPC.Command`). `v` is added by `encodeCmd`.
 * - press: key down; the app decides what it means for its phase (idle -> listen, listening -> end now, ...).
 * - release: key up; `pressId` names the press it ends, `heldMs` >= 600 after speech ends the utterance.
 * - choose: 1-based choice; `seq` is the snapshot the choice was rendered from (unused by this plugin).
 */
export type PluginCmd =
	| { t: "hello"; client: string; version: string }
	| { t: "press"; id: string; at: number }
	| { t: "release"; id: string; pressId?: string; heldMs: number }
	| { t: "choose"; id: string; index: number; seq?: number }
	| { t: "cancel"; id: string }
	| { t: "ping"; id: string };

// ---------- encoding ----------

/** JSON with keys sorted at every level and undefined members dropped, like Swift's `.sortedKeys`. */
export function sortedJson(value: unknown): string {
	return JSON.stringify(value, (_key, v: unknown) => {
		if (v && typeof v === "object" && !Array.isArray(v)) {
			const out: Record<string, unknown> = {};
			for (const k of Object.keys(v).sort()) {
				const x = (v as Record<string, unknown>)[k];
				if (x !== undefined) out[k] = x;
			}
			return out;
		}
		return v;
	});
}

/** One NDJSON line for a plugin command, newline included. Byte-identical to `IPC.line(_ cmd:)`. */
export function encodeCmd(cmd: PluginCmd): string {
	return sortedJson({ v: PROTOCOL_VERSION, ...cmd }) + "\n";
}

/** One NDJSON line for an app message, newline included. Byte-identical to `IPC.line(_ msg:)` (fake apps, tests). */
export function encodeAppMsg(msg: AppMsg): string {
	return sortedJson(msg) + "\n";
}

// ---------- decoding ----------

type Obj = Record<string, unknown>;

function parseObject(line: string): Obj | undefined {
	if (Buffer.byteLength(line, "utf8") > MAX_LINE_BYTES) return undefined;
	try {
		const o: unknown = JSON.parse(line);
		return o && typeof o === "object" && !Array.isArray(o) ? (o as Obj) : undefined;
	} catch {
		return undefined;
	}
}

/** `IPC.FlexInt`: an integer that may arrive as a float; rounds half away from zero like Swift's `rounded()`. */
export function flexInt(v: unknown): number | undefined {
	if (typeof v !== "number" || !Number.isFinite(v) || Math.abs(v) >= 9e15) return undefined;
	return Math.sign(v) * Math.round(Math.abs(v)) || 0;
}

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

function hasVersion(o: Obj): boolean {
	return flexInt(o.v) === PROTOCOL_VERSION;
}

/** Mirror of `IPC.decodeCommand`: undefined for junk, other versions, unknown types or missing required fields. */
export function decodeCmd(line: string): PluginCmd | undefined {
	const o = parseObject(line);
	if (!o || !hasVersion(o)) return undefined;
	const id = str(o.id);
	switch (o.t) {
		case "hello":
			return { t: "hello", client: str(o.client) ?? "?", version: str(o.version) ?? "?" };
		case "press":
			return id === undefined ? undefined : { t: "press", id, at: flexInt(o.at) ?? 0 };
		case "release": {
			if (id === undefined) return undefined;
			const pressId = str(o.pressId);
			return { t: "release", id, ...(pressId !== undefined ? { pressId } : {}), heldMs: flexInt(o.heldMs) ?? 0 };
		}
		case "choose": {
			const index = flexInt(o.index);
			if (id === undefined || index === undefined) return undefined;
			const seq = flexInt(o.seq);
			return { t: "choose", id, index, ...(seq !== undefined ? { seq } : {}) };
		}
		case "cancel":
			return id === undefined ? undefined : { t: "cancel", id };
		case "ping":
			return id === undefined ? undefined : { t: "ping", id };
		default:
			return undefined;
	}
}

function parseChoices(v: unknown): Choice[] | undefined {
	if (!Array.isArray(v)) return undefined;
	const out: Choice[] = [];
	for (const c of v) {
		if (!c || typeof c !== "object") continue;
		const n = flexInt((c as Obj).n);
		const label = str((c as Obj).label);
		if (n === undefined || label === undefined) continue;
		const detail = str((c as Obj).detail);
		out.push(detail !== undefined ? { n, label, detail } : { n, label });
	}
	return out;
}

function parseState(o: Obj): StateMsg | undefined {
	const seq = flexInt(o.seq);
	const since = flexInt(o.since);
	const phase = o.phase;
	if (seq === undefined || since === undefined || typeof phase !== "string" || !(PHASES as readonly string[]).includes(phase)) {
		return undefined;
	}
	const s: StateMsg = { v: 1, t: "state", seq, phase: phase as Phase, since };
	const transcript = str(o.transcript);
	if (transcript !== undefined) s.transcript = transcript;
	const preview = str(o.preview);
	if (preview !== undefined) s.preview = preview;
	const choices = parseChoices(o.choices);
	if (choices !== undefined) s.choices = choices;
	const total = flexInt(o.total);
	if (total !== undefined) s.total = total;
	const deadline = flexInt(o.deadline);
	if (deadline !== undefined) s.deadline = deadline;
	const message = str(o.message);
	if (message !== undefined) s.message = message;
	if (typeof o.micReady === "boolean") s.micReady = o.micReady;
	const lang = str(o.lang);
	if (lang !== undefined) s.lang = lang;
	return s;
}

/**
 * Parses one app line. Undefined for junk, other versions, unknown types, unknown phases or missing
 * required fields (state: seq, phase, since; level: rms; pong: id). Optional fields with a wrong type
 * are dropped, nulls count as absent.
 */
export function parseAppMsg(line: string): AppMsg | undefined {
	const o = parseObject(line);
	if (!o || !hasVersion(o)) return undefined;
	switch (o.t) {
		case "state":
			return parseState(o);
		case "level": {
			const rms = o.rms;
			if (typeof rms !== "number" || !Number.isFinite(rms)) return undefined;
			return { v: 1, t: "level", rms };
		}
		case "pong": {
			const id = str(o.id);
			return id === undefined ? undefined : { v: 1, t: "pong", id };
		}
		default:
			return undefined;
	}
}

// ---------- framing ----------

/**
 * Splits a byte stream into lines. Works on bytes, so a multi-byte character split across chunks stays
 * intact. A line longer than MAX_LINE_BYTES is dropped as a whole, the rest of the stream stays usable.
 */
export class LineSplitter {
	#parts: Buffer[] = [];
	#size = 0;
	#discarding = false;

	push(chunk: Buffer | string): string[] {
		const buf = typeof chunk === "string" ? Buffer.from(chunk, "utf8") : chunk;
		const lines: string[] = [];
		let start = 0;
		for (;;) {
			const nl = buf.indexOf(0x0a, start);
			if (nl < 0) break;
			const piece = buf.subarray(start, nl);
			if (!this.#discarding && this.#size + piece.length <= MAX_LINE_BYTES) {
				const line = this.#size === 0 ? piece : Buffer.concat([...this.#parts, piece]);
				lines.push(line.toString("utf8"));
			}
			this.#reset();
			start = nl + 1;
		}
		const rest = buf.subarray(start);
		if (rest.length > 0 && !this.#discarding) {
			if (this.#size + rest.length > MAX_LINE_BYTES) {
				this.#parts = [];
				this.#size = 0;
				this.#discarding = true;
			} else {
				this.#parts.push(Buffer.from(rest));
				this.#size += rest.length;
			}
		}
		return lines;
	}

	#reset(): void {
		this.#parts = [];
		this.#size = 0;
		this.#discarding = false;
	}
}
