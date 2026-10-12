import AppKit
import CryptoKit
import Foundation

private enum AppConfig {
    static let label = "app.lidawake.LidAwake.power-monitor"
    static let helperPath = "/Library/PrivilegedHelperTools/app.lidawake.LidAwake.power-monitor"
    static let launchDaemonPath = "/Library/LaunchDaemons/app.lidawake.LidAwake.power-monitor.plist"
    static let systemSupportDirectory = URL(fileURLWithPath: "/Library/Application Support/Lid Awake (Public Build)", isDirectory: true)
    static let statusPath = systemSupportDirectory.appendingPathComponent("status")
    static let effectivePath = systemSupportDirectory.appendingPathComponent("effective")
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lid Awake (Public Build)", isDirectory: true)
    static let statePath = supportDirectory.appendingPathComponent("enabled")
    static let resourceHashes: [String: String] = [
        "power-monitor": "@POWER_MONITOR_SHA256@",
        "install-helper": "@INSTALL_HELPER_SHA256@",
        "uninstall-helper": "@UNINSTALL_HELPER_SHA256@"
    ]
}

private enum PowerSource {
    case ac
    case battery
    case unknown

    var description: String {
        switch self {
        case .ac: return "Connected to power"
        case .battery: return "On battery"
        case .unknown: return "Power source unavailable"
        }
    }
}

private struct SystemSnapshot {
    let enabled: Bool
    let powerSource: PowerSource
    let sleepDisabled: Bool
    let helperInstalled: Bool
    let helperRunning: Bool
    let helperConflict: Bool
    let helperState: String
}

