import Foundation

public enum LocalFileOperations {
    public static func relocate(_ sources: [URL], into directory: URL, copy: Bool) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let plans = try sources.compactMap { source -> (URL, URL)? in
            let source = source.standardizedFileURL
            let target = directory.appendingPathComponent(source.lastPathComponent)
            _ = try FilePaths.child(source.lastPathComponent, in: directory.path)
            let physicalSource = source.resolvingSymlinksInPath().path
            guard target.path != source.path, directory.path != physicalSource, !directory.path.hasPrefix(physicalSource + "/") else { return nil }
            guard !FileManager.default.fileExists(atPath: target.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else { throw SSHError.invalid(T("文件已存在：%@", target.lastPathComponent)) }
            return (source, target)
        }
        for (source, target) in plans {
            if copy { try FileManager.default.copyItem(at: source, to: target) }
            else { try FileManager.default.moveItem(at: source, to: target) }
        }
    }
}

extension FilePaths {
    private static func normalizeRemotePath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return (path.hasPrefix("/") ? "/" : "") + components.joined(separator: "/")
    }
    public static func validateDeletion(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", normalizeRemotePath(path) == path,
              !path.contains("\0") else { throw SSHError.invalid("无效的删除路径") }
    }
    public static func isSelfDestination(source: String, target: String) -> Bool {
        let source = normalizeRemotePath(source)
        let target = normalizeRemotePath(target)
        return target == source || target.hasPrefix(source + "/")
    }
}
