import Foundation

// Small readers over the daemon's loose JSON; unknown fields and unknown
// message types read as nil and get ignored, so daemon evolution never
// crashes the phone.
public func str(_ object: [String: Any], _ key: String) -> String? {
    object[key] as? String
}

public func int(_ object: [String: Any], _ key: String) -> Int? {
    (object[key] as? NSNumber)?.intValue
}

public func bool(_ object: [String: Any], _ key: String) -> Bool? {
    (object[key] as? NSNumber)?.boolValue
}

public func obj(_ object: [String: Any], _ key: String) -> [String: Any]? {
    object[key] as? [String: Any]
}

public func arr(_ object: [String: Any], _ key: String) -> [Any]? {
    object[key] as? [Any]
}

// Null fields are omitted, never sent as JSON null: the daemon treats an
// absent conversation id and a null one differently in no lane we use, but
// the Android client omits, so this one does too.
public func msg(_ type: String, _ fields: [String: Any?] = [:]) -> [String: Any] {
    var out: [String: Any] = ["type": type]
    for (key, value) in fields {
        if let value { out[key] = value }
    }
    return out
}

public func encodeJSON(_ object: [String: Any]) -> String? {
    (try? JSONSerialization.data(withJSONObject: object))
        .flatMap { String(data: $0, encoding: .utf8) }
}

public func decodeJSON(_ text: String) -> [String: Any]? {
    text.data(using: .utf8)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
}

public struct FileRef: Identifiable, Equatable {
    public let id: String?
    public let name: String
    public let bytes: Int64?

    public init(id: String?, name: String, bytes: Int64?) {
        self.id = id
        self.name = name
        self.bytes = bytes
    }
}

public func artifactFiles(_ artifacts: [String: Any]?) -> [FileRef] {
    guard let artifacts, let files = arr(artifacts, "files") else { return [] }
    return files.compactMap { element in
        guard let row = element as? [String: Any] else { return nil }
        let name = str(row, "name")
            ?? str(row, "path").flatMap { $0.components(separatedBy: "/").last }
        guard let name else { return nil }
        return FileRef(id: str(row, "id"), name: name,
                       bytes: (row["bytes"] as? NSNumber)?.int64Value)
    }
}
