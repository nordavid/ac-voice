import { defineConfig } from "vitest/config";

// Caches stay inside this folder (.cache/), never in node_modules: during development node_modules can be a
// read-only symlink to another checkout. Load this file with `--configLoader native` (see package.json) so Vite
// does not bundle it into node_modules/.vite-temp either.
export default defineConfig({
	cacheDir: ".cache/vite",
	test: {
		include: ["test/**/*.test.ts"],
		environment: "node",
		setupFiles: ["test/setup.ts"],
		fsModuleCache: false,
		fsModuleCachePath: ".cache/vitest-modules",
		testTimeout: 10_000,
		// Socket tests bind real Unix sockets; keep files sequential so timing assertions stay stable.
		fileParallelism: false,
	},
});
