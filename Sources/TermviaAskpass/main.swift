import Foundation
import TermviaCore

// Only stdout is the OpenSSH reply pipe. Errors deliberately carry no details.
do {
    let arguments = CommandLine.arguments
    if arguments.count == 5, arguments[1] == "--scoped-known-hosts" {
        guard let path = Data(base64Encoded: arguments[2]).flatMap({ String(data: $0, encoding: .utf8) }),
              let address = Data(base64Encoded: arguments[3]).flatMap({ String(data: $0, encoding: .utf8) }),
              let port = Int(arguments[4]), path.hasPrefix("/") else { exit(1) }
        let host = SSHHost(name: address, address: address, user: "known-hosts", port: port)
        let store = KnownHostsStore(url: URL(fileURLWithPath: path))
        guard let view = try store.scopedCertificateView(for: host) else { exit(1) }
        FileHandle.standardOutput.write(Data(view.records.utf8))
        exit(0)
    }
    guard let prompt = CommandLine.arguments.dropFirst().first,
          let value = try AskpassClient.response(prompt: prompt) else { exit(1) }
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
} catch { exit(1) }
