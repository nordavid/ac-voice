import net from "node:net";
import { APP_MISSING } from "./i18n.js";
import { encodeCmd, LineSplitter, parseAppMsg, type PluginCmd, type StateMsg } from "./protocol.js";
import type { LinkStatus } from "./view.js";

export type { LinkStatus } from "./view.js";

/** Link error when LaunchServices cannot find the app; the key names it in its language (`KEY_TEXTS`). */
export { APP_MISSING };

export interface LinkEvents {
	/** `error` is set while the app is down for a known reason (launch failed). */
	status(status: LinkStatus, error?: string): void;
	/** Snapshots in order; older or repeated `seq` values of the same connection are dropped. */
	state(state: StateMsg): void;
	level(rms: number): void;
	/** The connected app stopped answering (true) or answers again (false). The link stays up either way. */
	busy?(busy: boolean): void;
}

export interface AppLinkOptions {
	socketPath: string;
	/** Sent in `hello`. */
	version: string;
	/** Starts the app (`open -g -b io.github.nordavid.acvoice`); rejects when it is not installed. */
	launch: () => Promise<void>;
	log?: (msg: string) => void;
	now?: () => number;
	connect?: (path: string) => net.Socket;
	/**
	 * How long a press made while the app is down waits for the socket. Matches the app's stale-press limit.
	 * A release for a press the app already got waits as long for a reconnect.
	 */
	queueMs?: number;
	/** Fast polling after a launch or `applicationDidLaunch`. */
	launchWindowMs?: number;
	fastRetryMs?: number;
	backoffMinMs?: number;
	backoffMaxMs?: number;
	/** A ping every `pingMs` while connected. */
	pingMs?: number;
	/**
	 * No answer to a ping within this time marks the app as busy (logged, `busy` event). It never drops the
	 * connection: on a local socket a dead app shows up as `close` at once, and a reconnect would only reach the
	 * same stalled process. Above the app's own 3 s bound for a Chrome Apple Event (REVIEW M4).
	 */
	busyAfterMs?: number;
	/**
	 * After a queued press goes out, an "idle" snapshot is held back this long: the app sends its idle snapshot on
	 * connect before it handles the press, and the key would flash idle between the spinner and "listening".
	 */
	idleHoldMs?: number;
	/**
	 * `setWanted(false)` keeps the connection this long. A page or profile switch with a voice key on both pages
	 * sends willDisappear and willAppear back to back; the link and the last snapshot survive it.
	 */
	lingerMs?: number;
}

export const LINK_DEFAULTS = {
	queueMs: 3000,
	launchWindowMs: 10_000,
	fastRetryMs: 50,
	backoffMinMs: 1000,
	backoffMaxMs: 10_000,
	pingMs: 5000,
	busyAfterMs: 4000,
	idleHoldMs: 150,
	lingerMs: 1000,
} as const;

interface Queued {
	id: string;
	at: number;
	/** keyUp arrived before the app did. */
	heldMs?: number;
	timer: NodeJS.Timeout;
}

/** A keyUp for a press the app got, while the link was down. */
interface PendingRelease {
	pressId: string;
	heldMs: number;
	at: number;
}

/**
 * Client side of the plugin <-> app link (NDJSON over the app's Unix socket).
 * - Holds one connection while a voice key is visible and reconnects with backoff (1 s doubling to 10 s).
 *   Without a visible key it lets go after `lingerMs`.
 * - A dead app shows up at once: ENOENT (never started), ECONNREFUSED (stale socket file) or `close`.
 * - A press while the app is down tries the socket first. If nothing listens, it launches the app via
 *   LaunchServices, keeps the press for at most `queueMs` and sends it with its original id and time once the
 *   socket accepts. One launch per window; a second press during the wait is ignored.
 * - A release for a press the app got waits up to `queueMs` for a reconnect, so the app ends the hold.
 * - Ping/pong only reports a busy app; any received line counts as a sign of life. Only `close` ends the link.
 * - Right after a queued press, an "idle" snapshot waits up to `idleHoldMs` for the app's answer to the press.
 */
