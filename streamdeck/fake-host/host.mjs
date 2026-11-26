// Headless end-to-end test of the built plugin (io.github.nordavid.acvoice.streamdeck.sdPlugin/bin/plugin.js).
//
// - Plays Stream Deck: a WebSocket host on 127.0.0.1 that starts the plugin with the same arguments as
//   Stream Deck (-port, -pluginUUID, -registerEvent, -info), sends willAppear / willDisappear / keyDown / keyUp /
//   applicationDidLaunch / propertyInspectorDidAppear and records every setImage.
// - Plays the AC Voice app: an NDJSON server on a temp Unix socket (ACVOICE_SOCKET), protocol v1.
// - Replaces `open -g -b` with a stub script (ACVOICE_TEST_LAUNCHER) that only logs its arguments.
//   Nothing here launches an app, touches Stream Deck's folders or the real socket.
//
//   npm run build && npm run e2e        (node fake-host/host.mjs [--keep] [--verbose])
//
// The plugin runs in a temp copy (manifest.json + bin/), so its logs/ never land in the repo.
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const SD = path.resolve(HERE, "../io.github.nordavid.acvoice.streamdeck.sdPlugin");
const PLUGIN_UUID = "io.github.nordavid.acvoice.streamdeck";
const ACTION = `${PLUGIN_UUID}.voice`;
const BUNDLE = "io.github.nordavid.acvoice";
const KEEP = process.argv.includes("--keep");
const VERBOSE = process.argv.includes("--verbose");
const now = () => performance.now();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (!fs.existsSync(path.join(SD, "bin/plugin.js"))) {
	console.error("bin/plugin.js missing: run `npm run build` first");
	process.exit(2);
}

// ---------- sandbox ----------

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "acv-e2e-"));
const SOCK = path.join(TMP, "ipc.sock");
if (Buffer.byteLength(SOCK) >= 104) throw new Error(`socket path too long (${SOCK.length} bytes): ${SOCK}`);
fs.mkdirSync(path.join(TMP, "bin"));
for (const f of ["manifest.json", "bin/plugin.js", "bin/package.json"]) fs.copyFileSync(path.join(SD, f), path.join(TMP, f));
const LAUNCH_LOG = path.join(TMP, "launch.log");
const LAUNCH_FAIL = path.join(TMP, "launch.fail");
const STUB = path.join(TMP, "launcher.sh");
fs.writeFileSync(
	STUB,
	`#!/bin/sh\n# Stub for /usr/bin/open: logs the arguments, starts nothing.\necho "$@" >> '${LAUNCH_LOG}'\nif [ -f '${LAUNCH_FAIL}' ]; then echo "Unable to find application with bundle identifier $3" >&2; exit 1; fi\nexit 0\n`,
	{ mode: 0o755 },
);
const launches = () => (fs.existsSync(LAUNCH_LOG) ? fs.readFileSync(LAUNCH_LOG, "utf8").trim().split("\n").filter(Boolean) : []);

// ---------- results ----------

