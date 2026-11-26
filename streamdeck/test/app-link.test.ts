import net from "node:net";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { APP_MISSING, AppLink, type AppLinkOptions, LINK_DEFAULTS, type LinkStatus } from "../src/app-link.js";
import { APP_BUNDLE_ID } from "../src/config.js";
import { createLauncher, type ExecFileError, type ExecFileFn, LAUNCH_TIMEOUT_MS, OPEN_BINARY } from "../src/launcher.js";
import type { StateMsg } from "../src/protocol.js";
import { FakeApp, makeStaleSocket, sleep, tempSocket, until } from "./helpers/fake-app.js";

// Short timings keep the suite fast; the production defaults are LINK_DEFAULTS.
const FAST: Partial<AppLinkOptions> = {
	queueMs: 300,
	launchWindowMs: 1000,
	fastRetryMs: 10,
	backoffMinMs: 40,
	backoffMaxMs: 200,
	pingMs: 100,
	busyAfterMs: 60,
	lingerMs: 30,
};

interface Rig {
	link: AppLink;
	app: FakeApp;
	sock: string;
	statuses: { s: LinkStatus; error?: string }[];
	states: StateMsg[];
	levels: number[];
	busy: boolean[];
	/** Called inside the link's status event (same tick). */
	onStatus?: (s: LinkStatus) => void;
	logs: string[];
	launches: number[];
	connects: number[];
}

let cleanup: (() => void)[] = [];

function rig(opts: Partial<AppLinkOptions> & { onLaunch?: (r: Rig) => Promise<void> | void } = {}): Rig {
	const t = tempSocket();
	const app = new FakeApp(t.sock);
	const r = { app, sock: t.sock, statuses: [], states: [], levels: [], busy: [], logs: [], launches: [], connects: [] } as unknown as Rig;
	const { onLaunch, ...linkOpts } = opts;
	r.link = new AppLink(
		{
			status: (s, error) => {
				r.statuses.push({ s, error });
				r.onStatus?.(s);
			},
			state: (s) => r.states.push(s),
			level: (x) => r.levels.push(x),
			busy: (b) => r.busy.push(b),
		},
		{
			socketPath: t.sock,
			version: "0.1.0",
			log: (m) => r.logs.push(m),
			launch: async () => {
				r.launches.push(Date.now());
				await onLaunch?.(r);
			},
			connect: (p) => {
				r.connects.push(Date.now());
				return net.createConnection({ path: p });
			},
			...FAST,
			...linkOpts,
		},
	);
	cleanup.push(() => r.link.dispose(), () => void app.stop(), t.cleanup);
	return r;
}

const last = (r: Rig) => r.statuses.at(-1);

beforeEach(() => {
	cleanup = [];
});

afterEach(async () => {
	for (const f of cleanup.reverse()) f();
	await sleep(5);
});

