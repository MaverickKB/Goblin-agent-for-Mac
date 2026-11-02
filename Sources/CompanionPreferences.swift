import AppKit
import Observation

@MainActor
@Observable
final class CompanionPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var windowLevelChanged: (() -> Void)?
    @ObservationIgnored var pushToTalkChanged: (() -> Void)?

    var alwaysOnTop: Bool {
        didSet {
            defaults.set(alwaysOnTop, forKey: "keepOnTop")
            windowLevelChanged?()
        }
    }
    var animations: Bool {
        didSet { defaults.set(animations, forKey: "animations") }
    }
    var commandReturn: String {
        didSet { defaults.set(commandReturn, forKey: "commandReturn") }
    }
    var pushToTalk: Bool {
        didSet {
            defaults.set(pushToTalk, forKey: "pushToTalk")
            pushToTalkChanged?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alwaysOnTop = defaults.bool(forKey: "keepOnTop")
        animations = defaults.object(forKey: "animations") as? Bool ?? true
        pushToTalk = defaults.bool(forKey: "pushToTalk")
        let savedCommand = defaults.string(forKey: "commandReturn")
        if savedCommand == "queue" {
            commandReturn = "queue"
        } else {
            commandReturn = "steer"
        }
    }
}

@MainActor
protocol CompanionVoice: AnyObject {
    var isConnected: Bool { get }
    func start(initiallyMuted: Bool) async throws
    func setMuted(_ muted: Bool)
}

@MainActor
@Observable
final class PushToTalkController {
    private(set) var isHeld = false
    @ObservationIgnored private let voice: any CompanionVoice
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored var onError: ((String) -> Void)?

    init(voice: any CompanionVoice) {
        self.voice = voice
    }

    @discardableResult
    func press() -> Task<Void, Never>? {
        if isHeld { return connecting }
        isHeld = true
        if voice.isConnected {
            voice.setMuted(false)
            return nil
        }
        voice.setMuted(true)
        if connecting != nil { return connecting }
        connecting = Task { [weak self] in
            guard let self else { return }
            defer { self.connecting = nil }
            do {
                try await self.voice.start(initiallyMuted: true)
                if self.isHeld && self.voice.isConnected && !Task.isCancelled {
                    self.voice.setMuted(false)
                }
            } catch is CancellationError {
                return
            } catch {
                self.onError?(error.localizedDescription)
            }
        }
        return connecting
    }

    func release() {
        isHeld = false
        voice.setMuted(true)
    }
}
