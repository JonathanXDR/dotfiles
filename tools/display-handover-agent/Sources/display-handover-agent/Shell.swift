import Foundation

struct CommandResult: Sendable {
    var status: Int32
    var output: String
}

enum Shell {
    /// Returns `nil` when the program could not start or ran past the timeout, and terminates a program
    /// that ran past it. Discards standard error.
    static func run(_ executable: String, _ arguments: [String], input: String? = nil, timeout: Double = 10) async -> CommandResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                let stdin = Pipe()
                process.standardInput = input == nil ? FileHandle.nullDevice : stdin
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                if let input {
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                guard finished.wait(timeout: .now() + timeout) == .success else {
                    process.terminate()
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: CommandResult(status: process.terminationStatus, output: text))
            }
        }
    }
}
