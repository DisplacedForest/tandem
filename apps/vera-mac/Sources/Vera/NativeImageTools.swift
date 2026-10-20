import Foundation

struct NativeImageSize: Equatable, Sendable {
    let width: Int
    let height: Int

    static let standard = NativeImageSize(width: 1024, height: 1024)
    static let minimumSide = 256
    static let maximumSide = 2048
    static let step = 8

    static func parse(_ raw: String?) throws -> NativeImageSize {
        guard let raw else { return .standard }
        let text = raw.lowercased().replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: " ", with: "")
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            throw NativeToolError.invalidArguments("Size must look like 1024x1024")
        }
        return NativeImageSize(width: try side(width), height: try side(height))
    }

    private static func side(_ value: Int) throws -> Int {
        guard value >= minimumSide, value <= maximumSide else {
            throw NativeToolError.invalidArguments("Each side must be between \(minimumSide) and \(maximumSide) pixels")
        }
        return Int((Double(value) / Double(step)).rounded()) * step
    }

    var label: String { "\(width)x\(height)" }
}

struct NativeImageGraph: Sendable {
    static let resourceName = "qwen-image-2.1"
    static let slots = ["prompt", "width", "height", "seed"]

    let template: Data

    static func bundled() throws -> NativeImageGraph {
        guard let url = VeraResources.url(resourceName, ext: "json") else {
            throw NativeToolError.failed("The image graph resource is missing from this build")
        }
        return try load(Data(contentsOf: url))
    }

    static func load(_ data: Data) throws -> NativeImageGraph {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            throw NativeToolError.failed("The image graph resource is not a JSON object")
        }
        let found = Set(slotNames(in: object))
        let missing = slots.filter { !found.contains($0) }
        guard missing.isEmpty else {
            throw NativeToolError.failed("The image graph resource is missing slots: \(missing.joined(separator: ", "))")
        }
        return NativeImageGraph(template: data)
    }

    func filled(prompt: String, size: NativeImageSize, seed: UInt64) -> [String: Any] {
        let values: [String: Any] = [
            "prompt": prompt, "width": size.width, "height": size.height, "seed": seed,
        ]
        let object = (try? JSONSerialization.jsonObject(with: template) as? [String: Any]) ?? [:]
        return Self.substitute(object, values: values) as? [String: Any] ?? [:]
    }

    private static func slotNames(in value: Any) -> [String] {
        switch value {
        case let text as String:
            if let name = slotName(text) { return [name] }
            return []
        case let object as [String: Any]:
            return object.values.flatMap(slotNames(in:))
        case let array as [Any]:
            return array.flatMap(slotNames(in:))
        default:
            return []
        }
    }

    private static func slotName(_ text: String) -> String? {
        guard text.hasPrefix("{{"), text.hasSuffix("}}"), text.count > 4 else { return nil }
        return String(text.dropFirst(2).dropLast(2))
    }

    private static func substitute(_ value: Any, values: [String: Any]) -> Any {
        switch value {
        case let text as String:
            if let name = slotName(text), let replacement = values[name] { return replacement }
            return text
        case let object as [String: Any]:
            return object.mapValues { substitute($0, values: values) }
        case let array as [Any]:
            return array.map { substitute($0, values: values) }
        default:
            return value
        }
    }
}

enum NativeImageTools {
    static let toolID = "generate-image"
    static let toolName = "generate_image"
    static let title = "Generate an image"
    static let timeout = Duration.seconds(280)
    static let configKey = "comfyui_base"
    static let envName = "VERA_COMFYUI_BASE"
    static let maximumSeed: UInt64 = 1 << 53
    static let unavailableNote = "Image generation is not set up. If asked to make, draw or generate an image, say that plainly and point to the Image tab in Settings. Do not describe an image as if it had been made."

    static func resolvedBase() -> URL? {
        let env = ProcessInfo.processInfo.environment[envName]
        let raw = (env?.isEmpty == false ? env : nil) ?? ConfigFile.read()[configKey] as? String
        return base(from: raw)
    }

