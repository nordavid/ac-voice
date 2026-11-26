import os from "node:os";
import path from "node:path";

/** Plugin identity. Must match manifest.json (checked by test/manifest.test.ts). */
export const PLUGIN_UUID = "io.github.nordavid.acvoice.streamdeck";
export const VOICE_ACTION_UUID = `${PLUGIN_UUID}.voice`;
/** Plugin version, sent in `hello`. Matches package.json and the manifest's "Version" (x.y.z.0). */
export const PLUGIN_VERSION = "0.1.0";

/** Bundle id of the AC Voice menu-bar app; also in the manifest's ApplicationsToMonitor. */
export const APP_BUNDLE_ID = "io.github.nordavid.acvoice";

/** Test hooks. Stream Deck starts the plugin with its own environment, so users never set these. */
export const ENV_SOCKET = "ACVOICE_SOCKET";
export const ENV_TEST_LAUNCHER = "ACVOICE_TEST_LAUNCHER";

/**
 * The app's socket (`AppPaths.socket` in Swift). ~/Library is 0700 and the app chmods the socket 0600,
 * so only this user reaches it. Must stay below the 104-byte sun_path limit.
 */
export function socketPath(env: NodeJS.ProcessEnv = process.env): string {
	return env[ENV_SOCKET] || path.join(os.homedir(), "Library", "Application Support", "ac-voice", "ipc.sock");
}
