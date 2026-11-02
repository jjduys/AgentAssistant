import AppKit

@MainActor
final class SleepMenuController: NSObject {
    private let controller: SleepController
    private weak var stateItem: NSMenuItem?
    private weak var toggleItem: NSMenuItem?
    private weak var refreshItem: NSMenuItem?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    var isWorking: Bool { controller.isWorking }

    init(service: any PowerManaging) {
        controller = SleepController(service: service)
        super.init()
        controller.onChange = { [weak self] _ in self?.updateItems() }
        controller.onError = { message in showError(AppError.message(message)) }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.controller.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.controller.refresh() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func addItems(to menu: NSMenu) {
        let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        state.isEnabled = false; menu.addItem(state); stateItem = state
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: "", action: #selector(toggle), keyEquivalent: "")
        toggle.target = self; toggleItem = toggle
        let refresh = menu.addItem(withTitle: "刷新状态", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self; refreshItem = refresh
        menu.addItem(.separator())
        updateItems()
    }

    private func updateItems() {
        stateItem?.title = controller.state.title
        toggleItem?.title = controller.state.enabled == true ? "关闭永不睡眠" : "开启永不睡眠"
        toggleItem?.isEnabled = !controller.isWorking
        refreshItem?.isEnabled = !controller.isWorking
        stateItem?.toolTip = "系统睡眠开关；退出 AgentAssistant 后保留当前设置。切换时需要管理员授权。"
        if case let .unavailable(message) = controller.state { stateItem?.toolTip = message }
    }

    @objc private func toggle() {
        guard !controller.isWorking else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task { await controller.toggle() }
    }

    @objc private func refresh() { Task { await controller.refresh() } }
}
