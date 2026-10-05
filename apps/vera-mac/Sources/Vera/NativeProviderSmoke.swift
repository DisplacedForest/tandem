import AppKit
import Foundation

private final class ProviderSmokeRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
enum NativeProviderSmoke {
    struct Failure: Error {
        let reason: String
    }

    struct Model {
        let id: String
        let inputPrice: Double
        let outputPrice: Double
        var forecast: Double { 3 * (4096 * inputPrice + 256 * outputPrice) }
    }

    static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw Failure(reason: reason) }
    }

    static func model(from catalog: [String: Any], id: String) throws -> Model {
        guard let entries = catalog["data"] as? [[String: Any]] else {
            throw Failure(reason: "Malformed model catalog")
        }
        let matches = entries.filter { $0["id"] as? String == id }
        guard matches.count == 1, let entry = matches.first,
              entry["alias_target"] == nil,
              let architecture = entry["architecture"] as? [String: Any],
              let inputs = architecture["input_modalities"] as? [String], inputs.contains("image"),
              let parameters = entry["supported_parameters"] as? [String],
              Set(["tools", "tool_choice", "max_tokens", "reasoning"]).isSubset(of: Set(parameters)),
              let reasoning = entry["reasoning"] as? [String: Any], reasoning["mandatory"] as? Bool == false,
              let pricing = entry["pricing"] as? [String: Any], pricing["overrides"] == nil,
              let inputText = pricing["prompt"] as? String, let input = Double(inputText),
              let outputText = pricing["completion"] as? String, let output = Double(outputText),
              input.isFinite, output.isFinite, input >= 0, output >= 0 else {
            throw Failure(reason: "Exact model or supported capabilities/pricing unavailable; no substitution")
        }
        for (key, value) in pricing where !["prompt", "completion", "input_cache_read", "input_cache_write"].contains(key) {
            try require((value as? String).flatMap(Double.init) == 0, "Additional pricing requires a new forecast")
        }
        return Model(id: id, inputPrice: input, outputPrice: output)
    }

    static func approvedBudget(_ text: String?, forecast: Double) throws -> Double {
        guard let text, let amount = Double(text), amount.isFinite, amount > 0,
              forecast.isFinite, amount >= forecast else {
            throw Failure(reason: "An approved budget covering the forecast is required")
        }
        return amount
    }

    static func savedProfile(from raw: [String: Any]) throws -> NativeEndpointProfile {
        guard let settings = raw["native_chat"] as? [String: Any],
              let activeID = settings["activeProfileID"] as? String, !activeID.isEmpty,
              let profiles = settings["profiles"] as? [[String: Any]] else {
            throw Failure(reason: "An explicitly active saved OpenRouter profile is required")
        }
        let matches = profiles.filter { $0["id"] as? String == activeID }
        guard matches.count == 1, let entry = matches.first,
              let data = try? JSONSerialization.data(withJSONObject: entry),
              let profile = try? JSONDecoder().decode(NativeEndpointProfile.self, from: data),
              let url = URL(string: profile.baseURL), url.scheme == "https", url.host == "openrouter.ai",
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "api/v1",
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw Failure(reason: "Save and select the OpenRouter endpoint in Vera Settings > Endpoints")
        }
        return profile
    }

    static func redImage() throws -> String {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 96, bitsPerPixel: 24),
              let pixels = bitmap.bitmapData else { throw Failure(reason: "Synthetic image creation failed") }
        for index in 0..<1024 {
            pixels[index * 3] = 255
            pixels[index * 3 + 1] = 0
            pixels[index * 3 + 2] = 0
        }
        guard let tagged = bitmap.retagging(with: .sRGB),
              let png = tagged.representation(using: .png, properties: [:]) else {
            throw Failure(reason: "Synthetic image encoding failed")
        }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static func toolMessages(from snapshot: NativeChatStreamSnapshot) throws -> [NativeChatMessage] {
        try require(snapshot.finishReason == "tool_calls" && snapshot.toolCalls.count == 1,
                    "Expected exactly one synthetic tool call")
        let call = snapshot.toolCalls[0]
        try require(call.name == "synthetic_add" && !call.id.isEmpty && call.id.count <= 128,
                    "Unknown or malformed tool refused")
        guard let data = call.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode([String: Int].self, from: data),
              args == ["a": 19, "b": 23] else {
            throw Failure(reason: "Tool arguments did not match the synthetic fixture")
        }
        return [
            NativeChatMessage(role: "assistant", content: "", toolCalls: [
                NativeChatToolCall(id: call.id, name: "synthetic_add", arguments: "{\"a\":19,\"b\":23}")]),
            NativeChatMessage(role: "tool", content: "{\"result\":42}", toolCallID: call.id),
        ]
    }

    static func usageCost(from response: [String: Any]) throws -> Double {
        guard let usage = response["usage"] as? [String: Any], let number = usage["cost"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0 else {
            throw Failure(reason: "Valid usage cost missing; stopping")
        }
        return number.doubleValue
    }

    static func fetch(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(reason: "Invalid HTTP response") }
        var data = Data()
        for try await byte in bytes {
            try require(data.count < 2_000_000, "Response size limit reached")
            data.append(byte)
        }
        if !(200..<300).contains(http.statusCode) {
            var category = "response body withheld"
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                let text = message.lowercased()
                if text.contains("no endpoints") {
                    category = "no eligible provider endpoint"
                    if text.contains("data policy") { category = "no endpoint matches account data policy" }
                    if text.contains("parameters") { category = "no endpoint supports required parameters" }
                    if text.contains("price") { category = "no endpoint within price ceiling" }
                } else if text.contains("model") && (text.contains("not found") || text.contains("not a valid")) {
                    category = "exact model unavailable"
                }
            }
            throw Failure(reason: "HTTP \(http.statusCode); " + category)
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(reason: "Malformed JSON response")
        }
        return result
    }

    static func run(arguments: [String]) async {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        do {
            let profile = try savedProfile(from: ConfigFile.read())
            if arguments.contains("--credential-status") {
                let available = KeychainNativeCredentialStore(allowsInteraction: false).value(for: profile.id)?.isEmpty == false
                emit(["mode": "credential-status", "credential_available_without_prompt": available])
                exit(available ? 0 : 1)
            }
            let id = value("--model") ?? ""
            try require(!id.isEmpty || arguments.contains("--access-status"), "Explicit --model is required")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: ProviderSmokeRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let root = URL(string: profile.baseURL)!
            if arguments.contains("--access-status") {
                guard let key = KeychainNativeCredentialStore(allowsInteraction: false).value(for: profile.id), !key.isEmpty else {
                    throw Failure(reason: "Saved credential unavailable without a Keychain prompt")
                }
                var request = URLRequest(url: root.appendingPathComponent("key"))
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                _ = try await fetch(request, session: session)
                emit(["mode": "access-status", "authentication": "verified"])
                exit(0)
            }
            let catalog = try await fetch(URLRequest(url: root.appendingPathComponent("models")), session: session)
            let selected = try model(from: catalog, id: id)
            emit(["mode": "preflight", "model": id, "forecast_usd": selected.forecast, "max_requests": 3])
            guard arguments.contains("--live") else { exit(0) }
            let budget = try approvedBudget(value("--approved-budget-usd"), forecast: selected.forecast)
            guard let key = KeychainNativeCredentialStore(allowsInteraction: false).value(for: profile.id), !key.isEmpty else {
                throw Failure(reason: "Saved credential unavailable without a Keychain prompt; no alternate key tried")
            }
            let client = NativeChatClient(config: NativeChatConfig(
                baseURL: root, apiKey: key, model: id, chatTemplateKwargs: nil, streaming: false))
            let schema = NativeToolSchema(name: "synthetic_add", description: "Add two synthetic integers.", parameters: .object([
                "type": .string("object"), "properties": .object([
                    "a": .object(["type": .string("integer")]), "b": .object(["type": .string("integer")])]),
                "required": .array([.string("a"), .string("b")]), "additionalProperties": .bool(false),
            ]))
            var spent = 0.0
            var requests = 0
            func complete(_ messages: [NativeChatMessage], tool: Bool = false) async throws -> NativeChatStreamSnapshot {
                try require(requests < 3 && spent + selected.forecast / 3 <= budget, "Request or remaining budget limit reached")
                var request = try client.request(messages: messages, model: id, tools: tool ? [schema] : [])
                var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                body["max_tokens"] = 256
                body["reasoning"] = ["enabled": false]
                body["provider"] = ["allow_fallbacks": false, "require_parameters": true,
                                    "max_price": ["prompt": selected.inputPrice * 1_000_000,
                                                  "completion": selected.outputPrice * 1_000_000]]
                if tool { body["tool_choice"] = ["type": "function", "function": ["name": "synthetic_add"]] }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 30
                requests += 1
                let start = Date()
                let response = try await fetch(request, session: session)
                try require(response["error"] == nil && response["model"] as? String == id, "Provider error or model mismatch")
                let cost = try usageCost(from: response)
                spent += cost
                emit(["mode": "live-request", "request": requests, "cost_usd": cost,
                      "total_cost_usd": spent, "seconds": Date().timeIntervalSince(start)])
                try require(spent <= budget, "Reported cost exceeded approved budget; stopped")
                let snapshot = try NativeChatClient.completeSnapshot(from: JSONSerialization.data(withJSONObject: response))
                try require(snapshot.finishReason == (tool ? "tool_calls" : "stop"), "Unexpected completion termination")
                return snapshot
            }
            var messages = [NativeChatMessage(role: "user", content:
                "Call synthetic_add with a=19 and b=23. After the tool result, reply with only the result integer.")]
            messages += try toolMessages(from: await complete(messages, tool: true))
            let answer = try await complete(messages)
            try require(answer.toolCalls.isEmpty && answer.content.trimmingCharacters(in: .whitespacesAndNewlines) == "42",
                        "Tool continuation did not return 42")
            let vision = try await complete([NativeChatMessage(role: "user", content:
                "What is the solid color of this image? Reply with one lowercase color word.", images: [redImage()])])
            try require(vision.toolCalls.isEmpty && vision.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "red",
                        "Image recognition did not return red")
            emit(["mode": "live", "model": id, "requests": requests, "cost_usd": spent,
                  "tool_call": "passed", "tool_continuation": "passed", "image_input": "passed",
                  "scope": "native provider smoke; API worker integration not tested"])
            exit(0)
        } catch let error as Failure {
            emit(["status": "blocked_or_failed", "reason": error.reason])
            exit(1)
        } catch {
            emit(["status": "blocked_or_failed", "reason": "Network or response failure; details withheld"])
            exit(1)
        }
    }

    static func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }

    static func selfTest() {
        do {
            func rejects(_ operation: () throws -> Void) throws {
                var rejected = false
                do { try operation() } catch { rejected = true }
                try require(rejected, "Invalid input accepted")
            }
            let entry: [String: Any] = [
                "id": "test/vision", "architecture": ["input_modalities": ["text", "image"]],
                "supported_parameters": ["tools", "tool_choice", "max_tokens", "reasoning"],
                "reasoning": ["mandatory": false],
                "pricing": ["prompt": "0.00000015", "completion": "0.00000047"],
            ]
            let selected = try model(from: ["data": [entry]], id: "test/vision")
            try require(abs(selected.forecast - 0.00220416) < 0.000000001, "Forecast test failed")
            try rejects { _ = try model(from: ["data": [entry]], id: "test/other") }
            try rejects { _ = try model(from: ["data": [entry, entry]], id: "test/vision") }
            for invalidCost: Any in [false, true, "0", -1, Double.infinity, NSNull()] {
                try rejects { _ = try usageCost(from: ["usage": ["cost": invalidCost]]) }
            }
            try require(try usageCost(from: ["usage": ["cost": 0.0001]]) == 0.0001, "Usage receipt test failed")
            for replacement: [String: Any] in [
                ["alias_target": ["slug": "test/other"]], ["reasoning": ["mandatory": true]],
                ["supported_parameters": []], ["architecture": ["input_modalities": ["text"]]],
                ["pricing": ["prompt": "nan", "completion": "0"]],
                ["pricing": ["prompt": "0", "completion": "0", "request": "1"]],
            ] {
                let invalidEntry = entry.merging(replacement) { _, new in new }
                try rejects { _ = try model(from: ["data": [invalidEntry]], id: "test/vision") }
            }
            for budget in [nil, "0", "-1", "nan", "inf", "0.00001"] as [String?] {
                try rejects { _ = try approvedBudget(budget, forecast: selected.forecast) }
            }
            _ = try approvedBudget("0.01", forecast: selected.forecast)
            var settings = NativeChatSettings.fresh
            settings.addProfile()
            settings.updateActiveProfile { $0.baseURL = "https://openrouter.ai/api/v1" }
            _ = try savedProfile(from: settings.merging(into: [:]))
            var absentActive = settings
            absentActive.activeProfileID = "missing"
            try rejects { _ = try savedProfile(from: absentActive.merging(into: [:])) }
            absentActive.activeProfileID = nil
            try rejects { _ = try savedProfile(from: absentActive.merging(into: [:])) }
            try rejects { _ = try savedProfile(from: ["model_base": "https://openrouter.ai/api/v1", "model": "test/vision"]) }
            var duplicate = settings
            duplicate.profiles += settings.profiles
            try rejects { _ = try savedProfile(from: duplicate.merging(into: [:])) }
            for badURL in ["http://openrouter.ai/api/v1", "https://other.example/api/v1",
                           "https://openrouter.ai/api/v1?key=example", "https://openrouter.ai:444/api/v1"] {
                var invalidSettings = settings
                invalidSettings.updateActiveProfile { $0.baseURL = badURL }
                try rejects { _ = try savedProfile(from: invalidSettings.merging(into: [:])) }
            }
            let snapshot = NativeChatStreamSnapshot(content: "untrusted content", toolCalls: [
                NativeChatToolCall(id: "synthetic", name: "synthetic_add", arguments: "{\"a\":19,\"b\":23}")], finishReason: "tool_calls")
            let messages = try toolMessages(from: snapshot)
            try require(messages[0].content.isEmpty && messages[1].content == "{\"result\":42}", "Sanitization test failed")
            let invalid = NativeChatStreamSnapshot(content: "", toolCalls: [
                NativeChatToolCall(id: "synthetic", name: "synthetic_add", arguments: "{\"a\":true,\"b\":23}")], finishReason: "tool_calls")
            try rejects { _ = try toolMessages(from: invalid) }
            try rejects { _ = try toolMessages(from: NativeChatStreamSnapshot(
                content: "", toolCalls: snapshot.toolCalls + snapshot.toolCalls, finishReason: "tool_calls")) }
            let image = try redImage()
            guard let imageData = Data(base64Encoded: String(image.dropFirst("data:image/png;base64,".count))),
                  let bitmap = NSBitmapImageRep(data: imageData),
                  let color = bitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB) else {
                throw Failure(reason: "Image decoding test failed")
            }
            try require(bitmap.pixelsWide == 32 && bitmap.pixelsHigh == 32
                        && color.redComponent > 0.9 && color.greenComponent < 0.25 && color.blueComponent < 0.25,
                        "Image fixture test failed")
            print("PROVIDER SMOKE SELFTEST OK (offline fixtures only)")
            exit(0)
        } catch let error as Failure {
            print("PROVIDER SMOKE SELFTEST FAILED: " + error.reason)
            exit(1)
        } catch {
            print("PROVIDER SMOKE SELFTEST FAILED")
            exit(1)
        }
    }
}