describe("AppLink, app running", () => {
	it("connects while a key is visible, says hello and forwards snapshots in order", async () => {
		const r = rig();
		await r.app.start();
		r.link.setWanted(true);
		await r.app.waitFor((x) => x.cmd.t === "hello");
		expect(r.app.commands("hello")).toEqual([{ t: "hello", client: "streamdeck", version: "0.1.0" }]);
		await until(() => r.states.length === 1, 1000, "first snapshot");
		expect(r.link.status).toBe("online");
		expect(r.statuses.map((s) => s.s)).toEqual(["online"]);

		r.app.broadcast({ v: 1, t: "state", seq: 1, phase: "listening", since: 1 }); // repeated seq
		r.app.broadcast("garbage\n");
		r.app.broadcast('{"v":1,"t":"future","x":1}\n');
		r.app.state("listening", { micReady: true });
		r.app.broadcast({ v: 1, t: "level", rms: 0.42 });
		r.app.broadcast({ v: 1, t: "state", seq: 0, phase: "error", since: 1 }); // older seq
		r.app.state("processing");
		await until(() => r.states.length === 3, 1000, "snapshots");
		expect(r.states.map((s) => [s.seq, s.phase])).toEqual([
			[1, "idle"],
			[2, "listening"],
			[3, "processing"],
		]);
		expect(r.levels).toEqual([0.42]);
	});

	it("sends press with id and time, release with the press id and held time", async () => {
		const r = rig();
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.link.online, 1000, "online");
		const before = Date.now();
		const id = r.link.press();
		const after = Date.now();
		const press = await r.app.waitFor((x) => x.cmd.t === "press");
		expect(press.cmd).toMatchObject({ t: "press", id });
		const at = (press.cmd as { at: number }).at;
		expect(at).toBeGreaterThanOrEqual(before);
		expect(at).toBeLessThanOrEqual(after);
		r.link.release(id, 812.4);
		const rel = await r.app.waitFor((x) => x.cmd.t === "release");
		expect(rel.cmd).toEqual({ t: "release", id: expect.stringMatching(/^sd-\d+$/), pressId: id, heldMs: 812 });
		expect((rel.cmd as { id: string }).id).not.toBe(id);
		expect(r.launches).toHaveLength(0);
	});

	it("keeps a live app connected with ping/pong", async () => {
		const r = rig();
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.link.online, 1000, "online");
		await sleep(450);
		expect(r.app.commands("ping").length).toBeGreaterThanOrEqual(3);
		expect(r.app.connections).toBe(1);
		expect(r.link.status).toBe("online");
	});

	// Review finding 1: a missed pong used to destroy the socket. The key went "Start", then "Startet", the
	// connection churned and a keyUp during the gap got lost, although the app only waited for Chrome or a prompt.
	it("keeps a stalled app connected: same face, no reconnect, the release arrives after the stall", async () => {
		const r = rig();
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.states.length === 1, 1000, "first snapshot");
		const id = r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press");
		r.app.state("listening", { micReady: true });
		await until(() => r.states.length === 2, 1000, "listening");

		r.app.stall();
		await until(() => r.link.busy, 1000, "busy");
		await sleep(10 * 100); // ten ping periods, more than ten busy timeouts
		r.link.release(id, 900);
		await sleep(50);
		expect(r.app.commands("release")).toEqual([]); // the app reads nothing while it stalls
		expect(r.link.status).toBe("online");
		expect(r.link.online).toBe(true);
		expect(r.statuses.map((s) => s.s)).toEqual(["online"]);
		expect(r.states.at(-1)!.phase).toBe("listening");
		expect(r.app.connections).toBe(1);
		expect(r.busy).toEqual([true]);
		expect(r.logs.filter((l) => l.startsWith("app busy"))).toEqual(["app busy, no answer within 60 ms"]);

		r.app.resume();
		const rel = await r.app.waitFor((x) => x.cmd.t === "release", 1000);
		expect(rel.cmd).toMatchObject({ pressId: id, heldMs: 900 });
		await until(() => !r.link.busy, 1000, "answers again");
		expect(r.busy).toEqual([true, false]);
		expect(r.logs.some((l) => /^app answers again after \d+ ms$/.test(l))).toBe(true);
		expect(r.app.commands("ping").length).toBeGreaterThanOrEqual(1);
		expect(r.app.connections).toBe(1);
		expect(r.statuses.map((s) => s.s)).toEqual(["online"]);
		expect(r.launches).toHaveLength(0);
	});

	it("marks the app busy only past the app's own 3 s bound for a Chrome Apple Event (REVIEW M4)", () => {
		expect(LINK_DEFAULTS.busyAfterMs).toBeGreaterThan(3000);
		expect(LINK_DEFAULTS.busyAfterMs).toBeLessThan(LINK_DEFAULTS.pingMs);
	});

	it("disconnects when no key is visible and stays quiet", async () => {
		const r = rig();
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.link.online, 1000, "online");
		r.link.setWanted(false);
		await until(() => r.app.clients.size === 0, 1000, "disconnect");
		const n = r.connects.length;
		await sleep(250);
		expect(r.connects.length).toBe(n);
		expect(r.link.status).toBe("offline");
	});

	// Review finding 3: setWanted(false) + setWanted(true) before the socket's close used to cost a 1 s offline gap.
	it("keeps the link and the snapshot through a page switch (willDisappear and willAppear back to back)", async () => {
		const r = rig({ lingerMs: 100, backoffMinMs: 5000, backoffMaxMs: 5000 });
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.states.length === 1, 1000, "first snapshot");
		r.link.setWanted(false);
		r.link.setWanted(true);
		await sleep(30);
		r.link.setWanted(false); // separate events a few ms apart
		await sleep(20);
		r.link.setWanted(true);
		await sleep(200);
		expect(r.app.connections).toBe(1);
		expect(r.app.clients.size).toBe(1);
		expect(r.statuses.map((s) => s.s)).toEqual(["online"]);
		expect(r.app.commands("hello")).toHaveLength(1);
	});

	it("tears the socket down at once after the linger, so a key that comes back in the same tick connects at once", async () => {
		const r = rig({ lingerMs: 20, backoffMinMs: 5000, backoffMaxMs: 5000 });
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.states.length === 1, 1000, "first snapshot");
		let again = false;
		r.onStatus = (s) => {
			if (s !== "offline" || again) return;
			again = true;
			r.link.setWanted(true); // same tick as the teardown, before the old socket's close event
		};
		r.link.setWanted(false);
		await until(() => r.app.connections === 2 && r.link.online, 500, "reconnect without the 5 s backoff");
		expect(r.statuses.map((s) => s.s)).toEqual(["online", "offline", "online"]);
		await sleep(50);
		expect(r.link.status).toBe("online"); // the old socket's close does not touch the new one
		expect(r.app.clients.size).toBe(1);
	});

	it("keeps a queued press through a page switch", async () => {
		const r = rig({ lingerMs: 100, onLaunch: (x) => void sleep(40).then(() => x.app.start()) });
		r.link.setWanted(true);
		const id = r.link.press();
		r.link.setWanted(false);
		r.link.setWanted(true);
		const press = await r.app.waitFor((x) => x.cmd.t === "press", 2000);
		expect(press.cmd).toMatchObject({ id });
	});

	it("drops oversized lines and keeps the stream usable", async () => {
		const r = rig();
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.states.length === 1, 1000, "first snapshot");
		r.app.broadcast(`{"v":1,"t":"state","seq":50,"phase":"error","since":1,"message":"${"x".repeat(70_000)}"}\n`);
		r.app.state("success");
		await until(() => r.states.length === 2, 1000, "next snapshot");
		expect(r.states[1]!.phase).toBe("success");
	});
});

