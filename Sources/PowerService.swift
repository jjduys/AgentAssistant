import Foundation

struct CommandOutput: Sendable {
    let status: Int32
    let text: String
}

protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) throws -> CommandOutput
}

struct SystemCommandRunner: CommandRunning {
    func run(_ executable: String, arguments: [String]) throws -> CommandOutput {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Drain both streams together, so an error cannot fill an unread pipe.
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandOutput(status: process.terminationStatus,
                             text: String(decoding: data, as: UTF8.self))
    }
}

enum PowerError: Error, LocalizedError, Equatable {
    case unreadableState
    case commandFailed(String)
    case cancelled
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .unreadableState:
            return "无法从系统读取 SleepDisabled 状态。请右键选择“刷新状态”重试。"
        case .commandFailed(let detail):
            return "系统命令执行失败：\n\(detail)"
        case .cancelled:
            return "已取消管理员授权。"
        case .verificationFailed:
            return "命令已执行，但系统状态与请求不一致。请刷新状态后重试。"
        }
    }
}

protocol PowerManaging: Sendable {
    func readEnabled() throws -> Bool
    /// Must verify the actual system state before returning successfully.
    func setEnabled(_ enabled: Bool) throws
}

struct PmsetService: PowerManaging {
    let runner: any CommandRunning

    init(runner: any CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    static func parseEnabled(_ output: String) throws -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            // Exact key and value only: do not confuse the sleep timer with this switch.
            if fields.count == 2, fields[0] == "SleepDisabled" {
                switch fields[1] {
                case "1": return true
                case "0": return false
                default: throw PowerError.unreadableState
                }
            }
        }
        throw PowerError.unreadableState
    }

    static func authorizationScript(enabled: Bool) -> String {
        // All commands are fixed; no user input or password is interpolated.
        let value = enabled ? "1" : "0"
        return """
        do shell script "/usr/bin/pmset -a disablesleep \(value)" with prompt "AgentAssistant 需要管理员权限来修改永不睡眠设置。" with administrator privileges
        """
    }

    func readEnabled() throws -> Bool {
        let result = try runner.run("/usr/bin/pmset", arguments: ["-g"])
        guard result.status == 0 else {
            throw PowerError.commandFailed(Self.trim(result.text))
        }
        return try Self.parseEnabled(result.text)
    }

    func setEnabled(_ enabled: Bool) throws {
        let result = try runner.run("/usr/bin/osascript", arguments: [
            "-e", Self.authorizationScript(enabled: enabled)
        ])
        guard result.status == 0 else {
            if result.text.range(of: #"\(-128\)\s*$"#,
                                 options: .regularExpression) != nil {
                throw PowerError.cancelled
            }
            throw PowerError.commandFailed(Self.trim(result.text))
        }
        guard try readEnabled() == enabled else {
            throw PowerError.verificationFailed
        }
    }

    private static func trim(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "命令未返回错误详情。" : String(trimmed.prefix(2_000))
    }
}

/// In-memory backend for isolated tests. The release app uses PmsetService.
final class DemoPowerService: PowerManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func readEnabled() throws -> Bool {
        lock.withLock { enabled }
    }

    func setEnabled(_ value: Bool) throws {
        lock.withLock { enabled = value }
    }
}
