import AppKit

// Supervisor mode for the nettop child (see NettopGuard). Runs before any AppKit setup.
let argv = CommandLine.arguments
if argv.count >= 3, argv[1] == "--nettop-guard", let parent = pid_t(argv[2]) {
    NettopGuard.run(parent: parent, nettopArgs: Array(argv.dropFirst(3)))
}

// Read-only MCP server for AI assistants (stdio). Never touches AppKit, never writes data.
if argv.count >= 2, argv[1] == "--mcp" {
    MCPServer.run()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
