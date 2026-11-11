import Foundation
import TermviaCore

// Only stdout is the OpenSSH reply pipe. Errors deliberately carry no details.
do {
    guard let prompt = CommandLine.arguments.dropFirst().first,
          let value = try AskpassClient.response(prompt: prompt) else { exit(1) }
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
} catch { exit(1) }
