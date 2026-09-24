import Foundation

public struct ClaudePaths: Sendable, Equatable {
    /// `~/.claude` (or `CLAUDE_CONFIG_DIR`).
    public var home: String
    /// `~/Library/Application Support/Claude` (desktop app).
    public var desktopSupport: String
    /// `~/.claude.json` (account metadata; used to pick the org's usage samples).
    public var accountFile: String

    public init(home: String, desktopSupport: String, accountFile: String) {
        self.home = home
        self.desktopSupport = desktopSupport
        self.accountFile = accountFile
    }

    public static func standard(homeDirectory: String = NSHomeDirectory(), configDirOverride: String? = nil) -> ClaudePaths {
        ClaudePaths(
            home: configDirOverride ?? Paths.join(homeDirectory, ".claude"),
            desktopSupport: Paths.join(homeDirectory, "Library/Application Support/Claude"),
            accountFile: Paths.join(homeDirectory, ".claude.json")
        )
    }

    public var sessionsDir: String { Paths.join(home, "sessions") }
    public var projectsDir: String { Paths.join(home, "projects") }
    public var planUsageHistory: String { Paths.join(desktopSupport, "plan-usage-history.json") }
}
