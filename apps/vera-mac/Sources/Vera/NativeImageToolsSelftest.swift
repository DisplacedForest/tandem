import AppKit
import Foundation

struct SelfTestComfyRequest: Sendable {
    let method: String
    let path: String
    let bodyData: Data?

    var body: [String: Any]? {
        bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

final class SelfTestComfyTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SelfTestComfyRequest] = []
    private var responses: [String: [(Data, Int)]] = [:]
    private var scriptedEvents: [ComfyUIEvent]? = nil
    private var holdEvents = false
    private var failure: Error?

    var requests: [SelfTestComfyRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func respond(_ method: String, _ path: String, status: Int, json: String) {
        respond(method, path, status: status, data: Data(json.utf8))
    }

    func respond(_ method: String, _ path: String, status: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        responses["\(method) \(path)", default: []].append((data, status))
    }

    func events(_ events: [ComfyUIEvent]?, hold: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        scriptedEvents = events
        holdEvents = hold
    }

    func fail(with error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        failure = error
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded = []
        responses = [:]
        scriptedEvents = nil
        holdEvents = false
        failure = nil
    }

    private func handle(_ url: URL, _ method: String, _ body: Data?) throws -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        var path = url.path
        if let base = url.baseURL?.path, path.hasPrefix(base) { path = String(path.dropFirst(base.count)) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        recorded.append(SelfTestComfyRequest(method: method, path: path, bodyData: body))
        if let failure { throw failure }
        let key = "\(method) \(path)"
        guard var queue = responses[key], !queue.isEmpty else { throw URLError(.unsupportedURL) }
        let response = queue.count == 1 ? queue[0] : queue.removeFirst()
        responses[key] = queue
        return response
    }

    var transport: ComfyUITransport {
        ComfyUITransport(
            request: { [self] url, method, body, _ in try handle(url, method, body) },
            events: { [self] _ in
                lock.lock()
                let events = scriptedEvents
                let hold = holdEvents
                lock.unlock()
                guard let events else { return nil }
                return AsyncThrowingStream { continuation in
                    for event in events { continuation.yield(event) }
                    if !hold { continuation.finish() }
                }
            })
    }
}

@MainActor
extension SelfTest {
    static func runNativeImageLive(_ raw: String) async throws {
        guard let base = NativeImageTools.base(from: raw) else {
            throw NativeToolError.failed("VERA_IMAGE_LIVE_BASE is not a valid http URL")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vera-selftest-live-images-\(UUID().uuidString)", isDirectory: true)
        let attachments = NativeAttachmentStore(directory: directory)
        guard let tool = NativeImageTools.definitions(base: { base }, attachments: attachments).first else {
            throw NativeToolError.failed("No image tool definition")
        }
        let started = ContinuousClock.now
        let report: @Sendable (NativeToolProgress) -> Void = { progress in
            print("  progress \(progress.label)")
        }
        let value = try await NativeToolProgressReporter.$report.withValue(report) {
            try await tool.execute([
                "prompt": .string("A lighthouse on a rocky coast at dusk, with a wooden sign that reads \"NORTH POINT\""),
                "size": .string("1024x1024"),
            ])
        }
        let elapsed = started.duration(to: .now)
        let activity = NativeToolActivity(
            id: "live", toolID: tool.id, name: tool.name, title: tool.title, round: 1, request: "{}",
            result: try NativeToolResultBudget.serialized(value, maximumBytes: NativeToolResultBudget.defaultBytes),
            state: .succeeded, confirmationRequired: false)
        guard let image = NativeImageTools.attachment(from: activity), let fileName = image.fileName,
              let url = attachments.url(for: fileName), attachments.image(for: fileName) != nil else {
            throw NativeToolError.failed("The live run returned no image")
        }
        print("LIVE IMAGE OK \(url.path) \(image.byteSize ?? 0) bytes in \(elapsed)")
    }

    static func runNativeImageTools() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vera-selftest-images-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachments = NativeAttachmentStore(directory: directory)
        let transport = SelfTestComfyTransport()
        let base = URL(string: "http://comfy.example:8188")!
        func definitions(base: URL?) -> [NativeToolDefinition] {
            NativeImageTools.definitions(
                base: { base }, attachments: attachments, transport: transport.transport,
                pollInterval: .milliseconds(20))
        }
        do {
            let graph = try NativeImageGraph.bundled()
            let filled = graph.filled(prompt: "a red door", size: NativeImageSize(width: 1536, height: 1024), seed: 7)
            let encoded = try JSONSerialization.data(withJSONObject: filled, options: [.sortedKeys])
            let text = String(decoding: encoded, as: UTF8.self)
            guard !text.contains("{{"), text.contains("\"prompt\":\"a red door\""),
                  text.contains("\"width\":1536"), text.contains("\"height\":1024"), text.contains("\"seed\":7"),
                  !text.contains("\"seed\":\"7\"") else {
                print("SELFTEST ERROR: image graph slot substitution \(text.prefix(400))"); exit(1)
            }
            let broken = Data("{\"a\":{\"class_type\":\"X\",\"inputs\":{\"prompt\":\"{{prompt}}\",\"width\":\"{{width}}\"}}}".utf8)
            guard (try? NativeImageGraph.load(broken)) == nil else {
                print("SELFTEST ERROR: image graph accepted missing slots"); exit(1)
            }
            guard try NativeImageSize.parse(nil) == .standard,
                  try NativeImageSize.parse("1536x1024") == NativeImageSize(width: 1536, height: 1024),
                  try NativeImageSize.parse("1920 × 1082") == NativeImageSize(width: 1920, height: 1080),
                  (try? NativeImageSize.parse("100x100")) == nil,
                  (try? NativeImageSize.parse("4096x1024")) == nil,
                  (try? NativeImageSize.parse("big")) == nil else {
                print("SELFTEST ERROR: image size parsing"); exit(1)
            }
            let tools = definitions(base: base)
            guard tools.map(\.name) == [NativeImageTools.toolName], tools.map(\.id) == [NativeImageTools.toolID],
                  tools[0].timeout == NativeImageTools.timeout,
                  case .object(let schema) = tools[0].parameters,
                  case .array(let required)? = schema["required"], required == [.string("prompt")],
                  schema["additionalProperties"] == .bool(false) else {
                print("SELFTEST ERROR: image tool definition"); exit(1)
            }
            guard NativeToolRegistry(definitions: definitions(base: nil)).active(enabledIDs: [NativeImageTools.toolID]).isEmpty,
                  NativeToolRegistry(definitions: tools).active(enabledIDs: [NativeImageTools.toolID]).count == 1,
                  NativeChatToolCatalog.tools(veraAPIConfigured: false, imageConfigured: false)
                      .first(where: { $0.id == NativeImageTools.toolID })?.available == false,
                  NativeChatToolCatalog.tools(veraAPIConfigured: false, imageConfigured: true)
                      .first(where: { $0.id == NativeImageTools.toolID })?.available == true,
                  ChatStore.builtInToolNames.contains(NativeImageTools.toolName) else {
                print("SELFTEST ERROR: image tool gating"); exit(1)
            }
            guard NativeImageTools.base(from: " http://comfy.example:8188 ") != nil,
                  NativeImageTools.base(from: "") == nil,
                  NativeImageTools.base(from: "comfy.example") == nil,
                  NativeImageTools.base(from: "ftp://comfy.example") == nil else {
                print("SELFTEST ERROR: image base validation"); exit(1)
            }
            let note = NativeContextAssembler.assemble(NativeContextInput(
                persona: "You are Vera.", timestamp: Date(timeIntervalSince1970: 1_786_000_000),
                timeZone: TimeZone(identifier: "America/Chicago")!, unavailableNotes: [NativeImageTools.unavailableNote]))
            guard let unavailable = note.sections.first(where: { $0.name == "unavailable" }),
                  unavailable.content.hasPrefix("NOT AVAILABLE"), unavailable.content.contains("Image tab"),
                  NativeContextAssembler.assemble(NativeContextInput(
                      persona: "You are Vera.", timestamp: Date(), timeZone: .current)).sections
                      .contains(where: { $0.name == "unavailable" }) == false else {
                print("SELFTEST ERROR: image unavailable context note"); exit(1)
            }

            let swatch = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                NSColor.systemTeal.setFill()
                rect.fill()
                return true
            }
            guard let pngData = swatch.pngData else {
                print("SELFTEST ERROR: image fixture png"); exit(1)
            }
            let registry = NativeToolRegistry(definitions: tools)
            let call = NativeChatToolCall(id: "image-1", name: NativeImageTools.toolName,
                                          arguments: "{\"prompt\":\"a red door\",\"size\":\"1024x1024\",\"seed\":7}")
            func rounds(_ answer: String) -> [[NativeChatStreamSnapshot]] {
                [
                    [NativeChatStreamSnapshot(content: "", toolCalls: [call], finishReason: "tool_calls")],
                    [NativeChatStreamSnapshot(content: answer, toolCalls: [], finishReason: "stop")],
                ]
            }
            func run(_ answer: String) async throws -> (NativeToolTurnSnapshot?, [NativeToolProgress]) {
                var final: NativeToolTurnSnapshot?
                var seen: [NativeToolProgress] = []
                for try await snapshot in NativeToolLoop(transport: ScriptedNativeToolTransport(rounds: rounds(answer)), registry: registry)
                    .stream(messages: [NativeChatMessage(role: "user", content: "Make an image")],
                            model: "local-model", enabledToolIDs: [NativeImageTools.toolID]) {
                    if let progress = snapshot.activities.first?.progress { seen.append(progress) }
                    final = snapshot
                }
                return (final, seen)
            }

            transport.respond("POST", "prompt", status: 200, json: "{\"prompt_id\":\"p1\",\"number\":3,\"node_errors\":{}}")
            transport.respond("GET", "history/p1", status: 200, json: "{}")
            transport.respond("GET", "history/p1", status: 200, json: """
            {"p1":{"status":{"status_str":"success","completed":true},"outputs":{"save":{"images":[{"filename":"tandem_00001_.png","subfolder":"","type":"output"}]}}}}
            """)
            transport.respond("GET", "view", status: 200, data: pngData)
            transport.events([
                .progress(completed: 10, total: 40, promptID: "p1"),
                .progress(completed: 40, total: 40, promptID: "p1"),
                .finished(promptID: "p1"),
            ])
            let (success, progress) = try await run("Here is the door.")
            guard let activity = success?.activities.first, activity.state == .succeeded, activity.progress == nil,
                  success?.content == "Here is the door.",
                  progress.map(\.label) == ["Step 10 of 40", "Step 40 of 40"],
                  let image = NativeImageTools.attachment(from: activity),
                  image.name == "a-red-door-1024x1024.png", image.mime == "image/png",
                  let fileName = image.fileName, attachments.image(for: fileName) != nil,
                  activity.result?.contains("\"seed\":7") == true else {
                print("SELFTEST ERROR: image generation success path \(String(describing: success))"); exit(1)
            }
            let queued = transport.requests.first { $0.method == "POST" && $0.path == "prompt" }
            let prompt = queued?.body?["prompt"] as? [String: Any]
            let promptText = ((prompt?["encode"] as? [String: Any])?["inputs"] as? [String: Any])?["prompt"] as? String
            let width = ((prompt?["latent"] as? [String: Any])?["inputs"] as? [String: Any])?["width"] as? Int
            let seed = ((prompt?["sampler"] as? [String: Any])?["inputs"] as? [String: Any])?["seed"] as? Int
            guard promptText == "a red door", width == 1024, seed == 7,
                  queued?.body?["client_id"] as? String == ComfyUIClient.clientID,
                  transport.requests.contains(where: { $0.method == "GET" && $0.path == "view" }) else {
                print("SELFTEST ERROR: image queue request shape"); exit(1)
            }

            transport.reset()
            transport.respond("POST", "prompt", status: 400, json: """
            {"error":{"type":"prompt_outputs_failed_validation","message":"Prompt outputs failed validation","details":""},"node_errors":{"unet":{"errors":[{"type":"value_not_in_list","message":"Value not in list","details":"unet_name: 'missing.safetensors' not in ['qwen.safetensors']"}]}}}
            """)
            let (rejected, _) = try await run("The server rejected it.")
            guard rejected?.activities.first?.state == .failed,
                  rejected?.activities.first?.result?.contains("Value not in list") == true,
                  rejected?.activities.first?.result?.contains("unet_name") == true,
                  transport.requests.filter({ $0.path == "prompt" }).count == 1 else {
                print("SELFTEST ERROR: image queue rejection \(String(describing: rejected))"); exit(1)
            }

            transport.reset()
            transport.respond("POST", "prompt", status: 200, json: "{\"prompt_id\":\"p2\"}")
            transport.respond("GET", "history/p2", status: 200, json: """
            {"p2":{"status":{"status_str":"error","completed":false,"messages":[["execution_start",{"prompt_id":"p2"}],["execution_error",{"prompt_id":"p2","node_type":"KSampler","exception_message":"CUDA out of memory"}]]},"outputs":{}}}
            """)
            transport.events(nil)
            let (errored, _) = try await run("It failed.")
            guard errored?.activities.first?.state == .failed,
                  errored?.activities.first?.result?.contains("KSampler: CUDA out of memory") == true else {
                print("SELFTEST ERROR: image execution error \(String(describing: errored))"); exit(1)
            }

            transport.reset()
            transport.fail(with: URLError(.cannotConnectToHost))
            let (down, _) = try await run("The server is down.")
            guard down?.activities.first?.state == .failed,
                  down?.activities.first?.result?.contains("unreachable") == true,
                  transport.requests.map(\.path) == ["prompt"] else {
                print("SELFTEST ERROR: image server down \(String(describing: down))"); exit(1)
            }

            transport.reset()
            transport.respond("POST", "prompt", status: 200, json: "{\"prompt_id\":\"p3\"}")
            transport.respond("GET", "history/p3", status: 200, json: "{}")
            transport.respond("GET", "queue", status: 200, json: "{\"queue_running\":[[1,\"p3\",{},{}]],\"queue_pending\":[]}")
            transport.respond("POST", "interrupt", status: 200, json: "{}")
            transport.events([.progress(completed: 2, total: 40, promptID: "p3")], hold: true)
            let runner = Task {
                try await run("Never.")
            }
            let started = ContinuousClock.now
            while !transport.requests.contains(where: { $0.path == "history/p3" }), started.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            runner.cancel()
            let outcome = await runner.result
            let interruptStart = ContinuousClock.now
            while !transport.requests.contains(where: { $0.method == "POST" && $0.path == "interrupt" }),
                  interruptStart.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let completedAfterCancel: Bool
            switch outcome {
            case .success(let result): completedAfterCancel = result.0?.activities.first?.state == .succeeded
            case .failure(let error): completedAfterCancel = !(error is CancellationError)
            }
            guard !completedAfterCancel,
                  transport.requests.contains(where: { $0.method == "POST" && $0.path == "interrupt" }),
                  !transport.requests.contains(where: { $0.path == "view" }) else {
                print("SELFTEST ERROR: image cancel interrupt \(transport.requests.map(\.path))"); exit(1)
            }

            transport.reset()
            transport.respond("POST", "prompt", status: 200, json: "{\"prompt_id\":\"p4\"}")
            transport.respond("GET", "history/p4", status: 200, json: "{}")
            transport.respond("GET", "queue", status: 200, json: "{\"queue_running\":[],\"queue_pending\":[[2,\"p4\",{},{}]]}")
            transport.respond("POST", "queue", status: 200, json: "{}")
            let pendingRunner = Task { try await run("Never.") }
            let pendingStart = ContinuousClock.now
            while !transport.requests.contains(where: { $0.path == "history/p4" }), pendingStart.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            pendingRunner.cancel()
            _ = await pendingRunner.result
            let deleteStart = ContinuousClock.now
            while !transport.requests.contains(where: { $0.method == "POST" && $0.path == "queue" }),
                  deleteStart.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let deletion = transport.requests.first(where: { $0.method == "POST" && $0.path == "queue" }),
                  (deletion.body?["delete"] as? [String]) == ["p4"],
                  !transport.requests.contains(where: { $0.path == "interrupt" }) else {
                print("SELFTEST ERROR: image cancel pending delete \(transport.requests.map(\.path))"); exit(1)
            }

            guard ComfyUIClient.parseEvent("{\"type\":\"progress\",\"data\":{\"value\":3,\"max\":40,\"prompt_id\":\"x\"}}")
                      == .progress(completed: 3, total: 40, promptID: "x"),
                  ComfyUIClient.parseEvent("{\"type\":\"executing\",\"data\":{\"node\":null,\"prompt_id\":\"x\"}}") == .finished(promptID: "x"),
                  ComfyUIClient.parseEvent("{\"type\":\"executing\",\"data\":{\"node\":\"sampler\",\"prompt_id\":\"x\"}}") == nil,
                  ComfyUIClient.parseEvent("{\"type\":\"execution_interrupted\",\"data\":{\"prompt_id\":\"x\"}}") == .interrupted(promptID: "x"),
                  ComfyUIClient.parseEvent("{\"type\":\"execution_error\",\"data\":{\"prompt_id\":\"x\",\"node_type\":\"VAEDecode\",\"exception_message\":\"boom\"}}")
                      == .failed(promptID: "x", message: "VAEDecode: boom"),
                  ComfyUIClient.parseEvent("{\"type\":\"status\",\"data\":{}}") == nil,
                  ComfyUIClient.parseEvent("not json") == nil else {
                print("SELFTEST ERROR: image websocket event parsing"); exit(1)
            }

            var canceledMessage = Message(role: .assistant, text: "")
            canceledMessage.toolActivities = [activity]
            let encodedActivity = try JSONEncoder().encode(activity)
            let decodedActivity = try JSONDecoder().decode(NativeToolActivity.self, from: encodedActivity)
            let legacy = Data("{\"id\":\"a\",\"toolID\":\"t\",\"name\":\"n\",\"title\":\"T\",\"round\":1,\"request\":\"{}\",\"state\":\"pending\",\"confirmationRequired\":false}".utf8)
            let decodedLegacy = try JSONDecoder().decode(NativeToolActivity.self, from: legacy)
            guard decodedActivity == activity, decodedLegacy.progress == nil, decodedLegacy.state == .pending else {
                print("SELFTEST ERROR: image activity progress coding"); exit(1)
            }
            print("  native image tools OK (graph slots, sizes, gating, progress, artifact, rejection, run error, server down, cancel interrupt, pending delete, events)")
        } catch {
            print("SELFTEST ERROR: native image tools \(error)"); exit(1)
        }
    }
}
