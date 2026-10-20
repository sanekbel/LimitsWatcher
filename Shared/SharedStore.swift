import Foundation

/// The menu bar app (not sandboxed) writes `snapshot.json` into the App Group container,
/// the widget extension (sandboxed) reads it from there.
/// The group id comes from Info.plist (`AppGroupID`), which is filled in from the build settings,
/// so the Team ID prefix is always correct.
enum SharedStore {
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    static var fileURL: URL? {
        guard let id = groupID,
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        else { return nil }
        return base.appendingPathComponent("snapshot.json")
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func write(_ snapshot: UsageSnapshot) throws {
        guard let url = fileURL else { return }
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    static func read() -> UsageSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }
}
