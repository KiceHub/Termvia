import Foundation
import Darwin

/// A bounded header read is sufficient for preflight; downloaded bytes are checked again.
public struct EditorFileInspection: Sendable {
    public static let headerLimit = 16 * 1024
    public static let smallFileLimit: UInt64 = 1024 * 1024
    public static let editorLimit: UInt64 = 16 * 1024 * 1024
    public let size: UInt64?
    public let header: Data
    public init(size: UInt64?, header: Data) { self.size = size; self.header = Data(header.prefix(Self.headerLimit)) }
    public var needsSizeConfirmation: Bool { size.map { $0 > Self.smallFileLimit } ?? true }
    public var exceedsEditorLimit: Bool { size.map { $0 > Self.editorLimit } ?? false }
    public var encoding: EditorEncoding {
        if header.starts(with: [0xff, 0xfe]) { return .utf16LE }
        if header.starts(with: [0xfe, 0xff]) { return .utf16BE }
        return .utf8
    }
    public static func local(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return Self(size: values.fileSize.map { UInt64(max(0, $0)) }, header: try handle.read(upToCount: headerLimit) ?? Data())
    }
    /// Use macOS's file-signature database, never the filename extension.
    public func isText() throws -> Bool {
        if header.isEmpty { return size == 0 }
        let signatures: [[UInt8]] = [
            [0x7f,0x45,0x4c,0x46], [0x89,0x50,0x4e,0x47], [0xff,0xd8,0xff],
            [0x50,0x4b,3,4], [0x50,0x4b,5,6], [0x50,0x4b,7,8], [0x1f,0x8b],
            [0x37,0x7a,0xbc,0xaf,0x27,0x1c], [0x52,0x61,0x72,0x21,0x1a,7], [0xfd,0x37,0x7a,0x58,0x5a,0],
            [0x28,0xb5,0x2f,0xfd], [0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1],
            [0xfe,0xed,0xfa,0xce], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xcf,0xfa,0xed,0xfe],
            [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca], [0,0x61,0x73,0x6d]
        ]
        if signatures.contains(where: { header.starts(with: $0) }) { return false }
        for magic in ["%PDF-", "GIF87a", "GIF89a", "SQLite format 3", "bplist00", "fLaC"] {
            if header.starts(with: magic.utf8) { return false }
        }
        if encoding == .utf8, header.contains(0) { return false }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = ["--brief", "--mime-type", "-"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let deadline = DispatchWorkItem { [weak process] in if let process, process.isRunning { ChildProcess.stop(process) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel() }
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit(); try? output.fileHandleForReading.close() }
        do { try input.fileHandleForWriting.write(contentsOf: header); try input.fileHandleForWriting.close() }
        catch { try? input.fileHandleForWriting.close(); throw error }
        let mime = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SSHError.invalid("无法检查文件格式") }
        let textual: Set<String> = ["application/json", "application/xml", "application/javascript", "application/x-javascript", "application/x-shellscript", "application/x-empty", "inode/x-empty", "application/toml", "application/yaml", "application/x-yaml", "application/x-ndjson", "image/svg+xml"]
        return mime.hasPrefix("text/") || textual.contains(mime)
    }
    /// Legacy SCP browsing already requires a POSIX SSH exec channel.
    public static func sshCommand(path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw SSHError.invalid("本地和远程路径必须是绝对路径") }
        let script = """
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        p=\(SSHRoute.shellQuote(path))
        [ -f "$p" ] && [ ! -L "$p" ] || exit 1
        case "$(uname -s)" in
          Darwin) n=$(stat -f '%z' "$p") || exit 1 ;;
          Linux) n=$(stat -c '%s' -- "$p") || exit 1 ;;
          *) exit 1 ;;
        esac
        printf 'termvia-editor-header-v1 %s\\n' "$n"
        head -c \(headerLimit) < "$p" | base64
        printf '\\ntermvia-editor-header-end\\n'
        """
        return "LC_ALL=C sh -c " + SSHRoute.shellQuote(script)
    }
    public static func decodeSSH(_ output: String) throws -> Self {
        let start = "termvia-editor-header-v1 ", end = "\ntermvia-editor-header-end"
        guard let marker = output.range(of: start), let finish = output.range(of: end, range: marker.upperBound..<output.endIndex) else { throw SSHError.invalid("无法检查文件格式") }
        let payload = output[marker.upperBound..<finish.lowerBound].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard payload.count == 2, let size = UInt64(payload[0]),
              let bytes = Data(base64Encoded: payload[1].filter { !$0.isWhitespace }), bytes.count == min(size, UInt64(headerLimit)) else { throw SSHError.invalid("无法检查文件格式") }
        return Self(size: size, header: bytes)
    }
}
