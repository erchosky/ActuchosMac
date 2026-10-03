import Foundation

struct Command: Sendable {
    let executable: String
    let arguments: [String]
    var environment: [String: String] = [:]
    var timeout: TimeInterval = 120

    var redactedDescription: String {
        ([executable] + arguments).map { argument in
            let lowered = argument.lowercased()
            if lowered.contains("token") || lowered.contains("password") || lowered.contains("secret") {
                return "<redacted>"
            }
            return argument.contains(" ") ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
    }
}

struct ProcessResult: Sendable {
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let duration: TimeInterval
    let timedOut: Bool

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

protocol ProcessRunning: Sendable {
    func run(_ command: Command) async -> ProcessResult
}

/// Runs external tools without a shell, with stdin closed, a hard timeout and cooperative cancellation.
///
/// Blocking work (waiting for the child and draining its pipes) happens on GCD threads, never on the
/// Swift concurrency pool, so dozens of concurrent commands cannot starve the app or deadlock on full pipes.
final class ProcessRunner: ProcessRunning {
    func run(_ command: Command) async -> ProcessResult {
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Self.execute(command, handle: handle))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func execute(_ command: Command, handle: ProcessHandle) -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environment(for: command)
        let started = Date()

        guard handle.attach(process) else {
            return failure(command, message: "Cancelado antes de iniciar", started: started)
        }
        do {
            try process.run()
        } catch {
            return failure(command, message: error.localizedDescription, started: started)
        }
        if handle.wasCancelled { process.terminate() }

        let readers = DispatchGroup()
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        for (pipe, buffer) in [(stdoutPipe, stdoutBuffer), (stderrPipe, stderrBuffer)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }

        let timeout = DispatchWorkItem { handle.timeOut() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + command.timeout, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        readers.wait()

        var stderr = String(decoding: stderrBuffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.didTimeOut {
            stderr = [stderr, "Tiempo de espera agotado tras \(Int(command.timeout)) s"].filter { !$0.isEmpty }.joined(separator: "\n")
        } else if handle.wasCancelled {
            stderr = [stderr, "Cancelado por el usuario"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ProcessResult(
            command: command.redactedDescription,
            stdout: String(decoding: stdoutBuffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr,
            exitCode: process.terminationStatus,
            duration: Date().timeIntervalSince(started),
            timedOut: handle.didTimeOut
        )
    }

    /// Apps launched from Finder inherit a minimal PATH. Tools such as npm (`#!/usr/bin/env node`) need
    /// their own directory and the usual package-manager prefixes to resolve their interpreter.
    private static func environment(for command: Command) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let executableDirectory = URL(fileURLWithPath: command.executable).deletingLastPathComponent().path
        var seen = Set<String>()
        environment["PATH"] = ([executableDirectory] + HostEnvironment.standardBinaryDirectories + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        return environment.merging(command.environment) { _, new in new }
    }

    private static func failure(_ command: Command, message: String, started: Date) -> ProcessResult {
        ProcessResult(command: command.redactedDescription, stdout: "", stderr: message, exitCode: -1,
                      duration: Date().timeIntervalSince(started), timedOut: false)
    }
}

/// Written by exactly one reader before `DispatchGroup.leave()`, read only after `wait()`.
private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
}

/// Thread-safe link between a running `Process` and the timeout/cancellation paths.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    var wasCancelled: Bool { lock.withLock { cancelled } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    /// Returns `false` when cancellation already happened, so the process is never started.
    func attach(_ process: Process) -> Bool {
        lock.withLock {
            self.process = process
            return !cancelled
        }
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            return self.process
        }
        Self.stop(process)
    }

    func timeOut() {
        let process = lock.withLock { () -> Process? in
            timedOut = true
            return self.process
        }
        Self.stop(process)
    }

    private static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
