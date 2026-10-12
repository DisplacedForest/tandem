import Foundation

private final class NativeAdmissionMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    func record(_ name: String, _ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        values[name] = value
    }
    func snapshot() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

struct NativeInferenceAdmissionFixture {
    struct Configuration: Decodable, Sendable {
        let base: String
        let scenario: String
        let resource_urls: [String]?
    }

    static func run(_ raw: String) async throws {
        let input = try JSONDecoder().decode(Configuration.self, from: Data(raw.utf8))
        guard let base = URL(string: input.base), base.scheme == "http",
              ["127.0.0.1", "localhost"].contains(base.host ?? "") else {
            throw NativeInferenceAdmission.AdmissionError.malformed
        }
        let endpoint = base.appendingPathComponent("v1")
        let measurements = NativeAdmissionMeasurements()
        let admission = NativeInferenceAdmission(baseURL: base, observe: { name, value in
            measurements.record(name, value)
            if input.scenario == "cancel-after-grant" && name == "admission_seconds" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        let config = NativeChatConfig(baseURL: endpoint, apiKey: "synthetic-fixture-key", model: "fixture-model",
                                      chatTemplateKwargs: nil, streaming: input.scenario != "nonstream")
        let client = NativeChatClient(config: config, admission: input.scenario == "uncoordinated" ? nil : admission)
        let started = ContinuousClock.now
        var frames: [String] = []
        var firstContentSeconds: Double?
        var outcome = "completed"
        var returnedSeconds = 0.0
        var fingerprints: [String: String] = [:]
        do {
            if input.scenario == "cancel-before-start" {
                let canceled = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    do {
                        _ = try await NativeInferenceDeadline.run(seconds: 1, onNotStarted: {
                            measurements.record("not_started_cleanup", 1)
                        }) {
                            measurements.record("unexpected_operation", 1)
                            return "unexpected"
                        }
                    } catch { measurements.record("cancellation_observed", 1) }
                }
                await canceled.value
                let limit = ContinuousClock.now.advanced(by: .seconds(1))
                while measurements.snapshot()["not_started_cleanup"] == nil && ContinuousClock.now < limit {
                    try await Task.sleep(for: .milliseconds(2))
                }
                outcome = "canceled"
            } else if input.scenario == "resources" {
                for raw in input.resource_urls ?? [] {
                    if let url = URL(string: raw) { fingerprints[raw] = try NativeInferenceAdmission.resource(for: url) }
                }
            } else if input.scenario == "resistant" {
                do {
                    _ = try await admission.perform(endpoint: endpoint, priority: .foreground, requestedSeconds: 2) { _ in
                        let end = ContinuousClock.now.advanced(by: .milliseconds(450))
                        while ContinuousClock.now < end { await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value }
                        return "late"
                    }
                } catch { outcome = "failed" }
                let returned = started.duration(to: .now)
                returnedSeconds = Double(returned.components.seconds) + Double(returned.components.attoseconds) / 1e18
                _ = try? await URLSession.shared.data(from: base.appendingPathComponent("fixture/released"))
            } else if input.scenario.hasPrefix("memory") || input.scenario == "embedding" {
                let memory = NativeMemoryService(configuration: NativeMemoryServiceConfiguration(
                    baseURL: endpoint, apiKey: "synthetic-fixture-key", embeddingsModel: "fixture-embedding", extractionModel: "fixture-model"), admission: admission)
                if input.scenario == "memory-background" {
                    _ = try await memory.proposals(user: "I like morning walks", assistant: "Understood", sourceConversationID: nil, sourceMessageID: nil, existing: [])
                } else if input.scenario == "memory-foreground" {
                    _ = try await memory.proposal(request: "Remember morning walks", existing: [])
                } else {
                    _ = try await memory.embed("morning walks")
                }
            } else if input.scenario == "cancel" {
                let request = Task {
                    for try await _ in client.stream(messages: [NativeChatMessage(role: "user", content: "native-fixture")], model: config.model, tools: []) {}
                }
                try await Task.sleep(for: .milliseconds(100))
                request.cancel()
                _ = try? await request.value
                outcome = "canceled"
                _ = try? await URLSession.shared.data(from: base.appendingPathComponent("fixture/released"))
            } else {
                for try await snapshot in client.stream(messages: [NativeChatMessage(role: "user", content: "native-fixture")], model: config.model, tools: []) {
                    if firstContentSeconds == nil && !snapshot.content.isEmpty {
                        let first = started.duration(to: .now)
                        firstContentSeconds = Double(first.components.seconds) + Double(first.components.attoseconds) / 1e18
                    }
                    frames.append(snapshot.content)
                }
            }
        } catch {
            outcome = "failed"
        }
        if input.scenario == "cancel-after-grant" {
            outcome = "canceled"
            _ = try? await URLSession.shared.data(from: base.appendingPathComponent("fixture/released"))
        }
        let elapsed = started.duration(to: .now)
        let result: [String: Any] = [
            "outcome": outcome, "frames": frames,
            "elapsed_seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            "resource": try NativeInferenceAdmission.resource(for: endpoint),
            "returned_seconds": returnedSeconds, "resource_vectors": fingerprints,
            "measurements": measurements.snapshot(), "first_content_seconds": firstContentSeconds ?? NSNull(),
        ]
        print("ADMISSION_FIXTURE " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }
}
