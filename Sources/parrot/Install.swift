import ArgumentParser
import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since parrot ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    @Flag(
        name: .long,
        help: "Update the launch-at-login agent's model. Pass a model id or choose interactively."
    )
    var selectModel: Bool = false

    @Argument(help: "Model id to use with --select-model.")
    var selectedModelID: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Keep daemon output in ~/Library/Logs/parrot.log (mode 0600). When omitted, an existing agent keeps its current setting; a fresh install discards output.")
    var logFile: Bool?

    @Flag(name: .long, help: "Delete the world-readable /tmp/parrot.{out,err}.log files left by earlier versions.")
    var purgeLegacyLogs: Bool = false

    func run() throws {
        if selectedModelID != nil && !selectModel {
            FileHandle.standardError.write(Data(
                "model id can only be specified with --select-model\n".utf8
            ))
            throw ExitCode(64)
        }

        let actionCount = [launchAtLogin, uninstall, selectModel].filter { $0 }.count
        if actionCount > 1 || (actionCount == 0 && !purgeLegacyLogs) {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login, --uninstall, --select-model, or --purge-legacy-logs\n".utf8
            ))
            throw ExitCode(64)
        }

        reportLegacyLogs()
        if purgeLegacyLogs {
            purgeLegacyLogFiles()
        }

        if uninstall {
            try removeAgent()
        } else if selectModel {
            let model = try resolveSelectedModel()
            try writeAgent(selectedModelID: model.id, actionName: "updated")
        } else if launchAtLogin {
            try writeAgent(selectedModelID: nil, actionName: "installed")
        }
    }

    // MARK: -

    private static let label = "com.digimata.parrot"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func writeAgent(selectedModelID: String?, actionName: String) throws {
        let binary = try resolveBinaryPath()
        var programArguments = [binary, "run", "--skip-doctor"]
        if let selectedModelID {
            programArguments.append(contentsOf: ["--model", selectedModelID])
        }

        // --select-model (and any other rewrite) must not silently drop a
        // previously chosen log destination, so an omitted flag means "keep
        // whatever the current plist says".
        let keepLog = logFile ?? existingAgentKeepsLogs()
        let logPath: String
        if keepLog {
            logPath = try prepareLogFile()
        } else {
            logPath = "/dev/null"
        }

        // ProgramArguments deliberately omits --echo-transcripts: a background
        // daemon must never be configured to write transcript text to a log.
        var plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        // Deliberately no Umask key: it would apply to everything the daemon
        // creates, including model-cache directories, which then lose their
        // execute bit and break downloads with EACCES. prepareLogFile creates
        // the log 0600 and every install rewrite re-tightens it; the one gap —
        // launchd recreating a deleted log at 0644 — is acceptable because the
        // log never holds transcript text.

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort restart of the managed LaunchAgent. This only targets
        // parrot's launchd label, not manually started foreground processes.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }
        let kickstart = runLaunchctl(["kickstart", "-k", "gui/\(uid())/\(Self.label)"])
        if kickstart.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl kickstart exited \(kickstart.status):\n\(kickstart.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login \(actionName)")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        if let selectedModelID {
            print("  model:  \(selectedModelID)")
        }
        if keepLog {
            print("  logs:   \(logPath) (mode 0600)")
        } else {
            print("  logs:   discarded — pass --log-file to keep them")
        }
    }

    /// Whether the currently installed agent writes its output to a log file
    /// (anything other than /dev/null). Missing or unreadable plist means no.
    private func existingAgentKeepsLogs() -> Bool {
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any],
            let path = plist["StandardErrorPath"] as? String
        else { return false }
        return path != "/dev/null"
    }

    /// launchd appends to an existing std-path file and leaves its mode alone,
    /// but creates a missing one at 0644 — so create it 0600 before bootstrap.
    private func prepareLogFile() throws -> String {
        let fm = FileManager.default
        let url = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("parrot.log")
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: url.path) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            _ = fm.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        return url.path
    }

    private static let legacyLogPaths = ["/tmp/parrot.out.log", "/tmp/parrot.err.log"]

    /// Versions up to v0.0.5 pointed the daemon's stderr at /tmp and logged
    /// every transcript, so anyone who ran `--launch-at-login` has a plaintext
    /// record of everything they dictated, readable by any local user.
    private func reportLegacyLogs() {
        let fm = FileManager.default
        let found = Self.legacyLogPaths.filter { fm.fileExists(atPath: $0) }
        guard !found.isEmpty else { return }

        var msg = "\n⚠️  found logs from an earlier parrot version:\n"
        for path in found {
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            msg += "     \(path) — \(size) bytes\n"
        }
        msg += "   these are world-readable and contain the text of every transcript\n"
        msg += "   parrot produced while the daemon was running.\n"
        if !purgeLegacyLogs {
            msg += "   review them, then delete with: parrot install --purge-legacy-logs\n"
        }
        msg += "\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    private func purgeLegacyLogFiles() {
        let fm = FileManager.default
        let found = Self.legacyLogPaths.filter { fm.fileExists(atPath: $0) }
        if found.isEmpty {
            print("no legacy /tmp logs to remove")
            return
        }
        for path in found {
            do {
                try fm.removeItem(atPath: path)
                print("✓ removed \(path)")
            } catch {
                FileHandle.standardError.write(Data(
                    "couldn't remove \(path): \(error)\n".utf8
                ))
            }
        }
    }

    private func resolveSelectedModel() throws -> TranscriptionModel {
        let id: String
        if let selectedModelID {
            id = selectedModelID
        } else {
            id = try promptForModelID()
        }

        guard let model = ModelRegistry.find(id) else {
            FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
            throw ExitCode(1)
        }
        return model
    }

    private func promptForModelID() throws -> String {
        print("Select a model for the launch-at-login agent:")
        for (index, model) in ModelRegistry.shared.enumerated() {
            let marker = model.recommended ? " (recommended)" : ""
            print("  \(index + 1). \(model.id) - \(model.displayName)\(marker)")
        }
        print("Enter a number: ", terminator: "")
        fflush(stdout)

        guard let line = readLine(), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data("no model selected\n".utf8))
            throw ExitCode(64)
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let choice = Int(trimmed),
            ModelRegistry.shared.indices.contains(choice - 1)
        else {
            FileHandle.standardError.write(Data("invalid model selection: \(trimmed)\n".utf8))
            throw ExitCode(64)
        }

        return ModelRegistry.shared[choice - 1].id
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/parrot is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/parrot"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "parrot"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/parrot not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the parrot binary. install it to /usr/local/bin/parrot first.\n".utf8
        ))
        throw ExitCode(1)
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
