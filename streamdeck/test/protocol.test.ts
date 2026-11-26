import { describe, expect, it } from "vitest";
import fixture from "./fixtures/ipc-v1.json";
import {
	type AppMsg,
	decodeCmd,
	encodeAppMsg,
	encodeCmd,
	flexInt,
	LineSplitter,
	MAX_LINE_BYTES,
	parseAppMsg,
	type PluginCmd,
	type StateMsg,
} from "../src/protocol.js";

// test/fixtures/ipc-v1.json is generated from Sources/ACVoiceCore/IPC.swift (IPC.line, IPC.decodeCommand and
// JSONDecoder for IPC.State). Every case here compares the TypeScript codec with the Swift output.

describe("fixture mirrors the Swift codec", () => {
	it("uses the same line limit", () => {
		expect(fixture.maxLineBytes).toBe(MAX_LINE_BYTES);
	});

	it.each(fixture.commands.map((c) => [c.line, c] as const))("encodes %s byte for byte", (_line, c) => {
		expect(encodeCmd(c.cmd as PluginCmd)).toBe(c.line + "\n");
		expect(decodeCmd(c.line)).toEqual(c.cmd);
	});

	it.each(fixture.commandDecode.map((c) => [c.line, c] as const))("decodes command %s like IPC.decodeCommand", (_line, c) => {
		expect(decodeCmd(c.line) ?? null).toEqual(c.expect);
	});

	it.each(fixture.states.map((s) => [s.line, s] as const))("state %s parses and re-encodes identically", (_line, s) => {
		const parsed = parseAppMsg(s.line);
		expect(parsed).toEqual(s.state);
		expect(encodeAppMsg(parsed as StateMsg)).toBe(s.line + "\n");
	});

	it.each(fixture.stateDecode.map((s) => [s.line, s] as const))("decodes state %s like JSONDecoder", (_line, s) => {
		expect(parseAppMsg(s.line) ?? null).toEqual(s.expect);
	});

	it.each([...fixture.levels, ...fixture.pongs].map((m) => [m.line, m] as const))("app message %s", (_line, m) => {
		expect(parseAppMsg(m.line)).toEqual(m.msg);
		expect(encodeAppMsg(m.msg as AppMsg)).toBe(m.line + "\n");
	});
});

describe("PLAN 2.5 examples", () => {
	it("encodes the plugin commands with pressId and seq", () => {
		expect(encodeCmd({ t: "hello", client: "streamdeck", version: "0.1.0" })).toBe('{"client":"streamdeck","t":"hello","v":1,"version":"0.1.0"}\n');
		expect(encodeCmd({ t: "press", id: "sd-7", at: 1732440000000 })).toBe('{"at":1732440000000,"id":"sd-7","t":"press","v":1}\n');
		expect(encodeCmd({ t: "release", id: "sd-8", pressId: "sd-7", heldMs: 812 })).toBe('{"heldMs":812,"id":"sd-8","pressId":"sd-7","t":"release","v":1}\n');
		expect(encodeCmd({ t: "ping", id: "sd-11" })).toBe('{"id":"sd-11","t":"ping","v":1}\n');
	});

	it("parses the state, level and pong examples", () => {
		const s = parseAppMsg(
			'{"v":1,"t":"state","seq":6,"phase":"choices","since":1732440001234,"transcript":"Öffne das WWT-Projekt","preview":null,"choices":[{"n":1,"label":"Relaunch","detail":"WWT: Website Relaunch [AGIL]"}],"total":4,"deadline":1732440007234,"message":null,"micReady":null}',
		) as StateMsg;
		expect(s.phase).toBe("choices");
		expect(s.choices).toEqual([{ n: 1, label: "Relaunch", detail: "WWT: Website Relaunch [AGIL]" }]);
		expect(s.total).toBe(4);
		expect("preview" in s || "message" in s || "micReady" in s).toBe(false);
		expect(parseAppMsg('{"v":1,"t":"level","rms":0.42}')).toEqual({ v: 1, t: "level", rms: 0.42 });
		expect(parseAppMsg('{"v":1,"t":"pong","id":"sd-11"}')).toEqual({ v: 1, t: "pong", id: "sd-11" });
	});
});

describe("tolerance", () => {
	it("rejects other versions, unknown types and junk", () => {
		for (const line of [
			'{"v":2,"t":"state","seq":1,"phase":"idle","since":1}',
			'{"t":"state","seq":1,"phase":"idle","since":1}',
			'{"v":1,"t":"hint","text":"x"}',
			'{"v":1,"t":"level"}',
			'{"v":1,"t":"level","rms":"0.5"}',
			'{"v":1,"t":"pong"}',
			"[]",
			"null",
			"",
			"{",
		]) {
			expect(parseAppMsg(line), line).toBeUndefined();
		}
	});

	it("drops optional fields with a wrong type but keeps the snapshot", () => {
		const s = parseAppMsg('{"v":1,"t":"state","seq":3.0,"phase":"listening","since":7.4,"micReady":"yes","transcript":5,"total":"x","choices":[{"n":1},{"n":2,"label":"B"}]}');
		expect(s).toEqual({ v: 1, t: "state", seq: 3, phase: "listening", since: 7, choices: [{ n: 2, label: "B" }] });
	});

	it("rounds floats half away from zero like Swift", () => {
		expect(flexInt(812.6)).toBe(813);
		expect(flexInt(2.5)).toBe(3);
		expect(flexInt(-2.5)).toBe(-3);
		expect(flexInt(-0.2)).toBe(0);
		expect(flexInt(9e15)).toBeUndefined();
		expect(flexInt(Number.NaN)).toBeUndefined();
		expect(flexInt("5")).toBeUndefined();
	});

	it("rejects lines over 64 KB", () => {
		const big = `{"v":1,"t":"state","seq":1,"phase":"idle","since":1,"transcript":"${"x".repeat(MAX_LINE_BYTES)}"}`;
		expect(parseAppMsg(big)).toBeUndefined();
		expect(decodeCmd(`{"v":1,"t":"ping","id":"${"x".repeat(MAX_LINE_BYTES)}"}`)).toBeUndefined();
	});
});

describe("LineSplitter", () => {
	it("joins chunks and splits lines", () => {
		const s = new LineSplitter();
		expect(s.push('{"a":1}\n{"b"')).toEqual(['{"a":1}']);
		expect(s.push(':2}\n\n{"c":3}\n')).toEqual(['{"b":2}', "", '{"c":3}']);
	});

	it("keeps multi-byte characters split across chunks", () => {
		const s = new LineSplitter();
		const bytes = Buffer.from('{"t":"Öffne"}\n', "utf8");
		const cut = bytes.indexOf(0xc3) + 1; // inside "Ö"
		expect(s.push(bytes.subarray(0, cut))).toEqual([]);
		expect(s.push(bytes.subarray(cut))).toEqual(['{"t":"Öffne"}']);
	});

	it("drops an oversized line and recovers", () => {
		const s = new LineSplitter();
		expect(s.push("x".repeat(MAX_LINE_BYTES - 10))).toEqual([]);
		expect(s.push("y".repeat(20))).toEqual([]);
		expect(s.push("tail\nok\n")).toEqual(["ok"]);
		expect(s.push("z".repeat(MAX_LINE_BYTES + 1) + "\nnext\n")).toEqual(["next"]);
		expect(s.push("a".repeat(MAX_LINE_BYTES) + "\n")).toEqual(["a".repeat(MAX_LINE_BYTES)]);
	});
});
