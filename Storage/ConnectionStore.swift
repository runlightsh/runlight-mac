import Foundation

/// A connected Runlight install. Its token is in the vault, never here.
struct Connection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// What the list calls it: the install's host, like analytics.joncp.dev.
    var name: String
    /// Where the API is mounted, without `/api`.
    var baseURL: URL
    /// The Runlight version it last reported, shown in Settings.
    var version: String
    var addedAt: Date
}

/// Keeps connection details and the last good responses as JSON in Application Support, so the
/// popover opens instantly with yesterday's numbers while fresh ones load. Holds no tokens.
struct ConnectionStore: Sendable {
    let directory: URL

    /// `~/Library/Containers/sh.runlight.mac/Data/Library/Application Support/Runlight` in the sandbox.
    static var standard: ConnectionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ConnectionStore(directory: support.appending(path: "Runlight", directoryHint: .isDirectory))
    }

    private var connectionsFile: URL { directory.appending(path: "connections.json") }
    private var cacheDirectory: URL { directory.appending(path: "Cache", directoryHint: .isDirectory) }

    func loadConnections() -> [Connection] {
        read([Connection].self, from: connectionsFile) ?? []
    }

    func saveConnections(_ connections: [Connection]) throws {
        try write(connections, to: connectionsFile)
    }

    /// The last good copy of a response, by a key like `<connection>/sites`.
    func cached<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        read(type, from: cacheFile(key))
    }

    func cache<T: Encodable>(_ value: T, _ key: String) {
        try? write(value, to: cacheFile(key))
    }

    /// Forgets everything cached for one connection.
    func removeCache(for connection: UUID) {
        try? FileManager.default.removeItem(at: cacheDirectory.appending(path: connection.uuidString, directoryHint: .isDirectory))
    }

    private func cacheFile(_ key: String) -> URL {
        let safe = key.split(separator: "/").map { $0.replacingOccurrences(of: "..", with: "_") }.joined(separator: "/")
        return cacheDirectory.appending(path: "\(safe).json")
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: [.atomic])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
