import os

public enum Log {
    public static let subsystem = "dev.claudexbar"
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let claude = Logger(subsystem: subsystem, category: "claude")
    public static let codex = Logger(subsystem: subsystem, category: "codex")
    public static let usage = Logger(subsystem: subsystem, category: "usage")
    public static let fs = Logger(subsystem: subsystem, category: "fs")
}