export class AppLink {
	readonly #on: LinkEvents;
	readonly #o: Required<Omit<AppLinkOptions, "log" | "now" | "connect">>;
	readonly #log: (msg: string) => void;
	readonly #now: () => number;
	readonly #connectFn: (path: string) => net.Socket;

	#sock?: net.Socket;
	#connected = false;
	#status: LinkStatus = "offline";
	#error?: string;
	#want = false;
	#disposed = false;
	#retryTimer?: NodeJS.Timeout;
	#lingerTimer?: NodeJS.Timeout;
	#backoff: number;
	/** Poll fast until then (epoch ms): a launch or an app start is in progress. */
	#fastUntil = 0;
	#launchPending = false;
	#lastLaunchAt = Number.NEGATIVE_INFINITY;
	#queued?: Queued;
	/** Id of the last press the app got and no release followed yet. */
	#lastSent?: string;
	#pendingRelease?: PendingRelease;
	#lastSeq = -1;
	#counter = 0;
	#pingTimer?: NodeJS.Timeout;
	#pongTimer?: NodeJS.Timeout;
	#pendingPing?: string;
	#pingAt = 0;
	#busy = false;
	#holdUntil = 0;
	#held?: StateMsg;
	#holdTimer?: NodeJS.Timeout;

	constructor(on: LinkEvents, opts: AppLinkOptions) {
		this.#on = on;
		this.#o = {
			socketPath: opts.socketPath,
			version: opts.version,
			launch: opts.launch,
			queueMs: opts.queueMs ?? LINK_DEFAULTS.queueMs,
			launchWindowMs: opts.launchWindowMs ?? LINK_DEFAULTS.launchWindowMs,
			fastRetryMs: opts.fastRetryMs ?? LINK_DEFAULTS.fastRetryMs,
			backoffMinMs: opts.backoffMinMs ?? LINK_DEFAULTS.backoffMinMs,
			backoffMaxMs: opts.backoffMaxMs ?? LINK_DEFAULTS.backoffMaxMs,
			pingMs: opts.pingMs ?? LINK_DEFAULTS.pingMs,
			busyAfterMs: opts.busyAfterMs ?? LINK_DEFAULTS.busyAfterMs,
			idleHoldMs: opts.idleHoldMs ?? LINK_DEFAULTS.idleHoldMs,
			lingerMs: opts.lingerMs ?? LINK_DEFAULTS.lingerMs,
		};
		this.#log = opts.log ?? (() => {});
		this.#now = opts.now ?? Date.now;
		this.#connectFn = opts.connect ?? ((p) => net.createConnection({ path: p }));
		this.#backoff = this.#o.backoffMinMs;
	}

	get status(): LinkStatus {
		return this.#status;
	}

	get error(): string | undefined {
		return this.#error;
	}

	get online(): boolean {
		return this.#connected && this.#sock?.writable === true;
	}

	/** Connected, but the last ping got no answer within `busyAfterMs`. */
	get busy(): boolean {
		return this.#busy;
	}

	/** True while a voice key is visible: keep a connection. False lets go after `lingerMs`. */
	setWanted(want: boolean): void {
		if (this.#disposed || want === this.#want) return;
		this.#want = want;
		this.#clearLinger();
		if (want) {
			if (!this.#sock) this.#connect();
		} else {
			this.#lingerTimer = setTimeout(() => this.#letGo(), this.#o.lingerMs);
		}
	}

	/** `applicationDidLaunch` (ApplicationsToMonitor): the app process exists, its socket follows shortly. */
	appLaunched(): void {
		if (this.#disposed) return;
		this.#fastUntil = Math.max(this.#fastUntil, this.#now() + this.#o.launchWindowMs);
		if (this.#connected || !(this.#want || this.#queued)) return;
		this.#setStatus("launching");
		if (!this.#sock) this.#scheduleRetry(0);
	}

	/** `applicationDidTerminate`: stop fast polling; the socket close does the rest. */
	appTerminated(): void {
		this.#fastUntil = 0;
	}

	/** Key down. Returns the press id at once; the outcome arrives as status and state events. */
	press(): string {
		const id = this.#nextId();
		const at = this.#now();
		if (this.#send({ t: "press", id, at })) {
			this.#lastSent = id;
			return id;
		}
		if (this.#disposed) return id;
		if (this.#queued) {
			this.#log(`press ${id} ignored, ${this.#queued.id} waits for the app`);
			return id;
		}
		this.#queued = { id, at, timer: setTimeout(() => this.#expire(id), this.#o.queueMs) };
		this.#setStatus("launching");
		// Try the socket first: a reconnect gap needs no launch. A failed attempt launches (#onClosed).
		if (!this.#sock) this.#connect();
		return id;
	}

	/**
	 * Key up for the press `pressId`. Kept with a queued press. For a press the app got, it waits up to `queueMs`
	 * for a reconnect (the app would keep end-of-utterance detection suspended otherwise). While the link is down,
	 * a release for a press the app never got is dropped.
	 */
	release(pressId: string, heldMs: number): void {
		const held = Math.max(0, Math.round(heldMs));
		if (this.#queued?.id === pressId) {
			this.#queued.heldMs = held;
			return;
		}
		const appGotPress = this.#lastSent === pressId;
		if (appGotPress) this.#lastSent = undefined;
		if (this.#send({ t: "release", id: this.#nextId(), pressId, heldMs: held })) return;
		if (!appGotPress || this.#disposed) return;
		this.#pendingRelease = { pressId, heldMs: held, at: this.#now() };
		this.#log(`release for ${pressId} waits for the app`);
	}

	dispose(): void {
		this.#disposed = true;
		this.#want = false;
		this.#clearRetry();
		this.#clearLinger();
		this.#dropQueue("disposed");
		this.#pendingRelease = undefined;
		this.#detach()?.destroy();
	}

	// ---------- connection ----------

	#connect(): void {
		this.#clearRetry();
		if (this.#sock || this.#disposed) return;
		let sock: net.Socket;
		try {
			sock = this.#connectFn(this.#o.socketPath);
		} catch (e) {
			this.#log(`connect failed: ${(e as Error).message}`);
			this.#onClosed(undefined);
			return;
		}
		this.#sock = sock;
		const lines = new LineSplitter();
		sock.once("connect", () => this.#onConnected(sock));
		sock.on("data", (chunk: Buffer) => {
			if (this.#sock !== sock) return;
			for (const line of lines.push(chunk)) this.#onLine(line);
		});
		sock.on("error", (e: NodeJS.ErrnoException) => {
			// ENOENT: the app never created its socket. ECONNREFUSED: stale socket file after a crash.
			if (this.#sock !== sock) return;
			if (e.code !== "ENOENT" && e.code !== "ECONNREFUSED") this.#log(`socket error: ${e.code ?? e.message}`);
		});
		sock.on("close", () => this.#onClosed(sock));
	}

	/**
	 * Forgets the current socket at once, so a `close` that follows is ignored and a new connect can start in the
	 * same tick. Returns the socket for the caller to destroy.
	 */
	#detach(): net.Socket | undefined {
		const sock = this.#sock;
		this.#sock = undefined;
		this.#connected = false;
		this.#busy = false;
		this.#stopPing();
		this.#clearHold();
		return sock;
	}

	/** No voice key for `lingerMs`: close the connection and stop polling. */
	#letGo(): void {
		this.#lingerTimer = undefined;
		if (this.#want || this.#disposed) return;
		this.#clearRetry();
		this.#dropQueue("no key visible");
		const sock = this.#detach();
		sock?.destroy();
		this.#setStatus("offline", this.#error);
	}

	#onConnected(sock: net.Socket): void {
		if (this.#sock !== sock || this.#disposed) return;
		this.#connected = true;
		this.#backoff = this.#o.backoffMinMs;
		this.#fastUntil = 0;
		// The launch window only guards the gap until the first connect; after a quit or crash a press launches again.
		this.#lastLaunchAt = Number.NEGATIVE_INFINITY;
		this.#lastSeq = -1;
		this.#setStatus("online");
		this.#send({ t: "hello", client: "streamdeck", version: this.#o.version });
		// A restarted app ignores a release whose press it never saw (pressId mismatch), so this is safe.
		const r = this.#pendingRelease;
		this.#pendingRelease = undefined;
		if (r) {
			if (this.#now() - r.at <= this.#o.queueMs) this.#send({ t: "release", id: this.#nextId(), pressId: r.pressId, heldMs: r.heldMs });
			else this.#log(`release for ${r.pressId} dropped, too old`);
		}
		const q = this.#queued;
		this.#queued = undefined;
		if (q) {
			clearTimeout(q.timer);
			if (this.#now() - q.at <= this.#o.queueMs) {
				this.#send({ t: "press", id: q.id, at: q.at });
				this.#holdUntil = this.#now() + this.#o.idleHoldMs;
				if (q.heldMs !== undefined) this.#send({ t: "release", id: this.#nextId(), pressId: q.id, heldMs: q.heldMs });
				else this.#lastSent = q.id;
			} else {
				this.#log(`press ${q.id} dropped, too old`);
			}
		}
		this.#startPing();
	}

	#onClosed(sock: net.Socket | undefined): void {
		if (sock && this.#sock !== sock) return;
		const wasConnected = this.#connected;
		this.#detach();
		if (this.#disposed) return;
		if (wasConnected) this.#log("app disconnected");
		const now = this.#now();
		if (this.#queued && !this.#launchPending && now - this.#lastLaunchAt > this.#o.launchWindowMs) this.#launch();
		const fast = this.#queued !== undefined || now < this.#fastUntil;
		if (fast) this.#setStatus("launching");
		else this.#setStatus("offline", this.#error);
		if (this.#want || this.#queued) {
			this.#scheduleRetry(fast ? this.#o.fastRetryMs : this.#backoff);
			if (!fast) this.#backoff = Math.min(this.#backoff * 2, this.#o.backoffMaxMs);
		}
	}

	#launch(): void {
		const now = this.#now();
		this.#launchPending = true;
		this.#lastLaunchAt = now;
		this.#fastUntil = Math.max(this.#fastUntil, now + this.#o.launchWindowMs);
		this.#log("launching the app");
		let p: Promise<void>;
		try {
			p = this.#o.launch();
		} catch (e) {
			p = Promise.reject(e);
		}
		p.then(
			() => {
				this.#launchPending = false;
			},
			(e: unknown) => {
				this.#launchPending = false;
				if (this.#disposed) return;
				this.#log(`launch failed: ${e instanceof Error ? e.message : String(e)}`);
				this.#fastUntil = 0;
				// The next press tries again (the app may be installed by then).
				this.#lastLaunchAt = Number.NEGATIVE_INFINITY;
				this.#dropQueue("launch failed");
				if (!this.#connected) this.#setStatus("offline", APP_MISSING);
			},
		);
	}

	#scheduleRetry(ms: number): void {
		this.#clearRetry();
		this.#retryTimer = setTimeout(() => {
			this.#retryTimer = undefined;
			if (!this.#sock && (this.#want || this.#queued)) this.#connect();
		}, ms);
	}

	#clearRetry(): void {
		if (this.#retryTimer) clearTimeout(this.#retryTimer);
		this.#retryTimer = undefined;
	}

	#clearLinger(): void {
		if (this.#lingerTimer) clearTimeout(this.#lingerTimer);
		this.#lingerTimer = undefined;
	}

	#expire(id: string): void {
		if (this.#queued?.id !== id) return;
		this.#queued = undefined;
		this.#log(`press ${id} dropped, app not reachable within ${this.#o.queueMs} ms`);
		if (!this.#connected && this.#now() >= this.#fastUntil) this.#setStatus("offline", this.#error);
	}

	#dropQueue(reason: string): void {
		if (!this.#queued) return;
		clearTimeout(this.#queued.timer);
		this.#log(`press ${this.#queued.id} dropped, ${reason}`);
		this.#queued = undefined;
	}

	// ---------- traffic ----------

	#onLine(line: string): void {
		// Any line proves the app is alive.
		this.#pendingPing = undefined;
		if (this.#pongTimer) clearTimeout(this.#pongTimer);
		this.#pongTimer = undefined;
		if (this.#busy) {
			this.#busy = false;
			this.#log(`app answers again after ${this.#now() - this.#pingAt} ms`);
			this.#on.busy?.(false);
		}
		const msg = parseAppMsg(line);
		if (!msg) return;
		if (msg.t === "state") {
			if (msg.seq <= this.#lastSeq) return;
			this.#lastSeq = msg.seq;
			if (msg.phase === "idle" && this.#now() < this.#holdUntil) {
				this.#held = msg;
				this.#holdTimer ??= setTimeout(() => this.#releaseHeld(), Math.max(0, this.#holdUntil - this.#now()));
				return;
			}
			this.#clearHold();
			this.#on.state(msg);
		} else if (msg.t === "level") {
			this.#on.level(msg.rms);
		}
	}

	/** The app stayed idle (it dropped the press as stale, say): show it. */
	#releaseHeld(): void {
		const held = this.#held;
		this.#clearHold();
		if (held && this.#connected) this.#on.state(held);
	}

	#clearHold(): void {
		if (this.#holdTimer) clearTimeout(this.#holdTimer);
		this.#holdTimer = undefined;
		this.#held = undefined;
		this.#holdUntil = 0;
	}

	#startPing(): void {
		this.#stopPing();
		this.#pingTimer = setInterval(() => this.#ping(), this.#o.pingMs);
	}

	#stopPing(): void {
		if (this.#pingTimer) clearInterval(this.#pingTimer);
		if (this.#pongTimer) clearTimeout(this.#pongTimer);
		this.#pingTimer = undefined;
		this.#pongTimer = undefined;
		this.#pendingPing = undefined;
	}

	/** One ping at a time; while the app stays silent no further ping goes out. */
	#ping(): void {
		if (!this.online || this.#pendingPing) return;
		const id = this.#nextId();
		this.#pendingPing = id;
		this.#pingAt = this.#now();
		this.#send({ t: "ping", id });
		const sock = this.#sock;
		this.#pongTimer = setTimeout(() => {
			this.#pongTimer = undefined;
			if (this.#pendingPing !== id || this.#sock !== sock) return;
			// Keep the socket, the status and the last snapshot: the app is busy (an Apple Event, a Keychain or
			// Automation prompt), not gone. Commands wait in the socket buffer until it reads again.
			this.#busy = true;
			this.#log(`app busy, no answer within ${this.#o.busyAfterMs} ms`);
			this.#on.busy?.(true);
		}, this.#o.busyAfterMs);
	}

	#send(cmd: PluginCmd): boolean {
		if (!this.online) return false;
		this.#sock!.write(encodeCmd(cmd));
		return true;
	}

	#nextId(): string {
		return `sd-${++this.#counter}`;
	}

	#setStatus(s: LinkStatus, error?: string): void {
		if (s === this.#status && error === this.#error) return;
		this.#status = s;
		this.#error = error;
		this.#on.status(s, error);
	}
}