describe("AppLink, app down", () => {
	it("launches on press when the socket is missing and delivers the queued press and release", async () => {
		const r = rig({ onLaunch: (x) => void sleep(60).then(() => x.app.start()) });
		r.link.setWanted(true);
		await until(() => r.connects.length >= 1 && r.link.status === "offline", 1000, "offline");
		const before = Date.now();
		const id = r.link.press();
		expect(r.link.status).toBe("launching");
		r.link.release(id, 120);
		const press = await r.app.waitFor((x) => x.cmd.t === "press", 2000);
		expect(r.launches).toHaveLength(1);
		expect(press.cmd).toMatchObject({ t: "press", id });
		expect((press.cmd as { at: number }).at).toBeGreaterThanOrEqual(before);
		expect((press.cmd as { at: number }).at).toBeLessThan(before + 20);
		const rel = await r.app.waitFor((x) => x.cmd.t === "release");
		expect(rel.cmd).toMatchObject({ pressId: id, heldMs: 120 });
		expect(r.app.commands().map((c) => c.t)).toEqual(["hello", "press", "release"]);
		expect(r.statuses.map((s) => s.s)).toEqual(["launching", "online"]); // "offline" is the initial status, not an event
	});

	it("treats a stale socket file (ECONNREFUSED) like a missing app", async () => {
		const r = rig({ onLaunch: (x) => void sleep(30).then(() => x.app.start()) });
		await makeStaleSocket(r.sock);
		const id = r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press" && (x.cmd as { id: string }).id === id, 2000);
		expect(r.launches).toHaveLength(1);
		expect(r.logs.filter((l) => l.startsWith("socket error"))).toEqual([]);
	});

	it("sends a press during a reconnect gap without launching", async () => {
		const r = rig({ backoffMinMs: 5000 });
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.link.online, 1000, "online");
		for (const c of r.app.clients) c.destroy();
		await until(() => r.link.status === "offline", 1000, "offline");
		const id = r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press" && (x.cmd as { id: string }).id === id, 1000);
		expect(r.launches).toHaveLength(0);
	});

	// Review finding 2: a keyUp while the link was down got lost, and the app kept end-of-utterance detection
	// suspended until its 8 s limit.
	it("sends a release that missed the link right after the reconnect", async () => {
		const r = rig();
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.link.online, 1000, "online");
		const id = r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press");
		for (const c of r.app.clients) c.destroy();
		await until(() => !r.link.online, 1000, "link down");
		r.link.release(id, 700);
		expect(r.logs).toContain(`release for ${id} waits for the app`);
		const rel = await r.app.waitFor((x) => x.cmd.t === "release", 1000);
		expect(rel.cmd).toEqual({ t: "release", id: expect.stringMatching(/^sd-\d+$/), pressId: id, heldMs: 700 });
		expect(rel.client).toBe(2);
		expect(r.app.received.filter((x) => x.client === 2).map((x) => x.cmd.t)).toEqual(["hello", "release"]);
		await sleep(250); // a later reconnect does not send it again
		for (const c of r.app.clients) c.destroy();
		await until(() => r.app.connections === 3 && r.link.online, 1000, "third connection");
		await sleep(30);
		expect(r.app.commands("release")).toHaveLength(1);
		expect(r.launches).toHaveLength(0);
	});

	it("sends the waiting release before a new queued press", async () => {
		const r = rig({ backoffMinMs: 5000, backoffMaxMs: 5000 });
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.link.online, 1000, "online");
		const first = r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press");
		for (const c of r.app.clients) c.destroy();
		await until(() => !r.link.online, 1000, "link down");
		r.link.release(first, 300);
		const second = r.link.press(); // tries the socket at once
		await r.app.waitFor((x) => x.cmd.t === "press" && (x.cmd as { id: string }).id === second, 1000);
		const cmds = r.app.received.filter((x) => x.client === 2).map((x) => x.cmd);
		expect(cmds.map((c) => c.t)).toEqual(["hello", "release", "press"]);
		expect(cmds[1]).toMatchObject({ pressId: first, heldMs: 300 });
		expect(r.launches).toHaveLength(0);
	});

	it("drops a waiting release older than the queue limit", async () => {
		const r = rig({ queueMs: 100, backoffMinMs: 300, backoffMaxMs: 300 });
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.link.online, 1000, "online");
		const id = r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press");
		for (const c of r.app.clients) c.destroy();
		await until(() => !r.link.online, 1000, "link down");
		r.link.release(id, 500);
		await until(() => r.app.connections === 2 && r.link.online, 1500, "reconnect");
		await sleep(30);
		expect(r.app.commands("release")).toEqual([]);
		expect(r.logs).toContain(`release for ${id} dropped, too old`);
	});

	it("launches once per window and ignores a second press while waiting", async () => {
		const r = rig({ queueMs: 1000 });
		const first = r.link.press();
		await until(() => r.launches.length === 1, 1000, "launch");
		const second = r.link.press();
		await sleep(80);
		expect(r.launches).toHaveLength(1);
		r.link.release(second, 50); // release of the ignored press is dropped
		await r.app.start();
		await r.app.waitFor((x) => x.cmd.t === "press", 1000);
		await sleep(30);
		expect(r.app.commands("press")).toEqual([{ t: "press", id: first, at: expect.any(Number) }]);
		expect(r.app.commands("release")).toEqual([]);
		expect(r.logs.some((l) => l.includes(`press ${second} ignored`))).toBe(true);
	});

	it("holds the connect snapshot back after a queued press, so the key never flashes idle", async () => {
		const r = rig({ idleHoldMs: 150, onLaunch: (x) => void sleep(20).then(() => x.app.start()) });
		r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press", 2000);
		r.app.state("listening", { micReady: false });
		await until(() => r.states.length === 1, 1000, "listening");
		await sleep(200);
		expect(r.states.map((s) => s.phase)).toEqual(["listening"]);

		// The app stays idle (it dropped the press): idle shows after the hold.
		const q = rig({ idleHoldMs: 150, onLaunch: (x) => void sleep(20).then(() => x.app.start()) });
		q.link.press();
		await q.app.waitFor((x) => x.cmd.t === "press", 2000);
		const t = Date.now();
		await until(() => q.states.length === 1, 1000, "held idle");
		expect(q.states[0]!.phase).toBe("idle");
		expect(Date.now() - t).toBeGreaterThanOrEqual(100);
	});

	it("launches again on the next press after the launched app quit", async () => {
		const r = rig({ launchWindowMs: 60_000, onLaunch: (x) => void sleep(20).then(() => x.app.start()) });
		r.link.setWanted(true);
		r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press", 2000);
		await r.app.stop();
		await until(() => r.link.status === "offline", 1000, "offline");
		const id = r.link.press();
		await r.app.waitFor((x) => x.cmd.t === "press" && (x.cmd as { id: string }).id === id, 2000);
		expect(r.launches).toHaveLength(2);
	});

	it("drops a press older than the queue limit and never sends it late", async () => {
		const r = rig({ queueMs: 150, launchWindowMs: 2000 });
		r.link.setWanted(true);
		r.link.press();
		await until(() => r.launches.length === 1, 1000, "launch");
		await sleep(250);
		expect(r.logs.some((l) => /press sd-\d+ dropped, app not reachable within 150 ms/.test(l))).toBe(true);
		expect(r.link.status).toBe("launching"); // still inside the launch window
		await r.app.start();
		await until(() => r.link.online, 1000, "online");
		await sleep(30);
		expect(r.app.commands().map((c) => c.t)).toEqual(["hello"]);
	});

	it("shows 'App fehlt' when the launch fails, and retries the launch on the next press", async () => {
		const r = rig({
			onLaunch: () => {
				throw new Error("Unable to find application with bundle identifier");
			},
		});
		r.link.setWanted(true);
		r.link.press();
		await until(() => r.link.error === APP_MISSING, 1000, "App fehlt");
		expect(last(r)).toEqual({ s: "offline", error: APP_MISSING });
		expect(r.logs.some((l) => l.includes("launch failed: Unable to find application"))).toBe(true);
		r.link.press();
		await until(() => r.launches.length === 2, 1000, "second launch");
	});

	it("reconnects with growing backoff and accepts the new app run's seq", async () => {
		const r = rig();
		await r.app.start();
		r.link.setWanted(true);
		await until(() => r.states.length === 1, 1000, "online");
		await r.app.stop();
		await until(() => r.link.status === "offline", 1000, "offline");
		const t0 = r.connects.length;
		await sleep(700);
		const gaps = r.connects.slice(t0).map((t, i, a) => (i === 0 ? 0 : t - a[i - 1]!)).slice(1);
		// 40 -> 80 -> 160 -> 200 (cap) ...
		expect(gaps.length).toBeGreaterThanOrEqual(3);
		expect(gaps[0]!).toBeGreaterThanOrEqual(70);
		expect(gaps[1]!).toBeGreaterThanOrEqual(140);
		for (const g of gaps) expect(g).toBeLessThan(260);
		expect(r.launches).toHaveLength(0);

		r.app.seq = 0; // a restarted app counts from 1 again
		await r.app.start();
		await until(() => r.states.length === 2, 1000, "snapshot after reconnect");
		expect(r.states[1]!.seq).toBe(1);
		expect(r.app.commands("hello")).toHaveLength(2);
	});

	it("polls fast after applicationDidLaunch", async () => {
		const r = rig({ backoffMinMs: 5000, backoffMaxMs: 5000 });
		r.link.setWanted(true);
		await until(() => r.link.status === "offline" && r.connects.length === 1, 1000, "offline");
		await r.app.start();
		r.link.appLaunched();
		expect(r.link.status).toBe("launching");
		await until(() => r.link.online, 300, "online within the fast window");
		expect(r.launches).toHaveLength(0);
	});

	it("never connects or launches after dispose", async () => {
		const r = rig();
		r.link.setWanted(true);
		r.link.dispose();
		const n = r.connects.length;
		r.link.press();
		r.link.appLaunched();
		await sleep(100);
		expect(r.connects.length).toBe(n);
		expect(r.launches).toHaveLength(0);
	});
});

