import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessError: Error, CustomStringConvertible {
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .executableNotFound(let path): return "Executable not found: \(path)"
        case .launchFailed(let detail): return "Could not launch process: \(detail)"
        case .timedOut(let path): return "Timed out waiting for \(path)"
        }
    }
}

/// Runs command-line tools and collects their output.
///
/// stdout and stderr are captured separately and read concurrently — several of the
/// tools this app drives (`mas` in particular) write warnings to stderr while emitting
/// their real output on stdout, and a single combined pipe both corrupts the payload
/// and can deadlock once a pipe buffer fills.
public struct ProcessRunner: Sendable {
    public init() {}

    public func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // mas kicks off Spotlight indexing as a side effect unless told not to.
        env["MAS_NO_AUTO_INDEX"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        if let environment { env.merge(environment) { _, new in new } }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so neither can block the child.
        async let outData = Self.readToEnd(outPipe.fileHandleForReading)
        async let errData = Self.readToEnd(errPipe.fileHandleForReading)

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        let (out, err) = await (outData, errData)
        process.waitUntilExit()
        watchdog.cancel()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: out, as: UTF8.self),
            standardError: String(decoding: err, as: UTF8.self)
        )
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// First existing path among `candidates`, for tools that live in different
    /// prefixes on Apple silicon (`/opt/homebrew`) and Intel (`/usr/local`).
    public static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var homebrewPath: String? {
        locate(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    }

    public static var masPath: String? {
        locate(["/opt/homebrew/bin/mas", "/usr/local/bin/mas"])
    }
}

extension ProcessRunner {
    /// Runs a tool, delivering output line by line as it arrives so the UI can show
    /// progress during a long `brew upgrade` instead of freezing until it finishes.
    public func stream(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 1800,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["MAS_NO_AUTO_INDEX"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Nothing can answer an interactive prompt, so refuse input rather than hang.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        onOutput(String(decoding: line, as: UTF8.self))
                    }
                }
                if !buffer.isEmpty { onOutput(String(decoding: buffer, as: UTF8.self)) }
                continuation.resume()
            }
        }

        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationStatus
    }
}
