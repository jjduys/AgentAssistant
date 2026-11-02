import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}

func expectThrows(_ error: PowerError, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw TestFailure(description: "Expected \(error), but operation succeeded")
    } catch let actual as PowerError {
        try expect(actual == error, "Wrong error: \(actual)")
    }
}

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }
    private let lock = NSLock()
    private var outputs: [CommandOutput]
    private var recorded: [Invocation] = []
    var invocations: [Invocation] { lock.withLock { recorded } }

    init(_ outputs: [CommandOutput]) { self.outputs = outputs }

    func run(_ executable: String, arguments: [String]) throws -> CommandOutput {
        try lock.withLock {
            recorded.append(Invocation(executable: executable, arguments: arguments))
            guard !outputs.isEmpty else { throw TestFailure(description: "Unexpected command") }
            return outputs.removeFirst()
        }
    }
}

final class TestPowerService: PowerManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var writes: [Bool] = []
    private var failure: PowerError?
    private var failReads = false
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var blocking = false

    var recordedWrites: [Bool] { lock.withLock { writes } }

    func configure(value: Bool? = nil, failure: PowerError? = nil, failReads: Bool = false) {
        lock.withLock {
            if let value { enabled = value }
            self.failure = failure
            self.failReads = failReads
        }
    }

    func readEnabled() throws -> Bool {
        try lock.withLock {
            if failReads { throw PowerError.unreadableState }
            return enabled
        }
    }

    func setEnabled(_ value: Bool) throws {
        let shouldBlock = lock.withLock { blocking }
        if shouldBlock {
            started.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw TestFailure(description: "Blocking test timed out")
            }
        }
        try lock.withLock {
            writes.append(value)
            if let failure { throw failure }
            enabled = value
        }
    }

    func blockNextWrite() { lock.withLock { blocking = true } }
    func waitForWrite() -> Bool { started.wait(timeout: .now() + 5) == .success }
    func releaseWrite() { release.signal() }
}

