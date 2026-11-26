import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { type AppMsg, decodeCmd, encodeAppMsg, LineSplitter, type PluginCmd, type StateMsg } from "../../src/protocol.js";

export interface Received {
	cmd: PluginCmd;
	at: number;
	client: number;
}

/** A temp directory with a socket path that fits sun_path (104 bytes). */
export function tempSocket(): { dir: string; sock: string; cleanup: () => void } {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "acv-"));
	const sock = path.join(dir, "ipc.sock");
	if (Buffer.byteLength(sock) >= 104) throw new Error(`socket path too long: ${sock.length}`);
	return { dir, sock, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

/** Leaves a socket file nobody listens on (like a crashed app): connect fails with ECONNREFUSED. */
export async function makeStaleSocket(sock: string): Promise<void> {
	const tmp = `${sock}.live`;
	const s = net.createServer();
	await new Promise<void>((r) => s.listen(tmp, r));
	fs.linkSync(tmp, sock);
	await new Promise<void>((r) => s.close(() => r()));
}

/**
 * Fake AC Voice app: NDJSON server on a Unix socket, speaking protocol v1 like the Swift IPCServer.
 * Sends a snapshot on connect, answers pings (unless told not to) and records every command.
 * `stall()` plays a blocked main thread: the kernel still accepts and buffers, the app reads and writes nothing.
 */
export class FakeApp {
	readonly received: Received[] = [];
	readonly clients = new Set<net.Socket>();
	answerPing = true;
	sendStateOnConnect = true;
	connections = 0;
	seq = 0;
	#server?: net.Server;
	#waiters: { pred: (r: Received) => boolean; resolve: (r: Received) => void }[] = [];
	#stalled = false;
	/** Connections accepted during a stall; they get their snapshot on `resume()`. */
	#greetLater: net.Socket[] = [];

	get stalled(): boolean {
		return this.#stalled;
	}

	/** Stops reading and writing until `resume()`. Commands stay in the socket buffer, like on a blocked main thread. */
	stall(): void {
		this.#stalled = true;
		for (const c of this.clients) c.pause();
	}

	resume(): void {
		this.#stalled = false;
		for (const c of this.#greetLater.splice(0)) if (!c.destroyed) this.#greet(c);
		for (const c of this.clients) c.resume();
	}

	constructor(readonly sock: string) {}

	get listening(): boolean {
		return this.#server?.listening === true;
	}

	async start(): Promise<void> {
		fs.rmSync(this.sock, { force: true });
		const server = net.createServer((c) => this.#accept(c));
		this.#server = server;
		await new Promise<void>((resolve, reject) => {
			server.once("error", reject);
			server.listen(this.sock, () => resolve());
		});
	}

	async stop(): Promise<void> {
		const s = this.#server;
		this.#server = undefined;
		this.#stalled = false;
		this.#greetLater = [];
		for (const c of this.clients) c.destroy();
		this.clients.clear();
		if (s) await new Promise<void>((r) => s.close(() => r()));
	}

	state(phase: StateMsg["phase"], extra: Partial<StateMsg> = {}): StateMsg {
		const s: StateMsg = { v: 1, t: "state", seq: ++this.seq, phase, since: Date.now(), ...extra };
		this.broadcast(s);
		return s;
	}

	broadcast(msg: AppMsg | string): void {
		if (this.#stalled) throw new Error("FakeApp is stalled; resume() first");
		const line = typeof msg === "string" ? msg : encodeAppMsg(msg);
		for (const c of this.clients) c.write(line);
	}

	commands(t?: PluginCmd["t"]): PluginCmd[] {
		return this.received.map((r) => r.cmd).filter((c) => !t || c.t === t);
	}

	waitFor(pred: (r: Received) => boolean, timeoutMs = 2000): Promise<Received> {
		const hit = this.received.find(pred);
		if (hit) return Promise.resolve(hit);
		return new Promise((resolve, reject) => {
			const w = { pred, resolve };
			const timer = setTimeout(() => {
				this.#waiters = this.#waiters.filter((x) => x !== w);
				reject(new Error(`timeout waiting for command; got ${JSON.stringify(this.commands())}`));
			}, timeoutMs);
			w.resolve = (r) => {
				clearTimeout(timer);
				resolve(r);
			};
			this.#waiters.push(w);
		});
	}

	#accept(c: net.Socket): void {
		const client = ++this.connections;
		this.clients.add(c);
		c.on("close", () => this.clients.delete(c));
		c.on("error", () => {});
		const lines = new LineSplitter();
		c.on("data", (chunk: Buffer) => {
			for (const line of lines.push(chunk)) {
				const cmd = decodeCmd(line);
				if (!cmd) continue;
				const r = { cmd, at: performance.now(), client };
				this.received.push(r);
				if (cmd.t === "ping" && this.answerPing) c.write(encodeAppMsg({ v: 1, t: "pong", id: cmd.id }));
				for (const w of [...this.#waiters]) {
					if (w.pred(r)) {
						this.#waiters = this.#waiters.filter((x) => x !== w);
						w.resolve(r);
					}
				}
			}
		});
		if (this.#stalled) {
			c.pause();
			this.#greetLater.push(c);
		} else {
			this.#greet(c);
		}
	}

	#greet(c: net.Socket): void {
		if (this.sendStateOnConnect) c.write(encodeAppMsg({ v: 1, t: "state", seq: ++this.seq, phase: "idle", since: Date.now() }));
	}
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Polls `cond` every 5 ms until it holds. */
export async function until(cond: () => boolean, timeoutMs = 2000, what = "condition"): Promise<void> {
	const end = Date.now() + timeoutMs;
	while (!cond()) {
		if (Date.now() > end) throw new Error(`timeout waiting for ${what}`);
		await sleep(5);
	}
}
