import { execFile as nodeExecFile } from "node:child_process";
import { APP_BUNDLE_ID, ENV_TEST_LAUNCHER } from "./config.js";

/** The error `child_process.execFile` passes: `killed`/`signal` after the timeout, `code` for an exit status. */
export type ExecFileError = Error & { killed?: boolean; signal?: NodeJS.Signals | null; code?: number | string | null };

export type ExecFileFn = (
	file: string,
	args: readonly string[],
	options: { timeout: number },
	callback: (error: ExecFileError | null, stdout: string | Buffer, stderr: string | Buffer) => void,
) => unknown;

export interface LauncherOptions {
	bundleId?: string;
	env?: NodeJS.ProcessEnv;
	execFile?: ExecFileFn;
	timeoutMs?: number;
	log?: (msg: string) => void;
}

/** The real launcher binary. LaunchServices starts the app as its own responsible process (TCC). */
export const OPEN_BINARY = "/usr/bin/open";

/** `open` waits until the launched app checks in; an app that blocks early in its launch keeps it waiting. */
export const LAUNCH_TIMEOUT_MS = 15_000;

/**
 * Returns a function that starts AC Voice in the background via LaunchServices:
 * `open -g -b io.github.nordavid.acvoice`. Never spawns the app binary, so the microphone and Automation
 * permissions belong to AC Voice, not to Stream Deck.
 * - Rejects on an exit status (how `open` reports "Unable to find application"): the app is not installed.
 * - Resolves when the timeout kills `open`: LaunchServices keeps starting the app, so a slow launch is no
 *   missing app, and the link keeps polling.
 * `ACVOICE_TEST_LAUNCHER` replaces `/usr/bin/open` with a stub (same arguments) for the e2e harness.
 */
export function createLauncher(opts: LauncherOptions = {}): () => Promise<void> {
	const bundleId = opts.bundleId ?? APP_BUNDLE_ID;
	const env = opts.env ?? process.env;
	const run = opts.execFile ?? (nodeExecFile as unknown as ExecFileFn);
	const timeout = opts.timeoutMs ?? LAUNCH_TIMEOUT_MS;
	const log = opts.log ?? (() => {});
	return () =>
		new Promise<void>((resolve, reject) => {
			const file = env[ENV_TEST_LAUNCHER] || OPEN_BINARY;
			run(file, ["-g", "-b", bundleId], { timeout }, (error, _stdout, stderr) => {
				if (!error) return resolve();
				if (error.killed || error.signal) {
					log(`launcher still running after ${timeout} ms (${error.signal ?? "killed"}), the app may still start`);
					return resolve();
				}
				const detail = String(stderr ?? "").trim();
				reject(new Error(detail || error.message));
			});
		});
}
