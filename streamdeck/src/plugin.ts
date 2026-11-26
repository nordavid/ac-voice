/**
 * AC Voice Stream Deck plugin: one key ("AC Voice") that triggers the app and mirrors its state.
 * keyDown -> `press`, keyUp -> `release`; the app owns what a press means (listen, end now, cancel).
 * The key face follows the app's `state` snapshots and `level` messages.
 */
import streamDeck, {
	action,
	type KeyDownEvent,
	type KeyUpEvent,
	type PropertyInspectorDidAppearEvent,
	type SendToPluginEvent,
	SingletonAction,
	type WillAppearEvent,
	type WillDisappearEvent,
} from "@elgato/streamdeck";
import type { JsonObject, JsonValue } from "@elgato/utils";
import { AppLink } from "./app-link.js";
import { APP_BUNDLE_ID, PLUGIN_VERSION, socketPath, VOICE_ACTION_UUID } from "./config.js";
import { KeyEdges } from "./keys.js";
import { createLauncher } from "./launcher.js";
import { Painter } from "./painter.js";
import { ViewModel } from "./view.js";

streamDeck.logger.setLevel("info");
const log = streamDeck.logger.createScope("ACVoice");
const logInfo = (m: string) => log.info(m);

const model = new ViewModel();
const painter = new Painter(() => model.view);

/** Status for the property inspector (ui/voice.html). Only sent while it is visible. */
function inspectorStatus(): JsonObject {
	return { type: "status", link: link.status, error: link.error ?? null, busy: link.busy, version: PLUGIN_VERSION };
}

function publishInspectorStatus(): void {
	streamDeck.ui.sendToPropertyInspector(inspectorStatus()).catch(() => {});
}

const link = new AppLink(
	{
		status: (status, error) => {
			model.status(status, error);
			painter.update();
			publishInspectorStatus();
		},
		state: (state) => {
			model.state(state);
			painter.update();
		},
		// No paint here: the 100 ms tick picks the level up (caps setImage at 10 fps).
		level: (rms) => model.level(rms),
		// The key keeps its face; only the property inspector says the app does not answer.
		busy: () => publishInspectorStatus(),
	},
	{ socketPath: socketPath(), version: PLUGIN_VERSION, launch: createLauncher({ log: logInfo }), log: logInfo },
);
const keys = new KeyEdges(link);

@action({ UUID: VOICE_ACTION_UUID })
class VoiceAction extends SingletonAction {
	override onWillAppear(ev: WillAppearEvent<JsonObject>): void {
		if (!ev.action.isKey()) return;
		painter.add(ev.action);
		link.setWanted(true);
	}

	override onWillDisappear(ev: WillDisappearEvent<JsonObject>): void {
		painter.remove(ev.action.id);
		keys.gone(ev.action.id);
		link.setWanted(painter.size > 0);
	}

	override onKeyDown(ev: KeyDownEvent<JsonObject>): void {
		keys.down(ev.action.id);
	}

	override onKeyUp(ev: KeyUpEvent<JsonObject>): void {
		keys.up(ev.action.id);
	}

	override onPropertyInspectorDidAppear(_ev: PropertyInspectorDidAppearEvent<JsonObject>): void {
		publishInspectorStatus();
	}

	override onSendToPlugin(ev: SendToPluginEvent<JsonValue, JsonObject>): void {
		const p = ev.payload;
		if (p && typeof p === "object" && !Array.isArray(p) && p.type === "status?") publishInspectorStatus();
	}
}

streamDeck.actions.registerAction(new VoiceAction());

// ApplicationsToMonitor (manifest) reports the app's launch and exit without polling.
streamDeck.system.onApplicationDidLaunch((ev) => {
	if (ev.application === APP_BUNDLE_ID) link.appLaunched();
});
streamDeck.system.onApplicationDidTerminate((ev) => {
	if (ev.application === APP_BUNDLE_ID) link.appTerminated();
});

await streamDeck.connect();
log.info(`AC Voice plugin ${PLUGIN_VERSION} running`);