@main
final class LidAwakeApplication: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var snapshot = SystemSnapshot(
        enabled: false,
        powerSource: .unknown,
        sleepDisabled: false,
        helperInstalled: false,
        helperRunning: false,
        helperConflict: false,
        helperState: "off"
    )
    private var refreshInFlight = false
    private var actionInFlight = false
    private static let fallbackSleepLock = NSLock()
    private static var fallbackSleepCache: (checkedAt: Date, disabled: Bool)?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LidAwakeApplication()
        app.delegate = delegate
        app.run()
        _ = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Lid Awake"
        refreshStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func refreshStatus() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Self.readSnapshot()
            DispatchQueue.main.async {
                self.snapshot = result
                self.refreshInFlight = false
                self.rebuildMenu()
            }
        }
    }

    private static func readSnapshot() -> SystemSnapshot {
        let launchDaemonURL = URL(fileURLWithPath: AppConfig.launchDaemonPath)
        let helperInstalled = FileManager.default.fileExists(atPath: launchDaemonURL.path)
        let configuredStatePath: String? = {
            guard let data = try? Data(contentsOf: launchDaemonURL),
                  let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let arguments = propertyList["ProgramArguments"] as? [String],
                  arguments.count >= 3 else { return nil }
            return arguments[2]
        }()
        let launchdStatus = run("/bin/launchctl", ["print", "system/\(AppConfig.label)"]) ?? ""
        let helperRunning = launchdStatus.contains("state = running") && launchdStatus.contains("pid =")
        let helperConflict = (helperInstalled || helperRunning) && configuredStatePath != AppConfig.statePath.path
        let statePath = helperConflict ? (configuredStatePath ?? AppConfig.statePath.path) : AppConfig.statePath.path

        let enabled: Bool
        if let value = try? String(contentsOfFile: statePath, encoding: .utf8) {
            enabled = value.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        } else {
            enabled = false
        }

        let batteryOutput = run("/usr/bin/pmset", ["-g", "batt"]) ?? ""
        let powerSource: PowerSource
        if batteryOutput.contains("Now drawing from 'AC Power'") {
            powerSource = .ac
        } else if batteryOutput.contains("Now drawing from 'Battery Power'") {
            powerSource = .battery
        } else {
            powerSource = .unknown
        }

        let helperState = (try? String(contentsOf: AppConfig.statusPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let helperEffective = (try? String(contentsOf: AppConfig.effectivePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepDisabled: Bool
        if helperRunning && (helperEffective == "0" || helperEffective == "1") {
            sleepDisabled = helperEffective == "1"
        } else {
            sleepDisabled = readFallbackSleepState()
        }

        return SystemSnapshot(
            enabled: enabled,
            powerSource: powerSource,
            sleepDisabled: sleepDisabled,
            helperInstalled: helperInstalled,
            helperRunning: helperRunning,
            helperConflict: helperConflict,
            helperState: helperState
        )
    }

    private static func readFallbackSleepState() -> Bool {
        fallbackSleepLock.lock()
        defer { fallbackSleepLock.unlock() }
        if let cache = fallbackSleepCache, Date().timeIntervalSince(cache.checkedAt) < 15 {
            return cache.disabled
        }
        let fullOutput = run("/usr/bin/pmset", ["-g", "everything"]) ?? ""
        let disabled = fullOutput
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("SleepDisabled") })?
            .split(whereSeparator: \.isWhitespace)
            .last == "1"
        fallbackSleepCache = (Date(), disabled)
        return disabled
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func rebuildMenu() {
        guard let button = statusItem.button else { return }
        let needsAttention = snapshot.helperConflict
            || (snapshot.enabled && !snapshot.helperRunning)
            || (snapshot.helperInstalled && !snapshot.helperRunning)
        let symbol = needsAttention
            ? "exclamationmark.triangle"
            : (snapshot.enabled && snapshot.powerSource == .ac && snapshot.sleepDisabled ? "bolt.fill" : "moon.zzz")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lid Awake")
        button.image?.isTemplate = true
        button.title = ""
        let tooltipStatus: String
        if snapshot.helperConflict {
            tooltipStatus = "monitor belongs to another account"
        } else if snapshot.helperState == "error" {
            tooltipStatus = "sleep setting could not be confirmed"
        } else if snapshot.helperInstalled && !snapshot.helperRunning {
            tooltipStatus = "background monitor is not running"
        } else if snapshot.enabled {
            tooltipStatus = "enabled on AC; normal sleep on battery"
        } else if snapshot.sleepDisabled {
            tooltipStatus = "off; system sleep is still disabled"
        } else {
            tooltipStatus = "off; normal sleep"
        }
        button.toolTip = "Lid Awake — \(tooltipStatus)"

        let menu = NSMenu()
        menu.autoenablesItems = false

        let toggle = NSMenuItem(
            title: "Keep Awake While Plugged In",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = snapshot.enabled ? .on : .off
        toggle.isEnabled = !actionInFlight && !snapshot.helperConflict
        menu.addItem(toggle)

        let power = NSMenuItem(title: "Power: \(snapshot.powerSource.description)", action: nil, keyEquivalent: "")
        power.isEnabled = false
        menu.addItem(power)

        let statusTitle: String
        if snapshot.helperConflict {
            statusTitle = "Status: Monitor belongs to another account"
        } else if actionInFlight {
            statusTitle = "Status: Applying change…"
        } else if snapshot.helperInstalled && !snapshot.helperRunning {
            statusTitle = snapshot.sleepDisabled
                ? "Status: Monitor stopped; sleep may still be disabled"
                : "Status: Background monitor isn’t running"
        } else if snapshot.enabled && !snapshot.helperRunning {
            statusTitle = "Status: Background monitor needs setup"
        } else if snapshot.helperState == "error" {
            statusTitle = "Status: Couldn’t confirm the sleep setting"
        } else if snapshot.enabled && snapshot.powerSource == .ac && snapshot.sleepDisabled {
            statusTitle = "Status: Awake with the lid closed"
        } else if snapshot.enabled && snapshot.powerSource == .battery && !snapshot.sleepDisabled {
            statusTitle = "Status: Normal sleep on battery"
        } else if snapshot.enabled && snapshot.powerSource == .battery {
            statusTitle = "Status: Previous sleep setting remains active"
        } else if snapshot.enabled && snapshot.powerSource == .ac {
            statusTitle = "Status: Awake setting not confirmed"
        } else if !snapshot.enabled && snapshot.helperRunning && snapshot.helperState == "active" {
            statusTitle = "Status: Restoring saved sleep setting…"
        } else if !snapshot.enabled && snapshot.sleepDisabled {
            statusTitle = "Status: Sleep is disabled by another setting"
        } else {
            statusTitle = "Status: Normal sleep"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let behavior = NSMenuItem(title: "When on: sleep off on AC • normal on battery", action: nil, keyEquivalent: "")
        behavior.isEnabled = false
        menu.addItem(behavior)

        menu.addItem(.separator())

        let remove = NSMenuItem(
            title: "Remove Background Monitor…",
            action: #selector(removeHelper(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        remove.isEnabled = snapshot.helperInstalled && !actionInFlight && !snapshot.helperConflict
        menu.addItem(remove)

        let quit = NSMenuItem(title: "Quit Lid Awake", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        guard !actionInFlight, !snapshot.helperConflict else { return }
        if snapshot.enabled {
            do {
                try writeState(false)
                if snapshot.helperInstalled && !snapshot.helperRunning {
                    installHelper(recovering: true)
                } else {
                    refreshStatus()
                }
            } catch {
                showAlert(title: "Couldn’t save the setting", message: error.localizedDescription)
            }
            return
        }

        do {
            try writeState(true)
        } catch {
            showAlert(title: "Couldn’t save the setting", message: error.localizedDescription)
            return
        }

        if snapshot.helperRunning {
            refreshStatus()
            return
        }
        installHelper()
    }

    private func writeState(_ enabled: Bool) throws {
        try FileManager.default.createDirectory(
            at: AppConfig.supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try (enabled ? "1\n" : "0\n").write(to: AppConfig.statePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: AppConfig.statePath.path)
    }

    private func installHelper(recovering: Bool = false) {
        guard let helperURL = Bundle.main.url(forResource: "power-monitor", withExtension: "sh"),
              let installerURL = Bundle.main.url(forResource: "install-helper", withExtension: "sh"),
              let helperData = try? Data(contentsOf: helperURL),
              let installerData = try? Data(contentsOf: installerURL),
              Self.resourceHashMatches(helperData, named: "power-monitor"),
              Self.resourceHashMatches(installerData, named: "install-helper") else {
            try? writeState(false)
            showAlert(title: "App files could not be verified", message: "Replace Lid Awake with a fresh copy and try again.")
            refreshStatus()
            return
        }

        do {
            let daemon: [String: Any] = [
                "Label": AppConfig.label,
                "ProgramArguments": ["/bin/sh", AppConfig.helperPath, AppConfig.statePath.path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Background",
                "ThrottleInterval": 10,
                "StandardOutPath": "/var/log/app.lidawake.LidAwake.power-monitor.log",
                "StandardErrorPath": "/var/log/app.lidawake.LidAwake.power-monitor.log"
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: daemon, format: .xml, options: 0)
            actionInFlight = true
            rebuildMenu()

            runAsAdministrator(
                scriptData: installerData,
                arguments: [helperData.base64EncodedString(), plistData.base64EncodedString()]
            ) { [weak self] success, details in
                guard let self else { return }
                self.actionInFlight = false
                if !success {
                    if !recovering { try? self.writeState(false) }
                    self.showAlert(
                        title: recovering ? "Sleep setting couldn’t be restored" : "Background monitor wasn’t installed",
                        message: details.isEmpty
                            ? (recovering
                                ? "The monitor is stopped. Sign in as an administrator and try again."
                                : "The administrator request was cancelled. Lid Awake is off.")
                            : details
                    )
                }
                self.refreshStatus()
            }
        } catch {
            if !recovering { try? writeState(false) }
            showAlert(title: "Couldn’t prepare the background monitor", message: error.localizedDescription)
            refreshStatus()
        }
    }

    @objc private func removeHelper(_ sender: NSMenuItem) {
        guard !actionInFlight, !snapshot.helperConflict,
              let uninstallerURL = Bundle.main.url(forResource: "uninstall-helper", withExtension: "sh"),
              let uninstallerData = try? Data(contentsOf: uninstallerURL),
              Self.resourceHashMatches(uninstallerData, named: "uninstall-helper") else {
            showAlert(title: "App files could not be verified", message: "Replace Lid Awake with a fresh copy and try again.")
            return
        }
        do {
            try writeState(false)
        } catch {
            showAlert(
                title: "Couldn’t turn off before removal",
                message: "The background monitor is still installed. Lid Awake could not save the off state: \(error.localizedDescription)"
            )
            return
        }
        actionInFlight = true
        rebuildMenu()
        runAsAdministrator(scriptData: uninstallerData, arguments: []) { [weak self] success, details in
            guard let self else { return }
            self.actionInFlight = false
            if !success {
                self.showAlert(
                    title: "Background monitor wasn’t removed",
                    message: details.isEmpty ? "The administrator request was cancelled." : details
                )
            }
            self.refreshStatus()
        }
    }

    private func runAsAdministrator(
        scriptData: Data,
        arguments: [String],
        completion: @escaping (Bool, String) -> Void
    ) {
        let encodedScript = scriptData.base64EncodedString()
        let argumentList = arguments.map(Self.shellQuote).joined(separator: " ")
        let shellCommand = "printf '%s' \(Self.shellQuote(encodedScript)) | /usr/bin/base64 -D | /bin/sh -s -- \(argumentList)"
        let appleScript = "do shell script \"\(Self.escapeAppleScript(shellCommand))\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            var message = ""
            var success = false
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                success = process.terminationStatus == 0
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { completion(success, message) }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func resourceHashMatches(_ data: Data, named name: String) -> Bool {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == AppConfig.resourceHashes[name]
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
