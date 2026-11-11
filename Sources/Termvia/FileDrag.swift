import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TermviaCore

struct FileDragPayload: Codable, Sendable {
    var version = 1
    var localPaths: [String] = []
    var sessionID: UUID?
    var entries: [RemoteEntry] = []
    static let type = "app.termvia.file-items"
    static let contentTypes: [UTType] = [UTType(exportedAs: type), .fileURL]
    func provider() -> NSItemProvider {
        let provider = localPaths.first.map { NSItemProvider(object: URL(fileURLWithPath: $0) as NSURL) } ?? NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.type, visibility: .all) { complete in complete(data, nil); return nil }
        return provider
    }
    @MainActor static func receive(_ providers: [NSItemProvider], action: @escaping @MainActor @Sendable (Self) -> Void) -> Bool {
        let custom = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        if !custom.isEmpty {
            guard custom.count <= 1000 else { return false }
            let collector = DropPayloads(), group = DispatchGroup()
            for (index, provider) in custom.enumerated() {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    defer { group.leave() }
                    guard let data, data.count <= 1048576, let payload = try? JSONDecoder().decode(Self.self, from: data), payload.version == 1, payload.localPaths.count + payload.entries.count <= 1000,
                          payload.localPaths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }), payload.entries.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else { return }
                    collector.add(payload, at: index)
                }
            }
            group.notify(queue: .global()) {
                guard let payload = collector.merged(expected: custom.count) else { return }
                RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { action(payload) } }
            }
            return true
        }
        let urls = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !urls.isEmpty, urls.count <= 1000 else { return false }
        let collector = DropURLs(), group = DispatchGroup()
        for (index, provider) in urls.enumerated() {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                collector.add(url.path, at: index)
            }
        }
        group.notify(queue: .global()) {
            let payload = Self(localPaths: collector.paths)
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { action(payload) } }
        }
        return true
    }
    private final class DropPayloads: @unchecked Sendable {
        private let lock = NSLock(); private var values: [Int: FileDragPayload] = [:]
        func add(_ payload: FileDragPayload, at index: Int) { lock.lock(); values[index] = payload; lock.unlock() }
        func merged(expected: Int) -> FileDragPayload? {
            lock.lock(); defer { lock.unlock() }
            let ordered = values.sorted { $0.key < $1.key }.map(\.value)
            guard ordered.count == expected, let first = ordered.first,
                  ordered.allSatisfy({ $0.sessionID == first.sessionID && ($0.localPaths.isEmpty == first.localPaths.isEmpty) }) else { return nil }
            var result = FileDragPayload(sessionID: first.sessionID), local = Set<String>(), remote = Set<String>()
            for payload in ordered {
                result.localPaths += payload.localPaths.filter { local.insert($0).inserted }
                result.entries += payload.entries.filter { remote.insert($0.id).inserted }
            }
            guard !result.localPaths.isEmpty || !result.entries.isEmpty, result.localPaths.count + result.entries.count <= 1000 else { return nil }
            return result
        }
    }
    private final class DropURLs: @unchecked Sendable {
        private let lock = NSLock(); private var values: [Int: String] = [:]
        func add(_ path: String, at index: Int) { lock.lock(); values[index] = path; lock.unlock() }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return values.sorted { $0.key < $1.key }.map(\.value) }
    }
}

/// Leave permanent unstriped space for directory actions, including when a
/// table is full or an existing row remains selected.