    static func base(from raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    static func definitions(
        base: @escaping @Sendable () -> URL?,
        attachments: NativeAttachmentStore,
        transport: ComfyUITransport = .live,
        graph: @escaping @Sendable () throws -> NativeImageGraph = { try NativeImageGraph.bundled() },
        pollInterval: Duration = .seconds(1)
    ) -> [NativeToolDefinition] {
        [
            NativeToolDefinition(
                id: toolID,
                name: toolName,
                title: title,
                description: "Generate an image from a text description. The finished image is shown to the user on this turn, so describe what was made in a sentence instead of linking to it. Write the prompt as a full description of the finished picture: subject, setting, style, lighting, and any exact text to render in quotes.",
                parameters: objectSchema(
                    properties: [
                        "prompt": .object(["type": .string("string"), "description": .string("A complete description of the image to make")]),
                        "size": .object(["type": .string("string"), "description": .string("Optional width x height in pixels such as 1024x1024 (default), 1536x1024 or 2048x2048. Each side 256 to 2048.")]),
                        "seed": .object(["type": .string("integer"), "description": .string("Optional seed for a repeatable result")]),
                    ], required: ["prompt"]),
                confirmation: .none,
                timeout: timeout,
                isAvailable: { base() != nil },
                execute: { arguments in
                    guard let prompt = arguments.imageString("prompt") else {
                        throw NativeToolError.invalidArguments("A prompt is required")
                    }
                    let size = try NativeImageSize.parse(arguments.imageString("size"))
                    let seed = try arguments.imageSeed("seed") ?? UInt64.random(in: 0...NativeImageTools.maximumSeed)
                    guard let base = base() else { throw NativeToolError.unavailable }
                    let template = try graph()
                    var client = ComfyUIClient(base: base, transport: transport)
                    client.pollInterval = pollInterval
                    let output = try await client.generate(graph: template.filled(prompt: prompt, size: size, seed: seed)) { completed, total in
                        NativeToolProgressReporter.post(NativeToolProgress(
                            completed: completed, total: total, label: "Step \(completed) of \(total)"))
                    }
                    let attachment: MessageAttachment
                    do {
                        attachment = try attachments.save(data: output.data, preferredName: preferredName(prompt: prompt, size: size))
                    } catch {
                        throw NativeToolError.failed("The image could not be saved: \(error.localizedDescription)")
                    }
                    let encoded = try JSONEncoder().encode(attachment)
                    let image = try NativeJSONValue(any: JSONSerialization.jsonObject(with: encoded))
                    return .object([
                        "image": image,
                        "width": .number(Double(size.width)),
                        "height": .number(Double(size.height)),
                        "seed": .number(Double(seed)),
                        "shown": .string("The image is displayed to the user on this turn."),
                    ])
                }),
        ]
    }

    static func descriptor(configured: Bool) -> NativeChatToolDescriptor {
        NativeChatToolDescriptor(
            id: toolID,
            name: "Image generation",
            summary: "Makes images on your ComfyUI server from a description.",
            available: configured,
            setup: "Set the ComfyUI URL in the Image tab to enable image generation.")
    }

    static func attachment(from activity: NativeToolActivity) -> MessageAttachment? {
        guard activity.name == toolName, activity.state == .succeeded,
              let raw = activity.result?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let image = object["image"],
              let data = try? JSONSerialization.data(withJSONObject: image),
              let attachment = try? JSONDecoder().decode(MessageAttachment.self, from: data),
              attachment.isImage, attachment.fileName?.isEmpty == false else { return nil }
        return attachment
    }

    static func preferredName(prompt: String, size: NativeImageSize) -> String {
        let words = prompt.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(6)
        let slug = words.map { $0.lowercased() }.joined(separator: "-")
        return (slug.isEmpty ? "image" : slug) + "-" + size.label + ".png"
    }

    private static func objectSchema(
        properties: [String: NativeJSONValue], required: [String]
    ) -> NativeJSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(NativeJSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }
}

private extension Dictionary where Key == String, Value == NativeJSONValue {
    func imageString(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func imageSeed(_ key: String) throws -> UInt64? {
        guard let value = self[key], value != .null else { return nil }
        let parsed: UInt64?
        switch value {
        case .number(let number):
            parsed = UInt64(exactly: number)
        case .string(let text):
            parsed = UInt64(text.trimmingCharacters(in: .whitespaces))
        default:
            parsed = nil
        }
        guard let parsed, parsed <= NativeImageTools.maximumSeed else {
            throw NativeToolError.invalidArguments("Seed must be a whole number up to \(NativeImageTools.maximumSeed)")
        }
        return parsed
    }
}
