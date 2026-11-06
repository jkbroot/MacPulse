import Foundation
import Darwin

/// Read-only Model Context Protocol server: `MacPulse --mcp` (stdio transport).
///
/// Lets an AI assistant (Claude Desktop, Claude Code, Cursor, …) *read and analyse* MacPulse data.
///
/// Security model
/// - **Read-only by construction**: no tool changes anything. The history DB is opened with
///   `SQLITE_OPEN_READONLY` + `PRAGMA query_only`; live data comes from the same unprivileged
///   collectors the app uses. There is no tool that runs commands, kills processes or writes files.
/// - **stdio only**: no network port is opened; only the client that launched the process can talk to it.
/// - **Validated inputs**: ranges/sort keys are enums, limits are clamped, the app filter is matched
///   in Swift (never interpolated into SQL), request lines are size-limited.
/// - **User control**: server addresses are shared only if "Share server addresses with AI" is on.
enum MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let maxLineBytes = 1 << 20

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard line.utf8.count <= maxLineBytes,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = obj as? [[String: Any]] {
                let replies = batch.compactMap(handle)
                if !replies.isEmpty { sendRaw(replies) }
            } else if let msg = obj as? [String: Any], let reply = handle(msg) {
                send(reply)
            }
        }
        exit(0)
    }

    // MARK: - JSON-RPC

    private static func handle(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return nil }   // responses / junk: ignore
        let isNotification = id == nil
        func ok(_ result: [String: Any]) -> [String: Any]? {
            isNotification ? nil : ["jsonrpc": "2.0", "id": id!, "result": result]
        }
        func fail(_ code: Int, _ message: String) -> [String: Any]? {
            isNotification ? nil : ["jsonrpc": "2.0", "id": id!, "error": ["code": code, "message": message]]
        }

        switch method {
        case "initialize":
            let params = msg["params"] as? [String: Any]
            let asked = params?["protocolVersion"] as? String ?? protocolVersions[0]
            return ok([
                "protocolVersion": protocolVersions.contains(asked) ? asked : protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "macpulse", "title": "MacPulse (read-only)", "version": "1.1.0"],
                "instructions": """
                MacPulse is a read-only Mac performance monitor. Use these tools to read live CPU, memory, \
                battery/energy and network data, and up to 30 days of history (per-app energy, network, \
                destinations). All tools are read-only. Units are in the field names (_w = watts, _wh = \
                watt-hours, _bytes, _bps = bytes per second, _pct = percent 0–100). Per-app energy is CPU \
                energy from kernel counters; whole-system power also includes display/GPU.
                """,
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": Tools.definitions])
        case "resources/list":
            return ok(["resources": []])
        case "prompts/list":
            return ok(["prompts": []])
        case "tools/call":
            guard let params = msg["params"] as? [String: Any], let name = params["name"] as? String else {
                return fail(-32602, "Invalid params")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let payload = try Tools.call(name, args)
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
                return ok(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                           "structuredContent": payload,
                           "isError": false])
            } catch let e as ToolError {
                // Tool-level errors are reported in the result so the model can see and adapt.
                return ok(["content": [["type": "text", "text": e.message]], "isError": true])
            } catch {
                return ok(["content": [["type": "text", "text": "Internal error"]], "isError": true])
            }
        default:
            return fail(-32601, "Method not found: \(method.prefix(64))")
        }
    }

    private static func send(_ obj: [String: Any]) { sendRaw(obj) }

    private static func sendRaw(_ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

struct ToolError: Error { let message: String }
