import Foundation

// Generates streamdeck/test/fixtures/ipc-v1.json from the real Swift codec. Compiled together with
// Sources/ACVoiceCore/IPC.swift by scripts/gen-ipc-fixtures.sh (npm run fixtures).

func lineString(_ d: Data) -> String {
    var d = d
    if d.last == 0x0A { d.removeLast() }
    return String(decoding: d, as: UTF8.self)
}

func cmdDict(_ c: IPC.Command) -> [String: Any] {
    switch c {
    case let .hello(client, version): return ["t": "hello", "client": client, "version": version]
    case let .press(id, at): return ["t": "press", "id": id, "at": at]
    case let .release(id, pressId, heldMs):
        var o: [String: Any] = ["t": "release", "id": id, "heldMs": heldMs]
        if let pressId { o["pressId"] = pressId }
        return o
    case let .choose(id, index, seq):
        var o: [String: Any] = ["t": "choose", "id": id, "index": index]
        if let seq { o["seq"] = seq }
        return o
    case let .cancel(id): return ["t": "cancel", "id": id]
    case let .ping(id): return ["t": "ping", "id": id]
    }
}

func stateDict(_ s: IPC.State) -> [String: Any] {
    var o: [String: Any] = ["v": s.v, "t": s.t, "seq": s.seq, "phase": s.phase.rawValue, "since": s.since]
    if let x = s.transcript { o["transcript"] = x }
    if let x = s.preview { o["preview"] = x }
    if let x = s.choices {
        o["choices"] = x.map { c -> [String: Any] in
            var d: [String: Any] = ["n": c.n, "label": c.label]
            if let det = c.detail { d["detail"] = det }
            return d
        }
    }
    if let x = s.total { o["total"] = x }
    if let x = s.deadline { o["deadline"] = x }
    if let x = s.message { o["message"] = x }
    if let x = s.micReady { o["micReady"] = x }
    if let x = s.lang { o["lang"] = x }
    return o
}

let commands: [IPC.Command] = [
    .hello(client: "streamdeck", version: "0.1.0"),
    .press(id: "sd-7", at: 1_732_440_000_000),
    .release(id: "sd-8", pressId: "sd-7", heldMs: 812),
    .release(id: "r", pressId: nil, heldMs: 0),
    .choose(id: "sd-9", index: 2, seq: 6),
    .choose(id: "c", index: 1, seq: nil),
    .cancel(id: "sd-10"),
    .ping(id: "sd-11"),
    .press(id: "sd-\"quoted\" / slash", at: 5),
]

let commandInputs: [String] = [
    #"{"v":1,"t":"press","id":"sd-7","at":1732440000000}"#,
    #"{"v":1,"t":"release","id":"sd-8","pressId":"sd-7","heldMs":812}"#,
    #"{"v":1,"t":"choose","id":"sd-9","index":2,"seq":6}"#,
    #"{"v":1,"t":"cancel","id":"sd-10"}"#,
    #"{"v":1,"t":"ping","id":"sd-11"}"#,
    #"{"v":1,"t":"hello","client":"streamdeck","version":"0.1.0"}"#,
    #"{"v":1,"t":"hello"}"#,
    #"{"v":1,"t":"release","id":"sd-8","heldMs":812}"#,
    #"{"v":1,"t":"choose","id":"sd-9","index":2}"#,
    #"{"v":1.0,"t":"release","id":"a","heldMs":812.6,"extra":{"x":1}}"#,
    #"{"v":1,"t":"press","id":"b","at":1732440000000.0,"client":5}"#,
    #"{"v":1,"t":"press","id":"c"}"#,
    #"{"v":1,"t":"release","id":"d","heldMs":"812"}"#,
    #"{"v":1,"t":"release","id":"e","heldMs":-2.5}"#,
    #"{"v":1,"t":"choose","id":"f","index":2.5,"seq":"6"}"#,
    #"{"v":2,"t":"press","id":"x"}"#,
    #"{"v":1,"t":"future","id":"x"}"#,
    #"{"v":1,"t":"press"}"#,
    #"{"v":1,"t":"press","id":7}"#,
    #"{"v":1,"t":"choose","id":"x"}"#,
    "not json",
    #"[1,2,3]"#,
    #"{"t":"press","id":"x"}"#,
    #"{"v":"1","t":"press","id":"x"}"#,
]

