import Foundation

enum SleepState: Equatable {
    case loading
    case ready(Bool)
    case changing(previous: Bool?)
    case unavailable(String)

    var enabled: Bool? {
        switch self {
        case .ready(let value): return value
        case .changing(let value): return value
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .loading: return "正在读取系统状态…"
        case .ready(true): return "永不睡眠：已开启"
        case .ready(false): return "永不睡眠：已关闭"
        case .changing: return "正在切换睡眠设置…"
        case .unavailable: return "永不睡眠：状态未知"
        }
    }
}

@MainActor
final class SleepController {
    private let service: any PowerManaging
    private(set) var isWorking = false {
        didSet { onChange?(state) }
    }
    private(set) var state: SleepState = .loading {
        didSet { onChange?(state) }
    }
    var onChange: ((SleepState) -> Void)?
    var onError: ((String) -> Void)?

    init(service: any PowerManaging) {
        self.service = service
    }

    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let backend = service
        do {
            let enabled = try await Task.detached { try backend.readEnabled() }.value
            state = .ready(enabled)
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    func toggle() async {
        guard !isWorking else { return }
        isWorking = true
        state = .changing(previous: state.enabled)
        defer { isWorking = false }
        let backend = service
        do {
            // Re-read just before toggling: another app/Terminal may have changed it.
            let enabled = try await Task.detached {
                let requested = try !backend.readEnabled()
                try backend.setEnabled(requested)
                return requested
            }.value
            state = .ready(enabled)
        } catch {
            let operationError = error
            // A failed write may still have changed the setting. Display observed truth.
            do {
                let actual = try await Task.detached { try backend.readEnabled() }.value
                state = .ready(actual)
            } catch {
                state = .unavailable(error.localizedDescription)
            }
            if (operationError as? PowerError) != .cancelled {
                onError?(operationError.localizedDescription)
            }
        }
    }
}