describe("launcher", () => {
	const fakeExec = (calls: { file: string; args: readonly string[] }[], fail?: string): ExecFileFn => {
		return (file, args, _opts, cb) => {
			calls.push({ file, args });
			setImmediate(() => (fail ? cb(new Error("Command failed"), "", fail) : cb(null, "", "")));
		};
	};

	it("runs open -g -b with the app's bundle id", async () => {
		const calls: { file: string; args: readonly string[] }[] = [];
		await createLauncher({ env: {}, execFile: fakeExec(calls) })();
		expect(calls).toEqual([{ file: OPEN_BINARY, args: ["-g", "-b", APP_BUNDLE_ID] }]);
		expect(OPEN_BINARY).toBe("/usr/bin/open");
		expect(APP_BUNDLE_ID).toBe("io.github.nordavid.acvoice");
	});

	it("uses the test launcher from the environment", async () => {
		const calls: { file: string; args: readonly string[] }[] = [];
		await createLauncher({ env: { ACVOICE_TEST_LAUNCHER: "/tmp/stub" }, execFile: fakeExec(calls) })();
		expect(calls[0]!.file).toBe("/tmp/stub");
	});

	it("rejects with the launcher's error output", async () => {
		const calls: { file: string; args: readonly string[] }[] = [];
		await expect(createLauncher({ env: {}, execFile: fakeExec(calls, "Unable to find application named x\n") })()).rejects.toThrow("Unable to find application named x");
	});

	it("rejects on an exit status, like open's 'Unable to find application'", async () => {
		const exec: ExecFileFn = (_f, _a, _o, cb) => {
			setImmediate(() => cb(Object.assign(new Error("Command failed"), { code: 1, killed: false, signal: null }) as ExecFileError, "", "Unable to find application with bundle identifier io.github.nordavid.acvoice.\n"));
		};
		await expect(createLauncher({ env: {}, execFile: exec })()).rejects.toThrow("Unable to find application with bundle identifier");
	});

	// Review finding 4: the execFile timeout used to count as "not installed".
	it("resolves when the timeout kills a hanging open: a slow launch is no missing app", async () => {
		const opts: { timeout: number }[] = [];
		const logs: string[] = [];
		const exec: ExecFileFn = (_f, _a, o, cb) => {
			opts.push(o);
			setImmediate(() => cb(Object.assign(new Error("Command failed: /usr/bin/open -g -b io.github.nordavid.acvoice"), { killed: true, signal: "SIGTERM" as const, code: null }), "", ""));
		};
		await expect(createLauncher({ env: {}, execFile: exec, log: (m) => logs.push(m) })()).resolves.toBeUndefined();
		expect(opts).toEqual([{ timeout: LAUNCH_TIMEOUT_MS }]);
		expect(LAUNCH_TIMEOUT_MS).toBe(15_000);
		expect(logs).toEqual(["launcher still running after 15000 ms (SIGTERM), the app may still start"]);
	});

	it("shows the launching face, not 'App fehlt', when open hangs, and the app still connects", async () => {
		const launch = createLauncher({
			env: {},
			timeoutMs: 40,
			execFile: (_f, _a, o, cb) => {
				setTimeout(() => cb(Object.assign(new Error("Command failed"), { killed: true, signal: "SIGTERM" as const, code: null }), "", ""), o.timeout);
			},
		});
		const t = tempSocket();
		const app = new FakeApp(t.sock);
		const statuses: { s: LinkStatus; error?: string }[] = [];
		const link = new AppLink(
			{ status: (s, error) => statuses.push({ s, error }), state: () => {}, level: () => {} },
			{ socketPath: t.sock, version: "0.1.0", launch, ...FAST, queueMs: 1000 },
		);
		cleanup.push(() => link.dispose(), () => void app.stop(), t.cleanup);
		link.setWanted(true);
		const id = link.press();
		await sleep(120); // the launcher timed out meanwhile
		expect(statuses.some((s) => s.error === APP_MISSING)).toBe(false);
		expect(link.status).toBe("launching");
		await app.start(); // the app finishes its slow start
		const press = await app.waitFor((x) => x.cmd.t === "press", 1000);
		expect(press.cmd).toMatchObject({ id });
		expect(statuses.every((s) => s.error === undefined)).toBe(true);
	});

	it("cannot reach the real child_process in unit tests", async () => {
		await expect(createLauncher({ env: {} })()).rejects.toThrow(/blocked in unit tests/);
	});
});