const results = [];
let failures = 0;
function check(label, ok, detail = "") {
	results.push({ label, ok, detail });
	if (!ok) failures++;
	console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? `  (${detail})` : ""}`);
}
const ms = (x) => `${x.toFixed(2)} ms`;
const pct = (xs, q) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(q * xs.length))];

// ---------- fake app ----------

const sortedJson = (v) =>
	JSON.stringify(v, (_k, x) => (x && typeof x === "object" && !Array.isArray(x) ? Object.fromEntries(Object.keys(x).sort().filter((k) => x[k] !== undefined).map((k) => [k, x[k]])) : x));

class FakeApp {
	server;
	clients = new Set();
	connections = 0;
	commands = [];
	waiters = [];
	seq = 0;
	snapshot = { phase: "idle" };
	lastWriteAt = 0;

	async start() {
		fs.rmSync(SOCK, { force: true });
		this.server = net.createServer((c) => this.accept(c));
		await new Promise((r, j) => this.server.once("error", j).listen(SOCK, r));
		fs.chmodSync(SOCK, 0o600);
	}

	async stop() {
		for (const c of this.clients) c.destroy();
		this.clients.clear();
		const s = this.server;
		this.server = undefined;
		if (s) await new Promise((r) => s.close(r));
	}

	accept(c) {
		this.connections++;
		this.clients.add(c);
		c.on("close", () => this.clients.delete(c));
		c.on("error", () => {});
		let buf = "";
		c.setEncoding("utf8");
		c.on("data", (chunk) => {
			buf += chunk;
			let i;
			while ((i = buf.indexOf("\n")) >= 0) {
				const line = buf.slice(0, i);
				buf = buf.slice(i + 1);
				let cmd;
				try {
					cmd = JSON.parse(line);
				} catch {
					continue;
				}
				const rec = { cmd, at: now(), line };
				this.commands.push(rec);
				if (VERBOSE) console.log(`  app <- ${line}`);
				if (cmd.t === "ping") c.write(sortedJson({ v: 1, t: "pong", id: cmd.id }) + "\n");
				for (const w of [...this.waiters]) if (w.pred(rec)) w.done(rec);
			}
		});
		// Like the Swift IPCServer: the current snapshot on connect.
		c.write(this.stateLine());
	}

	stateLine() {
		return sortedJson({ v: 1, t: "state", seq: ++this.seq, since: Date.now(), ...this.snapshot }) + "\n";
	}

	/** Publishes a new snapshot; returns the time it was written. */
	publish(snapshot) {
		this.snapshot = snapshot;
		const line = this.stateLine();
		this.lastWriteAt = now();
		for (const c of this.clients) c.write(line);
		return this.lastWriteAt;
	}

	level(rms) {
		const line = sortedJson({ v: 1, t: "level", rms }) + "\n";
		for (const c of this.clients) c.write(line);
	}

	waitFor(pred, timeout = 3000, what = "command") {
		const hit = this.commands.find(pred);
		if (hit) return Promise.resolve(hit);
		return new Promise((resolve, reject) => {
			const w = { pred };
			const t = setTimeout(() => {
				this.waiters = this.waiters.filter((x) => x !== w);
				reject(new Error(`timeout waiting for ${what}`));
			}, timeout);
			w.done = (rec) => {
				clearTimeout(t);
				this.waiters = this.waiters.filter((x) => x !== w);
				resolve(rec);
			};
			this.waiters.push(w);
		});
	}

	since(i) {
		return this.commands.slice(i);
	}
}

// ---------- fake Stream Deck ----------

const wss = new WebSocketServer({ host: "127.0.0.1", port: 0 });
await new Promise((r) => wss.once("listening", r));
const port = wss.address().port;
let ws;
const frames = []; // { at, ctx, face, bytes }
const toInspector = [];
const faceListeners = new Set();

function faceOf(image) {
	const svg = decodeURIComponent(image.replace(/^data:image\/svg\+xml;charset=utf8,/, ""));
	return /<rect id="face-([a-z-]+)"/.exec(svg)?.[1] ?? "unknown";
}

/** Resolves with the first frame from now on whose face (and frame) match `pred`. */
function waitFace(pred, timeout = 3000, what = "face") {
	return new Promise((resolve, reject) => {
		const l = (f) => {
			if (pred(f.face, f)) {
				clearTimeout(t);
				faceListeners.delete(l);
				resolve(f);
			}
		};
		const t = setTimeout(() => {
			faceListeners.delete(l);
			reject(new Error(`timeout waiting for ${what}; last faces: ${frames.slice(-5).map((f) => f.face).join(", ")}`));
		}, timeout);
		faceListeners.add(l);
	});
}

wss.on("connection", (socket) => {
	ws = socket;
	socket.on("message", (raw) => {
		const msg = JSON.parse(raw.toString());
		if (msg.event === "registerPlugin") return socket.emit("registered", msg);
		if (msg.event === "setImage") {
			const f = { at: now(), ctx: msg.context, face: faceOf(msg.payload.image), bytes: msg.payload.image.length };
			frames.push(f);
			if (VERBOSE) console.log(`  key <- ${f.face} (${f.bytes} B)`);
			for (const l of [...faceListeners]) l(f);
		} else if (msg.event === "sendToPropertyInspector") {
			toInspector.push(msg.payload);
		} else if (msg.event === "setTitle") {
			frames.push({ at: now(), ctx: msg.context, face: "setTitle", bytes: 0 });
		}
	});
});

const DEVICE = "61b5e2e62ad684c35125b119e7e889a9";
const CTX = "voice-key-1";
const send = (m) => ws.send(JSON.stringify(m));
const keyEvent = (event, context = CTX) => ({
	event,
	action: ACTION,
	context,
	device: DEVICE,
	payload: { settings: {}, coordinates: { column: 0, row: 0 }, controller: "Keypad", isInMultiAction: false, state: 0 },
});
const keyDown = () => {
	const t = now();
	send(keyEvent("keyDown"));
	return t;
};
const keyUp = () => {
	const t = now();
	send(keyEvent("keyUp"));
	return t;
};
/** Several events in one TCP write, as Stream Deck does on a page switch (willDisappear + willAppear). */
const sendTogether = (...msgs) => {
	const sock = ws._socket;
	sock.cork();
	for (const m of msgs) send(m);
	sock.uncork();
};
const dedupe = (faces) => faces.filter((f, i, a) => f !== a[i - 1]);

const info = {
	application: { font: ".AppleSystemUIFont", language: "de", platform: "mac", platformVersion: "26.6.2", version: "7.6.1.23033" },
	colors: {},
	devicePixelRatio: 2,
	devices: [{ id: DEVICE, name: "Stream Deck", size: { columns: 5, rows: 3 }, type: 0 }],
	plugin: { uuid: PLUGIN_UUID, version: "0.1.0.0" },
};

const child = spawn(
	process.execPath,
	["--no-global-search-paths", "--enable-source-maps", path.join(TMP, "bin/plugin.js"), "-port", String(port), "-pluginUUID", "e2e-plugin", "-registerEvent", "registerPlugin", "-info", JSON.stringify(info)],
	{
		cwd: TMP,
		env: { ...process.env, ACVOICE_SOCKET: SOCK, ACVOICE_TEST_LAUNCHER: STUB },
		stdio: ["ignore", "pipe", "pipe"],
	},
);
child.stderr.on("data", (d) => process.stderr.write(`[plugin] ${d}`));
if (VERBOSE) child.stdout.on("data", (d) => process.stdout.write(`[plugin] ${d}`));
let childExited = false;
child.on("exit", () => (childExited = true));

const app = new FakeApp();

async function finish(code) {
	try {
		child.kill();
		await app.stop();
		wss.close();
	} finally {
		if (KEEP) console.log(`kept ${TMP}`);
		else fs.rmSync(TMP, { recursive: true, force: true });
	}
	process.exit(code);
}

try {
	await new Promise((resolve, reject) => {
		const t = setTimeout(() => reject(new Error("plugin did not register")), 5000);
		wss.once("connection", (s) => s.once("registered", () => (clearTimeout(t), resolve())));
	});
	const T0 = now();
	console.log(`plugin registered (node ${process.version}, socket ${Buffer.byteLength(SOCK)} bytes)`);

	// 1. Key appears while the app is down: "Start" face.
	let p = waitFace((f) => f === "offline", 3000, "offline");
	send(keyEvent("willAppear"));
	await p;
	check("app down: key shows the offline face", true);

	// 2. Cold path: keyDown launches the app via the stub, the press waits in the queue and arrives after launch.
	const launchFace = waitFace((f) => f === "launching", 2000, "launching");
	const coldDown = keyDown();
	const coldDownEpoch = Date.now();
	const spinnerAt = (await launchFace).at;
	const end = now() + 2000;
	while (launches().length === 0 && now() < end) await sleep(2);
	// The stub's first run is slow (macOS checks a freshly written script); /usr/bin/open is not affected.
	check("cold: keyDown -> spinner, launcher stub called", launches().length === 1, `spinner ${ms(spinnerAt - coldDown)}, stub logged after ${ms(now() - coldDown)}`);
	await sleep(150); // simulated app start
	await app.start();
	const coldPress = await app.waitFor((r) => r.cmd.t === "press", 3000, "queued press");
	const order = app.commands.map((r) => r.cmd.t);
	check("cold: hello, then the queued press", order[0] === "hello" && order[1] === "press", order.join(","));
	check("cold: press keeps the key-down time", Math.abs(coldPress.cmd.at - coldDownEpoch) <= 5, `at - keyDown = ${coldPress.cmd.at - coldDownEpoch} ms`);
	check("cold: keyDown -> press delivered after launch", coldPress.at - coldDown < 3000, ms(coldPress.at - coldDown));
	p = waitFace((f) => f === "listening", 2000, "listening");
	app.publish({ phase: "listening", micReady: true });
	await p;
	check("cold: launcher called exactly once with -g -b io.github.nordavid.acvoice", JSON.stringify(launches()) === JSON.stringify([`-g -b ${BUNDLE}`]), JSON.stringify(launches()));
	const coldFaces = frames.map((f) => f.face).filter((f, i, a) => f !== a[i - 1]);
	check("cold: no idle flash between spinner and listening", coldFaces.join(">") === "offline>launching>listening", coldFaces.join(" > "));
	keyUp();
	const coldRelease = await app.waitFor((r) => r.cmd.t === "release", 2000, "release");
	check("cold: release names the press", coldRelease.cmd.pressId === coldPress.cmd.id && coldRelease.cmd.heldMs >= 0, JSON.stringify(coldRelease.cmd));
	p = waitFace((f) => f === "idle", 2000, "idle");
	app.publish({ phase: "idle" });
	await p;

	// 3. Warm path: keyDown -> press at the app, state -> setImage.
	const pressLat = [];
	const faceLat = [];
	const releaseOk = [];
	for (let k = 0; k < 40; k++) {
		const n = app.commands.length;
		const t = keyDown();
		const press = await app.waitFor((r) => r.cmd.t === "press" && app.commands.indexOf(r) >= n, 1000, "warm press");
		pressLat.push(press.at - t);
		const fp = waitFace((f) => f === "mic-starting", 1000, "mic-starting");
		const w = app.publish({ phase: "listening", micReady: false });
		faceLat.push((await fp).at - w);
		await sleep(5);
		keyUp();
		const rel = await app.waitFor((r) => r.cmd.t === "release" && app.commands.indexOf(r) >= n, 1000, "warm release");
		releaseOk.push(rel.cmd.pressId === press.cmd.id);
		const ip = waitFace((f) => f === "idle", 1000, "idle");
		app.publish({ phase: "idle" });
		await ip;
	}
	const warm = pressLat.slice(5); // the first presses warm up the JIT
	check(`warm: keyDown -> press at the app < 5 ms (p50, p95; n=${warm.length})`, pct(warm, 0.5) < 5 && pct(warm, 0.95) < 5, `p50 ${ms(pct(warm, 0.5))}, p95 ${ms(pct(warm, 0.95))}, max ${ms(Math.max(...warm))}`);
	check("warm: every release names its press", releaseOk.every(Boolean), `${releaseOk.filter(Boolean).length}/${releaseOk.length}`);
	check("warm: state -> setImage < 5 ms (p95)", pct(faceLat, 0.95) < 5, `p50 ${ms(pct(faceLat, 0.5))}, p95 ${ms(pct(faceLat, 0.95))}, max ${ms(Math.max(...faceLat))}`);

	// 4. Every wire phase maps to its face.
	const deadline = Date.now() + 1500;
	const phases = [
		[{ phase: "listening", micReady: false, message: "Sprachmodell lädt" }, "mic-starting"],
		[{ phase: "listening", micReady: true, transcript: "Öffne das WWT-Projekt" }, "listening"],
		[{ phase: "processing", transcript: "Öffne das WWT-Projekt" }, "processing"],
		[{ phase: "choices", deadline, total: 4, choices: [1, 2, 3, 4].map((n) => ({ n, label: `Wahl ${n}` })), message: "Sag eine Zahl" }, "choices"],
		[{ phase: "success", message: "WWT: Website Relaunch" }, "success"],
		[{ phase: "error", message: "Nichts gehört" }, "error"],
		[{ phase: "idle" }, "idle"],
	];
	const phaseLat = [];
	for (const [snap, face] of phases) {
		const fp = waitFace((f) => f === face, 1000, face);
		const w = app.publish(snap);
		phaseLat.push(`${face} ${((await fp).at - w).toFixed(2)}`);
	}
	check("state broadcast -> setImage for every phase", true, phaseLat.join(", ") + " ms");

	// 5. Animation: at most 10 fps while listening with 15 Hz levels, and nothing while static.
	app.publish({ phase: "listening", micReady: true });
	await sleep(100);
	const f0 = frames.length;
	const tA = now();
	for (let i = 0; i < 30; i++) {
		app.level(0.2 + 0.6 * Math.abs(Math.sin(i / 3)));
		if (i % 4 === 0) app.publish({ phase: "listening", micReady: true, transcript: `Öffne WWT ${i}` });
		await sleep(66);
	}
	const listenFrames = frames.slice(f0).filter((f) => f.face === "listening");
	const dur = (now() - tA) / 1000;
	const fps = listenFrames.length / dur;
	const avgBytes = Math.round(listenFrames.reduce((a, f) => a + f.bytes, 0) / Math.max(1, listenFrames.length));
	check("listening animation <= 10 fps", fps <= 10.5 && fps >= 6, `${listenFrames.length} frames in ${dur.toFixed(2)} s = ${fps.toFixed(1)} fps, ${avgBytes} B/frame`);
	const pp = waitFace((f) => f === "processing", 1000, "processing");
	app.publish({ phase: "processing" });
	await pp;
	const f1 = frames.length;
	await sleep(1000);
	const procFps = frames.slice(f1).length;
	check("processing animation <= 10 fps", procFps <= 11 && procFps >= 6, `${procFps} frames in 1 s`);
	let ip = waitFace((f) => f === "idle", 1000, "idle");
	app.publish({ phase: "idle" });
	await ip;
	const f2 = frames.length;
	await sleep(800);
	check("static idle face: no setImage", frames.length === f2, `${frames.length - f2} frames in 800 ms`);

	// 6. Choices countdown animates until the deadline, then stops.
	const cp = waitFace((f) => f === "choices", 1000, "choices");
	app.publish({ phase: "choices", deadline: Date.now() + 600, choices: [{ n: 1, label: "A" }, { n: 2, label: "B" }] });
	await cp;
	const f3 = frames.length;
	await sleep(900);
	const countdown = frames.slice(f3);
	const lastAt = countdown.at(-1)?.at ?? 0;
	await sleep(400);
	check("choices countdown animates, then stops after the deadline", countdown.length >= 4 && countdown.length <= 8 && frames.length === f3 + countdown.length, `${countdown.length} frames, last ${(now() - lastAt).toFixed(0)} ms ago`);
	ip = waitFace((f) => f === "idle", 1000, "idle");
	app.publish({ phase: "idle" });
	await ip;

	// 7. Property inspector gets the link status.
	send({ event: "propertyInspectorDidAppear", action: ACTION, context: CTX, device: DEVICE });
	await sleep(50);
	const pi = toInspector.at(-1);
	check("property inspector receives the link status", pi?.type === "status" && pi?.link === "online" && pi?.busy === false, JSON.stringify(pi));

	// 7b. Page switch while the key is held (the voice key sits on both pages): willDisappear and willAppear
	//     arrive in one TCP write. The held press gets its release, and the link and the face survive.
	const CTX2 = "voice-key-2";
	const nConn = app.connections;
	const n7 = app.commands.length;
	const f7 = frames.length;
	keyDown();
	const heldPress = await app.waitFor((r) => r.cmd.t === "press" && app.commands.indexOf(r) >= n7, 1000, "press before the switch");
	p = waitFace((f) => f === "listening", 1000, "listening");
	app.publish({ phase: "listening", micReady: true });
	await p;
	const lp = waitFace((_face, f) => f.ctx === CTX2, 1000, "first frame of the key on the new page");
	sendTogether(keyEvent("willDisappear"), keyEvent("willAppear", CTX2));
	const switchRel = await app.waitFor((r) => r.cmd.t === "release" && app.commands.indexOf(r) >= n7, 1000, "release on willDisappear");
	const newKey = await lp;
	check("page switch while held: the press gets a release with heldMs 0", switchRel.cmd.pressId === heldPress.cmd.id && switchRel.cmd.heldMs === 0, JSON.stringify(switchRel.cmd));
	check("page switch: the new key shows the current face at once", newKey.face === "listening", `${newKey.face} on ${newKey.ctx}`);
	keyUp(); // the old key's keyUp, should Stream Deck send it: nothing more goes out
	await sleep(1300); // longer than the link's linger
	sendTogether(keyEvent("willDisappear", CTX2), keyEvent("willAppear"));
	await sleep(100);
	const switchFaces = dedupe(frames.slice(f7).map((f) => f.face));
	const switchCmds = app.commands.slice(n7).map((r) => r.cmd.t).filter((t) => t !== "ping");
	check(
		"page switch keeps the link: no reconnect, no offline or launching face",
		app.connections === nConn && app.clients.size === 1 && !switchFaces.some((f) => f === "offline" || f === "launching"),
		`${app.connections - nConn} new connections, faces ${switchFaces.join(" > ")}`,
	);
	check("page switch: one press, one release", switchCmds.join(",") === "press,release", switchCmds.join(","));
	ip = waitFace((f) => f === "idle", 1000, "idle");
	app.publish({ phase: "idle" });
	await ip;

	// 8. Liveness: the plugin pings while connected.
	const pingWait = Math.max(0, 5600 - (now() - T0));
	await sleep(pingWait);
	const pings = app.commands.filter((r) => r.cmd.t === "ping").length;
	check("ping/pong liveness runs while connected", pings >= 1, `${pings} pings in ${((now() - T0) / 1000).toFixed(1)} s`);

	// 9. App crash: the key goes offline at once.
	p = waitFace((f) => f === "offline", 2000, "offline");
	let t = now();
	await app.stop();
	check("app gone -> offline face", true, ms((await p).at - t));

	// 10. App started from outside (login item) + applicationDidLaunch -> reconnect without a key press.
	const nLaunch = launches().length;
	await app.start();
	p = waitFace((f) => f === "idle", 2000, "idle after reconnect");
	t = now();
	send({ event: "applicationDidLaunch", payload: { application: BUNDLE } });
	check("applicationDidLaunch -> reconnect -> idle face", true, ms((await p).at - t));
	check("reconnect needs no launch", launches().length === nLaunch);

	// 11. App not installed: the launcher fails -> "App fehlt".
	p = waitFace((f) => f === "offline", 2000, "offline");
	await app.stop();
	await p;
	fs.writeFileSync(LAUNCH_FAIL, "");
	p = waitFace((f) => f === "missing", 3000, "missing");
	t = keyDown();
	keyUp();
	const miss = await p;
	check("app missing: keyDown -> 'App fehlt' face", launches().length === nLaunch + 1, ms(miss.at - t));

	// 12. Key disappears: the plugin lets go of the app.
	fs.rmSync(LAUNCH_FAIL);
	await app.start();
	send({ event: "applicationDidLaunch", payload: { application: BUNDLE } });
	await waitFace((f) => f === "idle", 2000, "idle");
	send(keyEvent("willDisappear"));
	t = now();
	const gone = Date.now() + 3000;
	while (app.clients.size > 0 && Date.now() < gone) await sleep(5);
	check("willDisappear closes the app connection after the linger", app.clients.size === 0, ms(now() - t));

	const faces = frames.map((f) => f.face).filter((f, i, a) => f !== a[i - 1]);
	console.log(`\nface sequence (deduped, first 16): ${faces.slice(0, 16).join(" > ")}`);
	console.log(`setImage calls: ${frames.length} in ${((now() - T0) / 1000).toFixed(1)} s; setTitle calls: ${frames.filter((f) => f.face === "setTitle").length}`);
	check("plugin process still running", !childExited);
	// The SDK catches the first uncaught exception (and an unhandled rejection Node raises as one) and only logs
	// it, so the process survives. The plugin log must hold no ERROR line.
	const logDir = path.join(TMP, "logs");
	const logText = fs.existsSync(logDir) ? fs.readdirSync(logDir).filter((f) => f.endsWith(".log")).map((f) => fs.readFileSync(path.join(logDir, f), "utf8")).join("") : "";
	const errorLines = logText.split("\n").filter((l) => /\bERROR\b/.test(l));
	check("plugin log has no ERROR lines", logText.length > 0 && errorLines.length === 0, errorLines[0] ?? `${logText.split("\n").filter(Boolean).length} lines`);
	console.log(`\n${results.length - failures}/${results.length} checks passed`);
	await finish(failures ? 1 : 0);
} catch (e) {
	console.error(`E2E ERROR: ${e?.stack ?? e}`);
	await finish(1);
}
