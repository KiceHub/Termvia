import Foundation

/// SCP has no directory protocol. Use a separate SSH exec channel in SCP mode,
/// with NUL-delimited records rather than parsing human-readable ls output.
public final class SSHFileClient: Sendable {
    public init() {}

    public static func invocation(_ host: SSHHost, commands: SSHCommands, operation: SFTPOperation) throws -> Invocation {
        try commands.execute(host, command: command(operation))
    }

    public static func command(_ operation: SFTPOperation) throws -> String {
        func quote(_ value: String) throws -> String {
            guard !value.contains("\0") else { throw SSHError.invalid("路径包含不支持的控制字符") }
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        func absolute(_ path: String) throws -> String {
            guard path.hasPrefix("/") else { throw SSHError.invalid("本地和远程路径必须是绝对路径") }
            return try quote(path)
        }
        func script(_ operation: SFTPOperation) throws -> String {
            switch operation {
            case .batch(let operations): return try operations.map(script).joined(separator: "\n")
            case .makeDirectory(let path): return "mkdir \(try absolute(path)) || exit 1"
            case .makeFile(let path): return "(umask 077; set -C; : > \(try absolute(path))) || exit 1"
            case .copyFile(let source, let target):
                let temporary = try FilePaths.child(".termvia-copy-" + UUID().uuidString, in: (target as NSString).deletingLastPathComponent)
                let source = try absolute(source), target = try absolute(target), temporaryQuoted = try absolute(temporary)
                let cleanup = try quote("rm -f " + temporaryQuoted)
                return "[ -f \(source) ] && [ ! -L \(source) ] || exit 1\n(umask 077; set -C; exec 3> \(temporaryQuoted); trap \(cleanup) EXIT HUP INT TERM; cat \(source) >&3 || exit 1; exec 3>&-; ln \(temporaryQuoted) \(target)) || exit 1"
            case .removeFile(let path): return "rm \(try absolute(path)) || exit 1"
            case .removeTree(let path):
                try FilePaths.validateDeletion(path)
                return "rm -rf \(try absolute(path)) || exit 1"
            case .removeDirectory(let path): return "rmdir \(try absolute(path)) || exit 1"
            case .rename(let source, let target):
                // An exclusive hard link avoids mv's directory-target race.
                // Cross-filesystem or directory moves fail without deleting source.
                let source = try absolute(source), target = try absolute(target)
                return "[ -f \(source) ] && [ ! -L \(source) ] || exit 1\nln \(source) \(target) && rm \(source) || exit 1"
            case .list(let path):
                let directory: String
                if path == "~" || path == "~/" { directory = "\"$HOME\"" }
                else if path.hasPrefix("~/") { directory = "\"$HOME\"/" + (try quote(String(path.dropFirst(2)))) }
                else { directory = try quote(path.hasPrefix("/") ? path : "./" + path) }
                return "cd \(directory) || exit 1\n" + listing
            }
        }
        let body = "# termvia-files-v1\nset -f\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\nexport PATH\n" + (try script(operation))
        return "LC_ALL=C sh -c " + (try quote(body))
    }

    private static let listing = #"""
    case "$(uname -s)" in
      Darwin) platform=Darwin ;;
      Linux) platform=Linux ;;
      *) echo 'Unsupported remote file platform' >&2; exit 1 ;;
    esac
    # Preserve trailing newlines in a directory name through command substitution.
    directory=$(pwd -P && printf '.') || exit 1
    directory=${directory%.}
    directory=${directory%?}
    [ -r . ] && [ -x . ] || { echo 'Remote directory is not readable' >&2; exit 1; }
    printf 'termvia-files-v1\000%s\000' "$directory"
    set +f
    count=0
    for entry in ./* ./.[!.]* ./..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      count=$((count + 1))
      [ "$count" -le 100000 ] || exit 1
      if [ -L "$entry" ]; then kind=symbolicLink
      elif [ -d "$entry" ]; then kind=directory
      elif [ -f "$entry" ]; then kind=file
      else kind=other; fi
      if [ "$platform" = Darwin ]; then
        metadata=$(stat -f '%z %m' "$entry" 2>/dev/null) || metadata='- -'
      else
        metadata=$(stat -c '%s %Y' -- "$entry" 2>/dev/null) || metadata='- -'
      fi
      printf '%s\000%s\000%s\000' "${entry#./}" "$kind" "$metadata"
    done
    printf 'termvia-files-end\000'
    """#

    public func perform(_ invocation: Invocation) async throws -> RemoteDirectory {
        let runner = ProcessRunner(), capture = Capture()
        let timeout = DispatchWorkItem { [weak capture, weak runner] in capture?.expire(); runner?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }
        let result: CommandResult
        do {
            result = try await runner.run(invocation) { bytes in
                if !capture.append(bytes) { runner.cancel() }
            }
        } catch {
            try Task.checkCancellation()
            if capture.expired { throw SSHError.invalid("文件操作超时，请重试") }
            if capture.overflow { throw SSHError.invalid("目录条目过多，请缩小目录范围") }
            throw error
        }
        try Task.checkCancellation()
        guard result.status == 0 else { throw SSHError.failed(result.status, result.output) }
        return try decode(capture.data)
    }

    public func decode(_ data: Data) throws -> RemoteDirectory {
        func malformed() -> SSHError { .invalid("SSH 目录返回了无效数据") }
        // SSH banners may precede the frame. A truncated/contaminated frame
        // never becomes a partial directory that could target the wrong file.
        let marker = Data("termvia-files-v1\0".utf8)
        guard data.count <= Capture.limit, let start = data.range(of: marker), data.last == 0 else { throw malformed() }
        let fields = data[start.upperBound...].split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 3, fields.last?.isEmpty == true,
              fields[fields.count - 2] == Data("termvia-files-end".utf8),
              (fields.count - 3).isMultiple(of: 3), (fields.count - 3) / 3 <= 100000,
              let path = String(data: fields[0], encoding: .utf8), path.hasPrefix("/") else { throw malformed() }
        var entries: [RemoteEntry] = [], names = Set<Data>()
        for index in stride(from: 1, to: fields.count - 2, by: 3) {
            guard let name = String(data: fields[index], encoding: .utf8),
                  names.insert(Data(fields[index])).inserted,
                  let kindText = String(data: fields[index + 1], encoding: .utf8), let kind = RemoteFileKind(rawValue: kindText),
                  let metadata = String(data: fields[index + 2], encoding: .utf8) else { throw malformed() }
            let parts = metadata.split(separator: " ")
            guard parts.count == 2 else { throw malformed() }
            let size = UInt64(parts[0]), seconds = TimeInterval(parts[1])
            guard (size != nil || parts[0] == "-"), (seconds?.isFinite == true || parts[1] == "-") else { throw malformed() }
            entries.append(RemoteEntry(name: name, path: try FilePaths.child(name, in: path), kind: kind, size: size, modified: seconds.map { Date(timeIntervalSince1970: $0) }))
        }
        return RemoteDirectory(path: path, entries: entries)
    }

    private final class Capture: @unchecked Sendable {
        static let limit = 16 * 1024 * 1024
        private let lock = NSLock()
        private var bytes = Data(), didExpire = false, didOverflow = false
        func append(_ data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard bytes.count + data.count <= Self.limit else { didOverflow = true; return false }
            bytes.append(data); return true
        }
        func expire() { lock.lock(); didExpire = true; lock.unlock() }
        var expired: Bool { lock.lock(); defer { lock.unlock() }; return didExpire }
        var overflow: Bool { lock.lock(); defer { lock.unlock() }; return didOverflow }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
}
