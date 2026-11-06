import SwiftUI
import AppKit

enum MCPSetup {
    static var executablePath: String { Bundle.main.executablePath ?? "/Applications/MacPulse.app/Contents/MacOS/MacPulse" }

    static var claudeCodeCommand: String {
        "claude mcp add --scope user macpulse -- \"\(executablePath)\" --mcp"
    }

    static var jsonSnippet: String {
        """
        {
          "mcpServers": {
            "macpulse": {
              "command": "\(executablePath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    static var claudeDesktopConfig: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    enum InstallResult { case installed, alreadyPresent, claudeNotFound, invalidExistingConfig(String), failed(String) }

    /// Adds MacPulse to Claude Desktop's config. Merges into the existing file (never discards other
    /// servers or settings), refuses to touch a file it can't parse, and keeps a `.bak` copy.
    static func installInClaudeDesktop() -> InstallResult {
        let url = claudeDesktopConfig
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else { return .claudeNotFound }
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: url.path), !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .invalidExistingConfig(url.path)
            }
            root = obj
            try? data.write(to: url.appendingPathExtension("bak"), options: .atomic)
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let entry: [String: Any] = ["command": executablePath, "args": ["--mcp"]]
        if let existing = servers["macpulse"] as? [String: Any],
           existing["command"] as? String == executablePath, existing["args"] as? [String] == ["--mcp"] {
            return .alreadyPresent
        }
        servers["macpulse"] = entry
        root["mcpServers"] = servers
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct MCPSettingsCard: View {
    @AppStorage("mcpShareDestinations") private var shareDestinations = true
    @State private var message: String?

    var body: some View {
        Card(title: T("الذكاء الاصطناعي (MCP)", "AI assistants (MCP)"), symbol: "sparkles", tint: Palette.memory) {
            Text(T("اربط MacPulse مع Claude ليقرأ بياناتك ويحللها. القراءة فقط: لا يستطيع المساعد تغيير أي شيء أو تشغيل أوامر.",
                   "Connect MacPulse to Claude so it can read and analyse your data. Read-only: the assistant can't change anything or run commands."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $shareDestinations) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(T("مشاركة عناوين الخوادم مع المساعد", "Share server addresses with the assistant"))
                    Text(T("الوجهات التي اتصلت بها التطبيقات", "Which servers your apps talked to"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            GlassGroup(spacing: 8) {
                VStack(spacing: 8) {
                    Button {
                        message = describe(MCPSetup.installInClaudeDesktop())
                    } label: {
                        Label(T("إضافة إلى Claude Desktop", "Add to Claude Desktop"), systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    HStack(spacing: 8) {
                        Button {
                            MCPSetup.copy(MCPSetup.claudeCodeCommand)
                            message = T("تم نسخ أمر Claude Code — الصقه في الطرفية.", "Claude Code command copied — paste it in Terminal.")
                        } label: { Label(T("أمر Claude Code", "Claude Code command"), systemImage: "terminal").frame(maxWidth: .infinity) }
                        .glassButton()
                        Button {
                            MCPSetup.copy(MCPSetup.jsonSnippet)
                            message = T("تم نسخ إعداد JSON (لـ Cursor وغيره).", "JSON config copied (Cursor, etc.).")
                        } label: { Label(T("نسخ JSON", "Copy JSON"), systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                        .glassButton()
                    }
                }
            }
            .controlSize(.small)

            if let message { Text(message).font(.caption2).foregroundStyle(Palette.battery).fixedSize(horizontal: false, vertical: true) }

            Footnote(text: T("الأدوات: الحالة الحية، البطارية، الذاكرة، أكثر التطبيقات، الوجهات، السجل، تقرير البطارية. ChatGPT يدعم حالياً خوادم MCP البعيدة فقط عبر الإنترنت، ولذلك لم يُفعَّل للحفاظ على خصوصية بياناتك.",
                             "Tools: live status, battery, memory, top apps, destinations, history, battery report. ChatGPT currently only connects to remote MCP servers over the internet, so it isn't enabled — your data stays local."))
        }
    }

    private func describe(_ r: MCPSetup.InstallResult) -> String {
        switch r {
        case .installed: T("تمت الإضافة ✓ — أعد تشغيل Claude Desktop.", "Added ✓ — restart Claude Desktop.")
        case .alreadyPresent: T("موجود مسبقاً في Claude Desktop ✓", "Already added to Claude Desktop ✓")
        case .claudeNotFound: T("لم يتم العثور على Claude Desktop على هذا الجهاز.", "Claude Desktop isn't installed on this Mac.")
        case .invalidExistingConfig(let p): T("ملف الإعداد الحالي غير صالح، لم يتم تعديله: ", "Existing config isn't valid JSON, left untouched: ") + p
        case .failed(let e): T("فشل الحفظ: ", "Couldn't save: ") + e
        }
    }
}