let states: [IPC.State] = [
    IPC.State(seq: 6, phase: .choices, since: 1_732_440_001_234, transcript: "Öffne das WWT-Projekt",
              choices: [.init(n: 1, label: "Relaunch", detail: "WWT: Website Relaunch [AGIL]")],
              total: 4, deadline: 1_732_440_007_234),
    IPC.State(seq: 1, phase: .idle, since: 1_732_440_000_000),
    IPC.State(seq: 2, phase: .listening, since: 1_732_440_000_010, message: "Sprachmodell lädt", micReady: false),
    IPC.State(seq: 3, phase: .listening, since: 1_732_440_000_010, transcript: "Öffne WWT Ticket 412",
              preview: "Ticket 412", micReady: true),
    IPC.State(seq: 4, phase: .processing, since: 1_732_440_000_900, transcript: "Öffne WWT Ticket 412",
              preview: "Ticket 412", message: "Suche Ticket 412 …"),
    IPC.State(seq: 5, phase: .choices, since: 1_732_440_001_000, transcript: "Öffne das WWT-Projekt",
              preview: "WWT: 4 Projekte",
              choices: [.init(n: 1, label: "Relaunch", detail: "WWT: Website Relaunch [AGIL]"),
                        .init(n: 2, label: "TYPO3 Maint.", detail: "WWT: TYPO3 Website maintenance [AGIL]"),
                        .init(n: 3, label: "Maintenance", detail: "WWT: Maintenance [SLA]"),
                        .init(n: 4, label: "Grand Navig.", detail: "WWT: Grand Navigation [AGIL]"),
                        .init(n: 5, label: "Größe"),
                        .init(n: 6, label: "S+K Partner", detail: "S+K: Partner [INT]")],
              total: 9, deadline: 1_732_440_007_000, message: "Sag eine Zahl"),
    IPC.State(seq: 7, phase: .success, since: 1_732_440_002_000, transcript: "WWT Relaunch",
              preview: "WWT: Website Relaunch", message: "WWT: Website Relaunch", lang: "de"),
    IPC.State(seq: 8, phase: .error, since: 1_732_440_003_000, message: "Nichts gehört"),
    IPC.State(seq: 10, phase: .error, since: 1_732_440_004_000, transcript: "my tasks", message: "I can’t hear anything",
              lang: "en"),
    IPC.State(seq: 11, phase: .idle, since: 1_732_440_005_000, lang: "en"),
    IPC.State(seq: 9, phase: .listening, since: 1, transcript: "Quote \" back\\slash / tab\tnew\nline <b>&amp; 🎙 é",
              micReady: true),
]

let stateInputs: [String] = [
    // PLAN 2.5 example, nulls included.
    #"{"v":1,"t":"state","seq":6,"phase":"choices","since":1732440001234,"transcript":"Öffne das WWT-Projekt","preview":null,"choices":[{"n":1,"label":"Relaunch","detail":"WWT: Website Relaunch [AGIL]"}],"total":4,"deadline":1732440007234,"message":null,"micReady":null}"#,
    // Research example (no preview/total).
    #"{"v":1,"t":"state","seq":6,"phase":"choices","since":1732440001234,"transcript":"Öffne das WWT-Projekt","deadline":1732440006234,"choices":[{"n":1,"label":"Relaunch","detail":"WWT: Website Relaunch [AGIL]"}]}"#,
    #"{"v":1,"t":"state","seq":2,"phase":"listening","since":5,"micReady":true,"future":{"x":[1,2]}}"#,
    // The app language (optional; older apps omit it).
    #"{"v":1,"t":"state","seq":3,"phase":"idle","since":5,"lang":"en"}"#,
    #"{"v":1,"t":"state","seq":3,"phase":"idle","since":5,"lang":null}"#,
    #"{"v":1,"t":"state","seq":2,"phase":"thinking","since":5}"#,
    #"{"v":1,"t":"state","seq":2,"phase":"idle"}"#,
    #"{"v":1,"t":"state","phase":"idle","since":5}"#,
    #"{"v":1,"t":"state","seq":"2","phase":"idle","since":5}"#,
]

var out: [String: Any] = [
    "source": "Generated from Sources/ACVoiceCore/IPC.swift (IPC.line / IPC.decodeCommand / JSONDecoder for IPC.State). Do not edit by hand.",
]
out["commands"] = commands.map { ["cmd": cmdDict($0), "line": lineString(IPC.line($0))] }
out["commandDecode"] = commandInputs.map { s -> [String: Any] in
    let r = IPC.decodeCommand(Data(s.utf8))
    return ["line": s, "expect": r.map(cmdDict) ?? NSNull()]
}
out["states"] = states.map { ["state": stateDict($0), "line": lineString(IPC.line($0))] }
out["stateDecode"] = stateInputs.map { s -> [String: Any] in
    let r = try? JSONDecoder().decode(IPC.State.self, from: Data(s.utf8))
    return ["line": s, "expect": r.map(stateDict) ?? NSNull()]
}
out["levels"] = [0.0, 0.42, 0.5, 1.0, 0.123456789].map { v -> [String: Any] in
    ["msg": ["v": 1, "t": "level", "rms": v], "line": lineString(IPC.line(IPC.Level(rms: v)))]
}
out["pongs"] = ["sd-11", "x"].map { id -> [String: Any] in
    ["msg": ["v": 1, "t": "pong", "id": id], "line": lineString(IPC.line(IPC.Pong(id: id)))]
}
out["maxLineBytes"] = IPC.maxLineBytes

let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
