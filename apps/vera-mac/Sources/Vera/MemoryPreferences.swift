import Foundation

final class MemoryPreferences: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    private func stored(_ key: String) -> Any? {
        lock.withLock { values[key] ?? registered[key] }
    }

    private func store(_ value: Any?, _ key: String) {
        willChangeValue(forKey: key)
        lock.withLock { values[key] = value }
        didChangeValue(forKey: key)
    }

    override func object(forKey defaultName: String) -> Any? { stored(defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) { store(value, defaultName) }
    override func removeObject(forKey defaultName: String) { store(nil, defaultName) }
    override func string(forKey defaultName: String) -> String? {
        let value = stored(defaultName)
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    override func array(forKey defaultName: String) -> [Any]? { stored(defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { stored(defaultName) as? [String: Any] }
    override func data(forKey defaultName: String) -> Data? { stored(defaultName) as? Data }
    override func stringArray(forKey defaultName: String) -> [String]? { stored(defaultName) as? [String] }
    override func integer(forKey defaultName: String) -> Int { number(defaultName)?.intValue ?? 0 }
    override func float(forKey defaultName: String) -> Float { number(defaultName)?.floatValue ?? 0 }
    override func double(forKey defaultName: String) -> Double { number(defaultName)?.doubleValue ?? 0 }
    override func bool(forKey defaultName: String) -> Bool { number(defaultName)?.boolValue ?? false }
    override func url(forKey defaultName: String) -> URL? {
        let value = stored(defaultName)
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }
        return nil
    }
    override func set(_ value: Int, forKey defaultName: String) { store(NSNumber(value: value), defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { store(NSNumber(value: value), defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { store(NSNumber(value: value), defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { store(NSNumber(value: value), defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { store(url, defaultName) }
    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock { registered.merge(registrationDictionary) { $1 } }
    }
    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { registered.merging(values) { $1 } }
    }
    override func persistentDomain(forName domainName: String) -> [String: Any]? { lock.withLock { values } }
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { lock.withLock { values = domain } }
    override func removePersistentDomain(forName domainName: String) { lock.withLock { values = [:] } }
    override func synchronize() -> Bool { true }

    private func number(_ key: String) -> NSNumber? {
        let value = stored(key)
        if let number = value as? NSNumber { return number }
        if let text = value as? String { return Double(text).map { NSNumber(value: $0) } ?? NSNumber(value: ["yes", "true"].contains(text.lowercased())) }
        return nil
    }
}
