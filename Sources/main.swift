import AppKit

if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests(); print("AgentAssistant self-test: PASS"); exit(0) }
    catch { fputs("AgentAssistant self-test: FAIL: \(error)\n", stderr); exit(1) }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--ui-test") {
        do { try runUITests(); print("AgentAssistant UI smoke: PASS"); exit(0) }
        catch { fputs("AgentAssistant UI smoke: FAIL: \(error)\n", stderr); exit(1) }
    }
    if CommandLine.arguments.contains("--capture-probe") {
        app.setActivationPolicy(.regular)
        do { try runCaptureProbe(); exit(0) } catch { fputs("Capture probe failed: \(error)\n", stderr); exit(1) }
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
