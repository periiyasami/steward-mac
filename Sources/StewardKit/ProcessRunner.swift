import Foundation

/// Runs a command and collects its output. Reads standard output and standard
/// error at the same time, so a command that writes a lot to either never
/// blocks on a full pipe.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let error: String
    }

    public static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Standard error on another thread while this one reads standard output.
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      output: String(data: outData, encoding: .utf8) ?? "",
                      error: String(data: box.get(), encoding: .utf8) ?? "")
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.withLock { data = d } }
        func get() -> Data { lock.withLock { data } }
    }
}
