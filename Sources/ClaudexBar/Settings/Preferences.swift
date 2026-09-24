import ClaudexCore
import Foundation
import Observation

/// User preferences, persisted in UserDefaults. AppKit consumers observe `changes`.
@Observable
final class Preferences {
    enum DisplayChoice: String, CaseIterable, Identifiable {
        case notched, main, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notched: return "Notched display (built-in)"
            case .main: return "Main display"
            case .all: return "All displays"
            }
        }
    }

    enum EarSize: String, CaseIterable, Identifiable {
        case regular, compact
        var id: String { rawValue }
        var metrics: IslandMetrics { self == .regular ? .regular : .compact }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let changes: AsyncStream<Void>
    @ObservationIgnored private let continuation: AsyncStream<Void>.Continuation
    /// `didSet` also runs for assignments in `init` under @Observable; don't persist those.
    @ObservationIgnored private var loading = true

    var displayChoice: DisplayChoice { didSet { save("displayChoice", displayChoice.rawValue) } }
    var hideInFullScreen: Bool { didSet { save("hideInFullScreen", hideInFullScreen) } }
    var earSize: EarSize { didSet { save("earSize", earSize.rawValue) } }
    var showUsageRing: Bool { didSet { save("showUsageRing", showUsageRing) } }
    var peekAttention: Bool { didSet { save("peekAttention", peekAttention) } }
    var peekFinished: Bool { didSet { save("peekFinished", peekFinished) } }
    var peekUsage: Bool { didSet { save("peekUsage", peekUsage) } }
    var sound: Bool { didSet { save("sound", sound) } }
    var claudeUsageAPI: Bool { didSet { save("claudeUsageAPI", claudeUsageAPI) } }
    var codexUsageAPI: Bool { didSet { save("codexUsageAPI", codexUsageAPI) } }
    var freshMinutes: Int { didSet { save("freshMinutes", freshMinutes) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        displayChoice = DisplayChoice(rawValue: defaults.string(forKey: "displayChoice") ?? "") ?? .notched
        hideInFullScreen = bool("hideInFullScreen", false)
        earSize = EarSize(rawValue: defaults.string(forKey: "earSize") ?? "") ?? .regular
        showUsageRing = bool("showUsageRing", true)
        peekAttention = bool("peekAttention", true)
        peekFinished = bool("peekFinished", true)
        peekUsage = bool("peekUsage", true)
        sound = bool("sound", false)
        claudeUsageAPI = bool("claudeUsageAPI", true)
        codexUsageAPI = bool("codexUsageAPI", true)
        let minutes = defaults.integer(forKey: "freshMinutes")
        freshMinutes = minutes > 0 ? minutes : 30
        loading = false
    }

    private func save(_ key: String, _ value: Any) {
        guard !loading else { return }
        defaults.set(value, forKey: key)
        continuation.yield()
    }

    func allows(_ event: PeekEvent) -> Bool {
        switch event.kind {
        case .attention: return peekAttention
        case .finished: return peekFinished
        case .usage: return peekUsage
        }
    }
}
