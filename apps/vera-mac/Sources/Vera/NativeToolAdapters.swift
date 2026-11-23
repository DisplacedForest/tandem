import Foundation

enum NativeToolTransport: Equatable, Sendable {
    case chat
    case handedOffWork
}

enum NativeToolAdapter {
    static func schema(_ definition: NativeToolDefinition) -> NativeToolSchema {
        NativeToolSchema(name: definition.name, description: definition.description, parameters: definition.parameters)
    }

    static func unsupported(_ definition: NativeToolDefinition, for transport: NativeToolTransport) -> NativeToolIssue.Reason? {
        switch transport {
        case .chat:
            return nil
        case .handedOffWork:
            guard NativeTaskGenerationJob.carriesToolName(definition.name) else { return .invalidName }
            return nil
        }
    }

    static func carried(_ definitions: [NativeToolDefinition],
                        for transport: NativeToolTransport) -> (definitions: [NativeToolDefinition], withheld: [NativeToolIssue]) {
        var kept: [NativeToolDefinition] = []
        var withheld: [NativeToolIssue] = []
        var names = Set<String>()
        for definition in definitions {
            guard names.insert(definition.name).inserted else {
                withheld.append(NativeToolIssue(name: definition.name, reason: .duplicateName))
                continue
            }
            if let reason = unsupported(definition, for: transport) {
                withheld.append(NativeToolIssue(name: definition.name, reason: reason))
                continue
            }
            kept.append(definition)
        }
        return (kept, withheld)
    }

    static func offered(_ definitions: [NativeToolDefinition],
                        for transport: NativeToolTransport) -> (schemas: [NativeToolSchema], withheld: [NativeToolIssue]) {
        let result = carried(definitions, for: transport)
        return (result.definitions.map(schema), result.withheld)
    }
}
