import { vi } from "vitest";

// Safety net: no unit test may start a process (in particular never the real `open`). Launchers are injected.
vi.mock("node:child_process", () => {
	const blocked = (name: string) => () => {
		throw new Error(`child_process.${name} is blocked in unit tests; inject a stub`);
	};
	return {
		execFile: blocked("execFile"),
		exec: blocked("exec"),
		spawn: blocked("spawn"),
		fork: blocked("fork"),
		execSync: blocked("execSync"),
		execFileSync: blocked("execFileSync"),
		spawnSync: blocked("spawnSync"),
		default: {},
	};
});