@main
struct Tests {
    @MainActor static func main() async {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS \(name)")
        }
        do {
            try test("Parse enabled system setting with tabs and unrelated settings") {
                let value = try PmsetService.parseEnabled("System-wide power settings:\n SleepDisabled\t\t1\n sleep 0\n")
                try expect(value, "Enabled state not read")
            }
            try test("Parse disabled system setting with spaces") {
                let value = try PmsetService.parseEnabled("SleepDisabled    0\n")
                try expect(!value, "Disabled state not read")
            }
            try test("Never treat a sleep timer or malformed setting as the switch") {
                for invalid in ["sleep 0", "SleepDisabled 2", "SleepDisabled 10", "SleepDisabled 1 extra", "", "OtherSleepDisabled 1"] {
                    try expectThrows(.unreadableState) { _ = try PmsetService.parseEnabled(invalid) }
                }
            }
            try test("Read invokes only the fixed read-only pmset command") {
                let runner = RecordingRunner([.init(status: 0, text: "SleepDisabled 1")])
                try expect(try PmsetService(runner: runner).readEnabled(), "Read failed")
                try expect(runner.invocations == [.init(executable: "/usr/bin/pmset", arguments: ["-g"])], "Wrong read command")
            }
            try test("Failed read cannot produce an enabled status") {
                let service = PmsetService(runner: RecordingRunner([.init(status: 1, text: "not available")]))
                try expectThrows(.commandFailed("not available")) { _ = try service.readEnabled() }
            }
            try test("Both toggles request administrator privileges then verify live state") {
                for enabled in [false, true] {
                    let value = enabled ? "1" : "0"
                    let runner = RecordingRunner([.init(status: 0, text: ""), .init(status: 0, text: "SleepDisabled \(value)")])
                    try PmsetService(runner: runner).setEnabled(enabled)
                    let calls = runner.invocations
                    try expect(calls.count == 2, "Write was not verified")
                    try expect(calls[0].executable == "/usr/bin/osascript", "Wrong authorization tool")
                    try expect(calls[0].arguments[1].contains("/usr/bin/pmset -a disablesleep \(value)"), "Wrong pmset command")
                    try expect(calls[0].arguments[1].contains("with administrator privileges"), "No administrator authorization")
                    try expect(calls[1] == .init(executable: "/usr/bin/pmset", arguments: ["-g"]), "Wrong verification command")
                }
            }
            try test("AppleScript authorization scripts compile on this Mac without executing") {
                for enabled in [false, true] {
                    let path = "\(FileManager.default.currentDirectoryPath)/build/auth-\(enabled).scpt"
                    let result = try SystemCommandRunner().run("/usr/bin/osacompile", arguments: [
                        "-o", path, "-e", PmsetService.authorizationScript(enabled: enabled)
                    ])
                    try expect(result.status == 0, "Invalid AppleScript: \(result.text)")
                }
            }
            try test("Cancelled administrator authorization is recognized independently of language") {
                let runner = RecordingRunner([.init(status: 1, text: "execution error: 用户已取消。 (-128)\n")])
                try expectThrows(.cancelled) { try PmsetService(runner: runner).setEnabled(true) }
                try expect(runner.invocations.count == 1, "Cancellation invoked an extra write")
            }
            try test("Authorization or command errors are surfaced") {
                let service = PmsetService(runner: RecordingRunner([.init(status: 1, text: "permission denied (1)")]))
                try expectThrows(.commandFailed("permission denied (1)")) { try service.setEnabled(true) }
            }
            try test("A successful command with an unchanged setting is rejected") {
                let runner = RecordingRunner([.init(status: 0, text: ""), .init(status: 0, text: "SleepDisabled 0")])
                try expectThrows(.verificationFailed) { try PmsetService(runner: runner).setEnabled(true) }
            }

            let service = TestPowerService()
            let controller = SleepController(service: service)
            var errors: [String] = []
            controller.onError = { errors.append($0) }
            await controller.refresh()
            try test("Startup observes current state without writing") {
                try expect(controller.state == .ready(false), "Wrong initial state")
                try expect(service.recordedWrites.isEmpty, "Startup wrote system settings")
            }
            await controller.toggle()
            await controller.toggle()
            try test("Two menu actions enable then disable") {
                try expect(service.recordedWrites == [true, false], "Wrong toggle sequence")
                try expect(controller.state == .ready(false), "Wrong final state")
            }
            service.configure(value: true)
            await controller.toggle()
            try test("Toggle re-reads an externally changed setting before choosing the new value") {
                try expect(service.recordedWrites.last == false, "Toggled stale UI state")
                try expect(controller.state == .ready(false), "External state not synchronized")
            }
            service.configure(failure: .cancelled)
            await controller.toggle()
            try test("Cancelling preserves observed state and does not show an error alert") {
                try expect(controller.state == .ready(false), "Cancellation falsely enabled the icon")
                try expect(errors.isEmpty, "Cancellation produced an error alert")
                try expect(!controller.isWorking, "Cancellation kept the button locked")
            }
            service.configure(failure: .commandFailed("failed"))
            await controller.toggle()
            try test("Command failure preserves actual state and reports an error") {
                try expect(controller.state == .ready(false), "Failure falsely enabled the icon")
                try expect(errors.count == 1, "Failure was not reported exactly once")
            }
            service.configure(failReads: true)
            await controller.refresh()
            try test("Read failure shows unknown status instead of stale green") {
                guard case .unavailable = controller.state else {
                    throw TestFailure(description: "Read failure left a known status")
                }
                try expect(controller.state.enabled == nil, "Read failure is presented as on/off")
            }
            service.configure(value: true)
            await controller.refresh()
            try test("Refresh recovers from failure and observes external changes") {
                try expect(controller.state == .ready(true), "Refresh did not recover")
            }
            service.blockNextWrite()
            let firstToggle = Task { await controller.toggle() }
            let reachedWrite = await Task.detached { service.waitForWrite() }.value
            let writesBefore = service.recordedWrites.count
            await controller.toggle()
            await controller.refresh()
            service.releaseWrite()
            await firstToggle.value
            try test("Concurrent clicks and polling cannot launch overlapping privileged commands") {
                try expect(reachedWrite, "Test never entered the first write")
                try expect(service.recordedWrites.count == writesBefore + 1, "Multiple writes overlapped")
                try expect(controller.state == .ready(false), "Wrong result after overlapping clicks")
                try expect(!controller.isWorking, "Button remained locked")
            }
            print("\n\(passed) tests passed. No system settings were changed.")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
