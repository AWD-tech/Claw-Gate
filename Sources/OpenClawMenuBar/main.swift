import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

enum GatewayState: String {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case stopping
    case failed

    var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .stopping: return "minus.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .disconnected: return "circle"
        }
    }

    var color: NSColor {
        switch self {
        case .connected: return .systemGreen
        case .connecting, .reconnecting: return .systemOrange
        case .stopping: return .systemYellow
        case .failed: return .systemRed
        case .disconnected: return .secondaryLabelColor
        }
    }

    var isTransitioning: Bool {
        self == .connecting || self == .reconnecting || self == .stopping
    }
}

enum HealthLevel: Equatable {
    case unknown
    case checking
    case ok
    case warning
    case failed

    var color: NSColor {
        switch self {
        case .unknown:
            return .secondaryLabelColor
        case .checking:
            return .systemOrange
        case .ok:
            return .systemGreen
        case .warning:
            return .systemYellow
        case .failed:
            return .systemRed
        }
    }
}

struct HealthCheckItem: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let level: HealthLevel
    let issueLines: [String]
    let sourceCommand: String?
    let suggestedCommand: String?

    init(
        id: String,
        label: String,
        detail: String,
        level: HealthLevel,
        issueLines: [String] = [],
        sourceCommand: String? = nil,
        suggestedCommand: String? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.level = level
        self.issueLines = issueLines
        self.sourceCommand = sourceCommand
        self.suggestedCommand = suggestedCommand
    }
}

private struct CommandResult {
    let status: Int32
    let output: String
    let timedOut: Bool
}

@MainActor
final class GatewayController: ObservableObject {
    @Published private(set) var state: GatewayState = .disconnected
    @Published private(set) var logs: [String] = []
    @Published private(set) var healthItems: [HealthCheckItem] = GatewayController.defaultHealthItems
    @Published private(set) var isRefreshingHealthDashboard = false
    @Published private(set) var isRunningDoctor = false

    private let openClawPath = GatewayController.resolveOpenClawPath()
    private let commandArguments = ["--no-color", "gateway", "run", "--force"]
    private var process: Process?
    private var healthTimer: Timer?
    private var healthCheckRunning = false
    private var startGatewayAfterHealthFailure = false
    private var restartRequested = false
    private var hasReportedHealthy = false
    private var connectionDeadline: Date?
    private var lastHealthFailureLogAt: Date?

    private static let defaultHealthItems: [HealthCheckItem] = [
        HealthCheckItem(id: "gateway", label: "Gateway", detail: "Not checked", level: .unknown),
        HealthCheckItem(id: "channels", label: "Channels", detail: "Not checked", level: .unknown),
        HealthCheckItem(id: "api", label: "API", detail: "Not checked", level: .unknown),
        HealthCheckItem(id: "memory", label: "Memory", detail: "Not checked", level: .unknown),
        HealthCheckItem(id: "context", label: "Context", detail: "Not checked", level: .unknown),
        HealthCheckItem(id: "usage", label: "Usage", detail: "Not checked", level: .unknown)
    ]

    private static func resolveOpenClawPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let configuredPath = environment["OPENCLAW_BIN"], FileManager.default.isExecutableFile(atPath: configuredPath) {
            return configuredPath
        }

        let candidates = [
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            "/usr/bin/openclaw"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        return "/usr/bin/env"
    }

    private var openClawBaseArguments: [String] {
        openClawPath == "/usr/bin/env" ? ["openclaw"] : []
    }

    var logText: String {
        logs.joined(separator: "\n")
    }

    init() {
        appendLog("Ready.")
        runHealthCheck()
    }

    func connect() {
        restartRequested = false
        guard process?.isRunning != true else {
            appendLog("Gateway process is already running.")
            return
        }

        state = .connecting
        hasReportedHealthy = false
        beginConnectionWindow()
        appendLog("Checking for an existing gateway before starting a new one.")
        runHealthCheck(startGatewayIfUnhealthy: true)
    }

    func disconnect() {
        restartRequested = false
        if process?.isRunning == true {
            stopGateway(nextState: .stopping)
        } else {
            runGatewayServiceCommand("stop", transition: .stopping) { [weak self] ok in
                guard let self else { return }
                self.stopHealthPolling()
                self.hasReportedHealthy = false
                self.state = ok ? .disconnected : .failed
                self.appendLog(ok ? "Gateway service stopped." : "Gateway service stop failed.")
            }
        }
    }

    func reconnect() {
        restartRequested = true
        appendLog("Reconnecting gateway.")

        if process?.isRunning == true {
            stopGateway(nextState: .reconnecting)
        } else {
            restartRequested = false
            runGatewayServiceCommand("restart", transition: .reconnecting) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.hasReportedHealthy = false
                    self.beginConnectionWindow()
                    self.appendLog("Gateway service restarted; checking health.")
                    self.runHealthCheck()
                } else {
                    self.state = .failed
                    self.appendLog("Gateway service restart failed.")
                }
            }
        }
    }

    func refreshHealthDashboard() {
        guard !isRefreshingHealthDashboard else { return }

        isRefreshingHealthDashboard = true
        healthItems = healthItems.map {
            HealthCheckItem(id: $0.id, label: $0.label, detail: "Checking", level: .checking)
        }

        let openClawPath = self.openClawPath
        let baseArguments = self.openClawBaseArguments
        let environment = processEnvironment()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = Self.runCommandSync(
                executablePath: openClawPath,
                arguments: baseArguments + ["--no-color", "status", "--json", "--timeout", "5000"],
                environment: environment,
                timeout: 8
            )
            let channels = Self.runCommandSync(
                executablePath: openClawPath,
                arguments: baseArguments + ["--no-color", "channels", "status", "--json", "--timeout", "10000"],
                environment: environment,
                timeout: 12
            )
            let channelConfig = Self.runCommandSync(
                executablePath: openClawPath,
                arguments: baseArguments + ["--no-color", "config", "get", "channels", "--json"],
                environment: environment,
                timeout: 8
            )
            let models = Self.runCommandSync(
                executablePath: openClawPath,
                arguments: baseArguments + ["--no-color", "models", "status", "--json", "--check"],
                environment: environment,
                timeout: 12
            )
            let memory = Self.runCommandSync(
                executablePath: openClawPath,
                arguments: baseArguments + ["--no-color", "memory", "status", "--json"],
                environment: environment,
                timeout: 12
            )

            Task { @MainActor in
                self?.applyHealthDashboard(status: status, channels: channels, channelConfig: channelConfig, models: models, memory: memory)
            }
        }
    }

    func refreshAfterWake() {
        appendLog("Wake detected; refreshing gateway status.")
        runHealthCheck()
        refreshHealthDashboard()
    }

    /// On-demand gateway probe for the idle status timer and panel-open, so
    /// the indicator tracks the gateway even when it is started or stopped
    /// outside Claw Gate (LaunchAgent, CLI, or the OpenClaw app). Safe to
    /// call while connected — runHealthCheck() no-ops if one is in flight.
    func checkHealthNow() {
        runHealthCheck()
    }

    func runDoctor() {
        guard !isRunningDoctor else { return }

        isRunningDoctor = true
        appendLog("Running doctor checks.")

        let openClawPath = self.openClawPath
        let baseArguments = self.openClawBaseArguments
        let environment = processEnvironment()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.runCommandSync(
                executablePath: openClawPath,
                arguments: baseArguments + ["--no-color", "doctor", "--lint", "--json", "--severity-min", "warning"],
                environment: environment,
                timeout: 20
            )

            Task { @MainActor in
                self?.applyDoctorResult(result)
            }
        }
    }

    func showHealthDetails(_ item: HealthCheckItem) {
        appendLog("\(item.label): \(item.detail).")
        if let sourceCommand = item.sourceCommand {
            appendLog("Source: \(sourceCommand)")
        }
        if item.issueLines.isEmpty {
            appendLog("\(item.label): no extra issue details reported.")
        } else {
            for issue in item.issueLines.prefix(8) {
                appendLog("\(item.label) issue: \(issue)")
            }
            if item.issueLines.count > 8 {
                appendLog("\(item.label): \(item.issueLines.count - 8) more issue\(item.issueLines.count - 8 == 1 ? "" : "s") hidden.")
            }
        }
        if let suggestedCommand = item.suggestedCommand {
            appendLog("Try: \(suggestedCommand)")
        }
    }

    func openOpenClawTUI() {
        let arguments = openClawBaseArguments + ["tui"]
        let command = ([openClawPath] + arguments).map(Self.shellQuoted).joined(separator: " ")
        let script = """
        tell application "Terminal"
            activate
            do script "\(Self.appleScriptEscaped(command))"
        end tell
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        do {
            try task.run()
            appendLog("Opened OpenClaw TUI.")
        } catch {
            appendLog("Failed to open OpenClaw TUI: \(error.localizedDescription)")
        }
    }

    func terminateImmediately() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let runningProcess = process, runningProcess.isRunning {
            runningProcess.terminate()
            kill(runningProcess.processIdentifier, SIGKILL)
        }
    }

    private func startGateway(as nextState: GatewayState) {
        hasReportedHealthy = false
        state = nextState
        beginConnectionWindow()
        let arguments = openClawBaseArguments + commandArguments
        appendLog("Starting: \(openClawPath) \(arguments.joined(separator: " "))")

        let gatewayProcess = Process()
        gatewayProcess.executableURL = URL(fileURLWithPath: openClawPath)
        gatewayProcess.arguments = arguments
        gatewayProcess.environment = processEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        gatewayProcess.standardOutput = outputPipe
        gatewayProcess.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveOutput(from: handle)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveOutput(from: handle)
        }

        gatewayProcess.terminationHandler = { [weak self] completedProcess in
            Task { @MainActor in
                self?.handleGatewayExit(completedProcess)
            }
        }

        do {
            try gatewayProcess.run()
            process = gatewayProcess
            startHealthPolling()
            runHealthCheck()
        } catch {
            state = .failed
            appendLog("Failed to start gateway: \(error.localizedDescription)")
            closeHandlers(outputPipe, errorPipe)
        }
    }

    private func stopGateway(nextState: GatewayState) {
        stopHealthPolling()

        guard let runningProcess = process, runningProcess.isRunning else {
            process = nil
            state = restartRequested ? .reconnecting : .disconnected
            if restartRequested {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.startGateway(as: .reconnecting)
                }
            } else {
                appendLog("Gateway is not running.")
            }
            return
        }

        state = nextState
        appendLog("Stopping gateway.")
        runningProcess.terminate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak runningProcess] in
            guard let self, let runningProcess, runningProcess.isRunning else { return }
            self.appendLog("Gateway did not exit after terminate; forcing stop.")
            kill(runningProcess.processIdentifier, SIGKILL)
        }
    }

    private func handleGatewayExit(_ completedProcess: Process) {
        guard completedProcess === process else { return }

        closeCurrentProcessHandlers()
        process = nil
        hasReportedHealthy = false

        let exitCode = completedProcess.terminationStatus
        if restartRequested {
            appendLog("Gateway exited with code \(exitCode); starting again.")
            stopHealthPolling()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.startGateway(as: .reconnecting)
            }
            return
        }

        stopHealthPolling()

        if state == .stopping {
            state = .disconnected
            appendLog("Gateway stopped.")
        } else if exitCode == 0 {
            state = .disconnected
            appendLog("Gateway exited.")
        } else {
            state = .failed
            appendLog("Gateway exited with code \(exitCode).")
        }
    }

    private nonisolated func receiveOutput(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        Task { @MainActor [weak self] in
            self?.appendOutputChunk(text)
        }
    }

    private func appendOutputChunk(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                appendLog(line)
            }
        }
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(line)")
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    private func runGatewayServiceCommand(_ command: String, transition: GatewayState, completion: @escaping (Bool) -> Void) {
        state = transition
        let arguments = openClawBaseArguments + ["--no-color", "gateway", command]
        appendLog("Running: \(openClawPath) \(arguments.joined(separator: " "))")

        let openClawPath = self.openClawPath
        let baseArguments = self.openClawBaseArguments
        let environment = processEnvironment()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let serviceProcess = Process()
            serviceProcess.executableURL = URL(fileURLWithPath: openClawPath)
            serviceProcess.arguments = baseArguments + ["--no-color", "gateway", command]
            serviceProcess.environment = environment

            let pipe = Pipe()
            serviceProcess.standardOutput = pipe
            serviceProcess.standardError = pipe

            var ok = false
            var output = ""
            do {
                try serviceProcess.run()
                let deadline = Date().addingTimeInterval(20.0)
                while serviceProcess.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if serviceProcess.isRunning {
                    serviceProcess.terminate()
                    Thread.sleep(forTimeInterval: 0.2)
                    if serviceProcess.isRunning {
                        kill(serviceProcess.processIdentifier, SIGKILL)
                    }
                    output = "Gateway \(command) timed out."
                } else {
                    ok = serviceProcess.terminationStatus == 0
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if output.isEmpty {
                    output = String(data: data, encoding: .utf8) ?? ""
                }
            } catch {
                output = error.localizedDescription
            }

            Task { @MainActor in
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.appendOutputChunk(output)
                }
                completion(ok)
            }
        }
    }

    private func startHealthPolling() {
        if healthTimer != nil { return }

        healthTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runHealthCheck()
            }
        }
    }

    private func stopHealthPolling() {
        healthTimer?.invalidate()
        healthTimer = nil
        healthCheckRunning = false
    }

    private func beginConnectionWindow() {
        connectionDeadline = Date().addingTimeInterval(45.0)
        lastHealthFailureLogAt = nil
        startHealthPolling()
    }

    private func runHealthCheck(startGatewayIfUnhealthy: Bool = false) {
        if healthCheckRunning {
            if startGatewayIfUnhealthy {
                startGatewayAfterHealthFailure = true
            }
            return
        }

        if startGatewayIfUnhealthy {
            startGatewayAfterHealthFailure = true
        }
        healthCheckRunning = true

        let openClawPath = self.openClawPath
        let baseArguments = self.openClawBaseArguments
        let environment = processEnvironment()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let healthProcess = Process()
            healthProcess.executableURL = URL(fileURLWithPath: openClawPath)
            healthProcess.arguments = baseArguments + ["--no-color", "gateway", "health"]
            healthProcess.environment = environment

            let pipe = Pipe()
            healthProcess.standardOutput = pipe
            healthProcess.standardError = pipe

            var ok = false
            var output = ""
            do {
                try healthProcess.run()
                let deadline = Date().addingTimeInterval(12.0)
                while healthProcess.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if healthProcess.isRunning {
                    healthProcess.terminate()
                    output = "Health check timed out."
                } else {
                    ok = healthProcess.terminationStatus == 0
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if output.isEmpty {
                    output = String(data: data, encoding: .utf8) ?? ""
                }
            } catch {
                output = error.localizedDescription
            }

            Task { @MainActor in
                self?.applyHealthResult(ok: ok, output: output)
            }
        }
    }

    private func applyHealthResult(ok: Bool, output: String) {
        healthCheckRunning = false
        let shouldStartGateway = startGatewayAfterHealthFailure
        startGatewayAfterHealthFailure = false

        if ok {
            if state == .connecting || state == .reconnecting || state == .failed || state == .disconnected {
                state = .connected
            }
            connectionDeadline = nil
            lastHealthFailureLogAt = nil
            startHealthPolling()
            if !hasReportedHealthy {
                hasReportedHealthy = true
                appendLog("Gateway health check passed.")
            }
        } else if shouldStartGateway, process?.isRunning != true {
            appendLog("No healthy gateway answered; starting the gateway service.")
            runGatewayServiceCommand("start", transition: state == .reconnecting ? .reconnecting : .connecting) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.beginConnectionWindow()
                    self.appendLog("Gateway service started; checking health.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.runHealthCheck()
                    }
                } else {
                    self.state = .failed
                    self.appendLog("Gateway service start failed.")
                }
            }
        } else if process?.isRunning == true {
            if state == .connected {
                state = .connecting
                hasReportedHealthy = false
                appendLog("Gateway health check failed while process is running.")
            }
        } else if state == .connecting || state == .reconnecting {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldLogFailure = lastHealthFailureLogAt == nil || Date().timeIntervalSince(lastHealthFailureLogAt ?? .distantPast) > 10
            if shouldLogFailure {
                lastHealthFailureLogAt = Date()
                appendLog(trimmed.isEmpty ? "Gateway is not healthy yet; retrying." : "Gateway is not healthy yet; retrying: \(trimmed)")
            }

            if let connectionDeadline, Date() >= connectionDeadline {
                self.connectionDeadline = nil
                stopHealthPolling()
                hasReportedHealthy = false
                state = .failed
                appendLog("Gateway did not become healthy within 45 seconds.")
            }
        } else if state == .connected {
            state = .disconnected
            hasReportedHealthy = false
            connectionDeadline = nil
            lastHealthFailureLogAt = nil
            stopHealthPolling()
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendLog("Gateway health check failed: \(trimmed)")
            }
        }
    }

    private func applyHealthDashboard(
        status: CommandResult,
        channels: CommandResult,
        channelConfig: CommandResult,
        models: CommandResult,
        memory: CommandResult
    ) {
        isRefreshingHealthDashboard = false
        healthItems = [gatewayHealthItem(from: status)]
            + channelHealthItems(from: channels, fallbackConfig: channelConfig)
            + [
                apiHealthItem(from: models),
                memoryHealthItem(from: memory),
                contextHealthItem(from: status),
                usageHealthItem(from: status)
            ]
    }

    private func applyDoctorResult(_ result: CommandResult) {
        isRunningDoctor = false

        guard !result.timedOut else {
            appendLog("Doctor timed out.")
            return
        }

        guard let root = parseJSONObject(result.output) as? [String: Any] else {
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            appendLog(trimmed.isEmpty ? "Doctor completed with exit code \(result.status)." : "Doctor: \(trimmed)")
            return
        }

        let ok = (root["ok"] as? Bool) ?? (result.status == 0)
        let findings = (root["findings"] as? [[String: Any]]) ?? (root["issues"] as? [[String: Any]] ?? [])
        if ok || findings.isEmpty {
            appendLog("Doctor found no warnings.")
            return
        }

        appendLog("Doctor found \(findings.count) warning\(findings.count == 1 ? "" : "s").")
        for issue in findings.prefix(6) {
            if let message = issue["message"] as? String, !message.isEmpty {
                appendLog("Doctor: \(message)")
            } else if let title = issue["title"] as? String, !title.isEmpty {
                appendLog("Doctor: \(title)")
            }
        }
        if findings.count > 6 {
            appendLog("Doctor: \(findings.count - 6) more warning\(findings.count - 6 == 1 ? "" : "s") hidden.")
        }
    }

    private func gatewayHealthItem(from result: CommandResult) -> HealthCheckItem {
        guard !result.timedOut else {
            return HealthCheckItem(id: "gateway", label: "Gateway", detail: "Timed out", level: .failed, issueLines: ["Gateway status check timed out."], sourceCommand: "openclaw status --json --timeout 5000", suggestedCommand: "openclaw doctor")
        }

        guard let root = parseJSONObject(result.output) as? [String: Any],
              let gateway = root["gateway"] as? [String: Any] else {
            return HealthCheckItem(id: "gateway", label: "Gateway", detail: result.status == 0 ? "OK" : "Unavailable", level: result.status == 0 ? .ok : .failed, issueLines: result.status == 0 ? [] : [result.output.trimmingCharacters(in: .whitespacesAndNewlines)], sourceCommand: "openclaw status --json --timeout 5000", suggestedCommand: "openclaw gateway health")
        }

        let reachable = gateway["reachable"] as? Bool ?? false
        let latency = gateway["connectLatencyMs"] as? Int
        if reachable {
            let detail = latency.map { "OK \($0)ms" } ?? "Reachable"
            return HealthCheckItem(id: "gateway", label: "Gateway", detail: detail, level: .ok, sourceCommand: "openclaw status --json --timeout 5000")
        }

        let error = gateway["error"] as? String ?? "Gateway did not respond."
        return HealthCheckItem(id: "gateway", label: "Gateway", detail: "Unreachable", level: .failed, issueLines: [error], sourceCommand: "openclaw status --json --timeout 5000", suggestedCommand: "openclaw gateway health")
    }

    private func channelHealthItems(from result: CommandResult, fallbackConfig: CommandResult) -> [HealthCheckItem] {
        guard !result.timedOut else {
            return channelHealthItemsFromConfig(fallbackConfig, fallbackDetail: "Status timed out")
        }

        guard let root = parseJSONObject(result.output) as? [String: Any] else {
            return channelHealthItemsFromConfig(fallbackConfig, fallbackDetail: result.status == 0 ? "Configured" : "Status unavailable")
        }

        let channels = root["channels"] as? [String: Any] ?? [:]
        let channelAccounts = root["channelAccounts"] as? [String: Any] ?? [:]
        let labels = root["channelLabels"] as? [String: String] ?? [:]
        let orderedIds = (root["channelOrder"] as? [String] ?? []) + channels.keys.sorted()
        var seenIds = Set<String>()
        var items: [HealthCheckItem] = []

        for rawId in orderedIds where !rawId.isEmpty && !seenIds.contains(rawId) {
            seenIds.insert(rawId)
            let channel = channels[rawId] as? [String: Any] ?? [:]
            let accounts = channelAccounts[rawId] as? [[String: Any]] ?? []
            let label = labels[rawId] ?? displayName(forChannelId: rawId)
            let configured = channel["configured"] as? Bool ?? accounts.contains { $0["configured"] as? Bool == true }
            let running = channel["running"] as? Bool ?? accounts.contains { $0["running"] as? Bool == true }
            let connected = accounts.contains { $0["connected"] as? Bool == true }
            let enabled = accounts.isEmpty || accounts.contains { $0["enabled"] as? Bool != false }
            let lastError = (channel["lastError"] as? String) ?? accounts.compactMap { $0["lastError"] as? String }.first

            if let lastError, !lastError.isEmpty {
                items.append(HealthCheckItem(id: "channel-\(rawId)", label: label, detail: "Error", level: .failed, issueLines: [lastError], sourceCommand: "openclaw channels status --json --timeout 10000", suggestedCommand: "openclaw channels status --channel \(rawId) --probe"))
            } else if connected {
                items.append(HealthCheckItem(id: "channel-\(rawId)", label: label, detail: "Connected", level: .ok, sourceCommand: "openclaw channels status --json --timeout 10000"))
            } else if configured && running {
                items.append(HealthCheckItem(id: "channel-\(rawId)", label: label, detail: "Running", level: .ok, sourceCommand: "openclaw channels status --json --timeout 10000"))
            } else if configured && enabled {
                items.append(HealthCheckItem(id: "channel-\(rawId)", label: label, detail: "Configured", level: .warning, issueLines: ["Channel is configured but not confirmed connected."], sourceCommand: "openclaw channels status --json --timeout 10000", suggestedCommand: "openclaw channels status --channel \(rawId) --probe"))
            } else if enabled {
                items.append(HealthCheckItem(id: "channel-\(rawId)", label: label, detail: "Not configured", level: .failed, issueLines: ["Channel is enabled but missing required configuration."], sourceCommand: "openclaw channels status --json --timeout 10000", suggestedCommand: "openclaw channels add"))
            }
        }

        if !items.isEmpty {
            return items
        }

        return channelHealthItemsFromConfig(fallbackConfig, fallbackDetail: "Configured")
    }

    private func channelHealthItemsFromConfig(_ result: CommandResult, fallbackDetail: String) -> [HealthCheckItem] {
        guard !result.timedOut,
              let channels = parseJSONObject(result.output) as? [String: Any] else {
            return [HealthCheckItem(id: "channels", label: "Channels", detail: fallbackDetail, level: .warning, issueLines: ["Could not read channel status or config."], sourceCommand: "openclaw config get channels --json", suggestedCommand: "openclaw channels status --probe")]
        }

        let enabledChannels = channels
            .compactMap { id, value -> (String, [String: Any])? in
                guard let config = value as? [String: Any],
                      config["enabled"] as? Bool != false else { return nil }
                return (id, config)
            }
            .sorted { $0.0 < $1.0 }

        if enabledChannels.isEmpty {
            return [HealthCheckItem(id: "channels", label: "Channels", detail: "None enabled", level: .warning, issueLines: ["No enabled OpenClaw messaging channels were found."], sourceCommand: "openclaw config get channels --json", suggestedCommand: "openclaw channels add")]
        }

        return enabledChannels.map { id, _ in
            HealthCheckItem(id: "channel-\(id)", label: displayName(forChannelId: id), detail: fallbackDetail, level: .warning, issueLines: ["Channel came from config fallback; live status was not available."], sourceCommand: "openclaw config get channels --json", suggestedCommand: "openclaw channels status --channel \(id) --probe")
        }
    }

    private func displayName(forChannelId id: String) -> String {
        let knownNames: [String: String] = [
            "bluebubbles": "BlueBubbles",
            "imessage": "iMessage",
            "msteams": "Microsoft Teams",
            "nextcloud-talk": "Nextcloud Talk",
            "qqbot": "QQ Bot",
            "zalouser": "Zalo User"
        ]
        if let knownName = knownNames[id] {
            return knownName
        }

        return id
            .split { $0 == "-" || $0 == "_" }
            .map { part in
                let lowercased = part.lowercased()
                return lowercased.prefix(1).uppercased() + String(lowercased.dropFirst())
            }
            .joined(separator: " ")
    }

    private func apiHealthItem(from result: CommandResult) -> HealthCheckItem {
        guard !result.timedOut else {
            return HealthCheckItem(id: "api", label: "API", detail: "Timed out", level: .failed, issueLines: ["Model/auth status check timed out."], sourceCommand: "openclaw models status --json --check", suggestedCommand: "openclaw models status --check")
        }

        guard let root = parseJSONObject(result.output) as? [String: Any],
              let auth = root["auth"] as? [String: Any] else {
            return HealthCheckItem(id: "api", label: "API", detail: result.status == 0 ? "OK" : "Check failed", level: result.status == 0 ? .ok : .failed, issueLines: result.status == 0 ? [] : [result.output.trimmingCharacters(in: .whitespacesAndNewlines)], sourceCommand: "openclaw models status --json --check", suggestedCommand: "openclaw models status --check")
        }

        let missingProviders = auth["missingProvidersInUse"] as? [Any] ?? []
        let routes = auth["runtimeAuthRoutes"] as? [[String: Any]] ?? []
        let unusableRoutes = routes.filter { ($0["status"] as? String) != "usable" }

        if missingProviders.isEmpty && unusableRoutes.isEmpty {
            let provider = routes.compactMap { $0["provider"] as? String }.first ?? "Configured"
            return HealthCheckItem(id: "api", label: "API", detail: "\(provider) usable", level: .ok, sourceCommand: "openclaw models status --json --check")
        }
        if !missingProviders.isEmpty {
            return HealthCheckItem(id: "api", label: "API", detail: "\(missingProviders.count) missing", level: .failed, issueLines: missingProviders.map { "\($0)" }, sourceCommand: "openclaw models status --json --check", suggestedCommand: "openclaw models status --check")
        }

        let routeIssues = unusableRoutes.map { route in
            let provider = route["provider"] as? String ?? "provider"
            let status = route["status"] as? String ?? "unusable"
            return "\(provider): \(status)"
        }
        return HealthCheckItem(id: "api", label: "API", detail: "\(unusableRoutes.count) unusable", level: .warning, issueLines: routeIssues, sourceCommand: "openclaw models status --json --check", suggestedCommand: "openclaw models status --check")
    }

    private func memoryHealthItem(from result: CommandResult) -> HealthCheckItem {
        guard !result.timedOut else {
            return HealthCheckItem(id: "memory", label: "Memory", detail: "Timed out", level: .warning, issueLines: ["Memory status check timed out."], sourceCommand: "openclaw memory status --json", suggestedCommand: "openclaw memory status --deep")
        }

        guard let entries = parseJSONObject(result.output) as? [[String: Any]], let first = entries.first else {
            return HealthCheckItem(id: "memory", label: "Memory", detail: result.status == 0 ? "OK" : "Check failed", level: result.status == 0 ? .ok : .warning, issueLines: result.status == 0 ? [] : [result.output.trimmingCharacters(in: .whitespacesAndNewlines)], sourceCommand: "openclaw memory status --json", suggestedCommand: "openclaw memory status --deep")
        }

        let status = first["status"] as? [String: Any]
        let scan = first["scan"] as? [String: Any]
        let audit = first["audit"] as? [String: Any]
        let dirty = status?["dirty"] as? Bool ?? false
        let issueLines = issueDescriptions(from: (scan?["issues"] as? [Any] ?? []) + (audit?["issues"] as? [Any] ?? []))

        if dirty {
            return HealthCheckItem(id: "memory", label: "Memory", detail: "Dirty state", level: .warning, issueLines: ["Memory index has dirty state and may need refresh."] + issueLines, sourceCommand: "openclaw memory status --json", suggestedCommand: "openclaw memory index --force")
        }
        if !issueLines.isEmpty {
            return HealthCheckItem(id: "memory", label: "Memory", detail: "\(issueLines.count) issue\(issueLines.count == 1 ? "" : "s")", level: .warning, issueLines: issueLines, sourceCommand: "openclaw memory status --json", suggestedCommand: "openclaw memory status --fix")
        }

        return HealthCheckItem(id: "memory", label: "Memory", detail: "Index clean", level: .ok, sourceCommand: "openclaw memory status --json")
    }

    // "Context" row: active conversation sessions, mirroring OpenClaw's
    // "N sessions · 24h". Built from the status JSON already fetched above.
    private func contextHealthItem(from result: CommandResult) -> HealthCheckItem {
        guard !result.timedOut,
              let root = parseJSONObject(result.output) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any] else {
            return HealthCheckItem(id: "context", label: "Context", detail: "Unknown", level: .unknown, sourceCommand: "openclaw status --json --timeout 5000", suggestedCommand: "openclaw sessions --json")
        }

        let total = (sessions["count"] as? NSNumber)?.intValue ?? 0
        let recent = sessions["recent"] as? [[String: Any]] ?? []
        let dayMs = 24.0 * 60.0 * 60.0 * 1000.0
        let active24h = recent.filter { (($0["age"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude) < dayMs }.count

        let detail: String
        if active24h > 0 {
            detail = "\(active24h) active · 24h"
        } else {
            detail = "\(total) session\(total == 1 ? "" : "s")"
        }
        let issues = recent.prefix(6).compactMap { session -> String? in
            guard let key = session["key"] as? String else { return nil }
            let model = session["model"] as? String ?? "?"
            return "\(key) — \(model)"
        }
        return HealthCheckItem(id: "context", label: "Context", detail: detail, level: total > 0 ? .ok : .unknown, issueLines: issues, sourceCommand: "openclaw sessions --json")
    }

    // "Usage" row: context-window budget of the most recent session
    // (percentUsed / remainingTokens). NOTE: the provider weekly quota shown
    // in the OpenClaw app ("Codex 0% left · Week") is not exposed by any
    // OpenClaw CLI command, so this shows context usage instead.
    private func usageHealthItem(from result: CommandResult) -> HealthCheckItem {
        guard !result.timedOut,
              let root = parseJSONObject(result.output) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any],
              let recent = sessions["recent"] as? [[String: Any]],
              let top = recent.first else {
            return HealthCheckItem(id: "usage", label: "Usage", detail: "Unknown", level: .unknown, sourceCommand: "openclaw status --json --timeout 5000")
        }

        let percent = (top["percentUsed"] as? NSNumber)?.intValue
        let remaining = (top["remainingTokens"] as? NSNumber)?.intValue
        let model = top["model"] as? String

        var parts: [String] = []
        if let percent { parts.append("\(percent)% ctx") }
        if let remaining { parts.append("\(Self.formatTokens(remaining)) left") }
        let detail = parts.isEmpty ? (model ?? "OK") : parts.joined(separator: " · ")
        let level: HealthLevel = (percent ?? 0) >= 90 ? .warning : .ok
        let issues = [
            "Context-window usage of the most recent session\(model.map { " (\($0))" } ?? "").",
            "Provider weekly quota (e.g. plan % left) is not exposed by the OpenClaw CLI; only the OpenClaw app shows it."
        ]
        return HealthCheckItem(id: "usage", label: "Usage", detail: detail, level: level, issueLines: issues, sourceCommand: "openclaw status --json --timeout 5000")
    }

    private static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1000)k" }
        return "\(value)"
    }

    private func issueDescriptions(from issues: [Any]) -> [String] {
        issues.compactMap { issue in
            if let text = issue as? String {
                return text
            }
            if let dict = issue as? [String: Any] {
                if let message = dict["message"] as? String {
                    return message
                }
                if let reason = dict["reason"] as? String {
                    return reason
                }
                if let path = dict["path"] as? String {
                    return path
                }
                return dict.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
            }
            return "\(issue)"
        }
    }

    private func parseJSONObject(_ output: String) -> Any? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private nonisolated static func runCommandSync(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> CommandResult {
        let commandProcess = Process()
        commandProcess.executableURL = URL(fileURLWithPath: executablePath)
        commandProcess.arguments = arguments
        commandProcess.environment = environment

        let pipe = Pipe()
        commandProcess.standardOutput = pipe
        commandProcess.standardError = pipe

        do {
            try commandProcess.run()
        } catch {
            return CommandResult(status: 127, output: error.localizedDescription, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while commandProcess.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        var timedOut = false
        if commandProcess.isRunning {
            timedOut = true
            commandProcess.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if commandProcess.isRunning {
                kill(commandProcess.processIdentifier, SIGKILL)
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let status = timedOut ? Int32(124) : commandProcess.terminationStatus
        return CommandResult(status: status, output: output, timedOut: timedOut)
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let currentPath = environment["PATH"], !currentPath.isEmpty {
            environment["PATH"] = "\(defaultPath):\(currentPath)"
        } else {
            environment["PATH"] = defaultPath
        }
        return environment
    }

    private func closeCurrentProcessHandlers() {
        guard let currentProcess = process else { return }
        if let stdout = currentProcess.standardOutput as? Pipe {
            stdout.fileHandleForReading.readabilityHandler = nil
        }
        if let stderr = currentProcess.standardError as? Pipe {
            stderr.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func closeHandlers(_ pipes: Pipe...) {
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }
}

@MainActor
final class PanelLayout: ObservableObject {
    static let width: CGFloat = 430
    static let collapsedHeight: CGFloat = 164
    static let expandedHeight: CGFloat = 408

    @Published var showsLogs = false

    var size: NSSize {
        NSSize(width: Self.width, height: showsLogs ? Self.expandedHeight : Self.collapsedHeight)
    }
}

// Locked-in design values (formerly tuned via temporary sliders).
private enum GlassDesign {
    static let buttonCornerRadius: CGFloat = 9
    static let panelGlass: Double = 0.66
}

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GlassDesign.buttonCornerRadius, style: .continuous)
        let label = configuration.label
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .contentShape(shape)

        Group {
            if #available(macOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: shape)
            } else {
                label
                    .background(shape.fill(.quaternary))
                    .overlay(shape.stroke(.separator, lineWidth: 0.75))
            }
        }
        .opacity(configuration.isPressed ? 0.7 : 1)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

struct PopoverView: View {
    @ObservedObject var controller: GatewayController
    @ObservedObject var layout: PanelLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: controller.state.symbolName)
                    .foregroundStyle(Color(nsColor: controller.state.color))
                    .font(.system(size: 18, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Claw Gate")
                        .font(.headline)
                    Text(controller.state.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    controller.connect()
                } label: {
                    Label("Connect", systemImage: "power")
                }
                .disabled(controller.state == .connected || controller.state.isTransitioning)

                Button {
                    controller.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "stop.fill")
                }
                .disabled(controller.state == .disconnected || controller.state == .stopping)

                Button {
                    controller.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .disabled(controller.state == .reconnecting || controller.state == .stopping)
            }
            .buttonStyle(GlassButtonStyle())

            Divider()

            Button {
                layout.showsLogs.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(layout.showsLogs ? "Hide Logs" : "Show More")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: layout.showsLogs ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if layout.showsLogs {
                HealthDashboardView(controller: controller)

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(controller.logText.isEmpty ? "No logs yet." : controller.logText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                            .padding(10)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .frame(height: 108)
                    // Scroll to the newest log only when the log view first
                    // appears (panel opened / logs expanded). Do NOT follow on
                    // every new line — that yanked the user away while reading.
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, layout.showsLogs ? -4 : -6)
        }
        .padding(14)
        .frame(width: PanelLayout.width, height: layout.size.height, alignment: .topLeading)
    }
}

struct HealthDashboardView: View {
    @ObservedObject var controller: GatewayController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Health")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    controller.refreshHealthDashboard()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(controller.isRefreshingHealthDashboard)

                Button {
                    controller.openOpenClawTUI()
                } label: {
                    Label("Open TUI", systemImage: "terminal")
                        .labelStyle(.titleAndIcon)
                }

                Button {
                    controller.runDoctor()
                } label: {
                    Label("Run Doctor", systemImage: "wrench.and.screwdriver")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(controller.isRunningDoctor)
            }
            .buttonStyle(GlassButtonStyle())
            .controlSize(.small)

            // Two-column grid packs the health rows side by side so all of
            // them fit without scrolling (6 rows -> 3 rows of 2). Spacers
            // above and below center the grid vertically in its space, so the
            // gap to the buttons above and the log box below stays equal.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14, alignment: .leading),
                        GridItem(.flexible(), spacing: 14, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(controller.healthItems) { item in
                        HealthRowView(item: item) {
                            controller.showHealthDetails(item)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: 104)
        }
    }
}

struct HealthRowView: View {
    let item: HealthCheckItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: item.level.color))
                    .frame(width: 8, height: 8)

                Text(item.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.level == .warning || item.level == .failed {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: 16)
    }
}

struct PanelChrome<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        if #available(macOS 26.0, *) {
            // Apple's real Liquid Glass: GPU refraction, lensing, specular
            // highlights — the genuine article, not a gradient fake.
            content.glassEffect(glassStyle, in: shape)
        } else {
            content
                .background(.regularMaterial)
                .clipShape(shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }

    // Locked at glass 0.66: .regular material with a subtle white tint for
    // that bright milk-glass finish.
    @available(macOS 26.0, *)
    private var glassStyle: Glass {
        .regular.tint(.white.opacity(GlassDesign.panelGlass * 0.18))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = GatewayController()
    private let panelLayout = PanelLayout()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private weak var attachedButton: NSStatusBarButton?
    private var resizeAnimationTimer: Timer?
    private var suppressStatusToggleUntil: Date?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var wakeObserver: Any?
    private var screensWakeObserver: Any?
    private var statusRefreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        controller.$state
            .sink { [weak self] newState in
                self?.updateStatusItem(for: newState)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updateStatusItem(for: self.controller.state)
                }
            }
            .store(in: &cancellables)

        panelLayout.$showsLogs
            .dropFirst()
            .sink { [weak self] showsLogs in
                guard let self else { return }
                if showsLogs {
                    self.controller.refreshHealthDashboard()
                }
                self.resizePanelForCurrentLayout(animated: true)
            }
            .store(in: &cancellables)

        installWakeObservers()
        startStatusRefreshTimer()
        updateStatusItem(for: controller.state)
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusRefreshTimer?.invalidate()
        removeWakeObservers()
        controller.terminateImmediately()
        closePanel()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let suppressStatusToggleUntil, Date() < suppressStatusToggleUntil {
            self.suppressStatusToggleUntil = nil
            return
        }

        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel(attachedTo: button)
        }
    }

    private func showPanel(attachedTo button: NSStatusBarButton) {
        attachedButton = button
        let panel = makePanelIfNeeded()
        // Probe immediately on open so the indicator is fresh, not stale.
        controller.checkHealthNow()
        updateStatusItem(for: controller.state)
        if panelLayout.showsLogs {
            controller.refreshHealthDashboard()
        }
        let frame = panelFrame(size: panelLayout.size, attachedTo: button, fixedTopY: nil)
        panel.setFrame(frame, display: true, animate: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        installEventMonitors()

        DispatchQueue.main.async { [weak self, weak button, weak panel] in
            guard let self, let button, let panel, panel.isVisible else { return }
            let frame = self.panelFrame(size: self.panelLayout.size, attachedTo: button, fixedTopY: nil)
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    private func resizePanelForCurrentLayout(animated: Bool) {
        guard let panel, panel.isVisible, let attachedButton else { return }
        let fixedTopY = panel.frame.maxY
        let targetFrame = panelFrame(size: panelLayout.size, attachedTo: attachedButton, fixedTopY: fixedTopY)
        if animated {
            animatePanel(panel, to: targetFrame)
        } else {
            panel.setFrame(targetFrame, display: true, animate: false)
        }
    }

    private func panelFrame(size panelSize: NSSize, attachedTo button: NSStatusBarButton, fixedTopY: CGFloat?) -> NSRect {
        let anchorFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let screen = button.window?.screen ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = screen?.visibleFrame ?? screenFrame
        let verticalGap: CGFloat = 6
        let inset: CGFloat = 8

        var x = anchorFrame.midX - panelSize.width / 2
        x = max(screenFrame.minX + inset, min(x, screenFrame.maxX - panelSize.width - inset))

        let hasUsableAnchor = !anchorFrame.isEmpty && screenFrame.intersects(anchorFrame)
        let desiredTop = fixedTopY ?? (hasUsableAnchor ? anchorFrame.minY - verticalGap : visibleFrame.maxY - inset)
        let maxY = screenFrame.maxY - panelSize.height - inset
        let minY = screenFrame.minY + inset
        var y = desiredTop - panelSize.height
        y = max(minY, min(y, maxY))

        return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }

    private func animatePanel(_ panel: NSPanel, to targetFrame: NSRect) {
        resizeAnimationTimer?.invalidate()

        let startFrame = panel.frame
        let duration: TimeInterval = 0.16
        let startDate = Date()

        resizeAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak panel] timer in
            guard let panel else {
                timer.invalidate()
                return
            }

            let rawProgress = min(1.0, Date().timeIntervalSince(startDate) / duration)
            let progress = CGFloat(1 - pow(1 - rawProgress, 3))
            let width = startFrame.width + (targetFrame.width - startFrame.width) * progress
            let height = startFrame.height + (targetFrame.height - startFrame.height) * progress
            let x = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * progress
            let topY = startFrame.maxY
            let y = topY - height

            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: false)

            if rawProgress >= 1.0 {
                panel.setFrame(targetFrame, display: true, animate: false)
                timer.invalidate()
            }
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelLayout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        let hostingController = NSHostingController(
            rootView: PanelChrome {
                PopoverView(controller: controller, layout: panelLayout)
            }
        )
        hostingController.view.frame = NSRect(origin: .zero, size: panelLayout.size)
        hostingController.view.autoresizingMask = [.width, .height]
        panel.contentViewController = hostingController

        self.panel = panel
        return panel
    }


    private func closePanel() {
        resizeAnimationTimer?.invalidate()
        resizeAnimationTimer = nil
        panel?.orderOut(nil)
        removeEventMonitors()
    }

    private func installEventMonitors() {
        removeEventMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closePanel()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown, self.isEventInStatusButton(event) {
                self.suppressNextStatusToggle()
                self.closePanel()
                return event
            }
            if event.window == self.panel {
                return event
            }
            self.closePanel()
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if self.isPointInStatusButton(event.locationInWindow) {
                    self.suppressNextStatusToggle()
                    self.closePanel()
                    return
                }
                self.closePanel()
            }
        }
    }

    private func installWakeObservers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWakeEvent()
            }
        }

        screensWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWakeEvent()
            }
        }
    }

    private func removeWakeObservers() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let screensWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensWakeObserver)
            self.screensWakeObserver = nil
        }
    }

    private func startStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Re-probe so externally started/stopped gateways are picked
                // up even when Claw Gate is idle (was only re-rendering before).
                self.controller.checkHealthNow()
                self.updateStatusItem(for: self.controller.state)
            }
        }
    }

    private func handleWakeEvent() {
        updateStatusItem(for: controller.state)
        controller.refreshAfterWake()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.updateStatusItem(for: self.controller.state)
        }
    }

    private func suppressNextStatusToggle() {
        suppressStatusToggleUntil = Date().addingTimeInterval(0.5)
    }

    private func isEventInStatusButton(_ event: NSEvent) -> Bool {
        let screenPoint: NSPoint
        if let eventWindow = event.window {
            screenPoint = eventWindow.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            screenPoint = event.locationInWindow
        }
        return isPointInStatusButton(screenPoint)
    }

    private func isPointInStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem?.button, let window = button.window else {
            return false
        }

        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -4, dy: -4)
        return buttonFrame.contains(screenPoint)
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func updateStatusItem(for state: GatewayState) {
        guard let button = statusItem?.button else { return }

        button.image = statusIconImage(for: state)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Claw Gate: \(state.title)"
        button.contentTintColor = nil
        button.needsDisplay = true
    }

    private func statusIconImage(for state: GatewayState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        // Same state -> color mapping the old circle used: disconnected = a
        // muted gray claw (idle), every other state fills the claw with its
        // status color (green connected, orange connecting/reconnecting,
        // yellow stopping, red failed).
        let color = (state == .disconnected) ? NSColor.secondaryLabelColor : state.color
        color.setFill()
        // Three overlapping pieces (palm + two pincers) filled separately so
        // they union solidly regardless of sub-path winding.
        for piece in clawPieces() {
            piece.fill()
        }

        image.isTemplate = false
        image.accessibilityDescription = state.title
        return image
    }

    // Stylized lobster crusher claw, pointing up inside the 18x18 box: a fat
    // rounded palm at the bottom that splits into two hooked pincer fingers
    // (the right one chunkier — the crusher) with an open "mouth" notch
    // between them. One closed path so it fills or strokes cleanly.
    // Lobster crusher claw inside the 18x18 box: a round palm at lower-left
    // with two tapered pincer fingers that hook toward each other, leaving an
    // open "mouth" between them. Returned as three pieces filled separately.
    private func clawPieces() -> [NSBezierPath] {
        let palm = NSBezierPath(ovalIn: NSRect(x: 1.6, y: 2.4, width: 8.8, height: 9.0))

        // Lower (fixed) finger: thick base, tapered tip hooking up.
        let lower = NSBezierPath()
        lower.move(to: NSPoint(x: 7.8, y: 3.8))
        lower.curve(to: NSPoint(x: 15.8, y: 10.8),
                    controlPoint1: NSPoint(x: 13.0, y: 3.4),
                    controlPoint2: NSPoint(x: 16.0, y: 7.0))
        lower.curve(to: NSPoint(x: 9.4, y: 6.2),
                    controlPoint1: NSPoint(x: 14.4, y: 9.6),
                    controlPoint2: NSPoint(x: 12.2, y: 7.0))
        lower.close()

        // Upper (movable) finger: tapered tip hooking right toward the lower
        // tip, so the two form a grabbing pincer.
        let upper = NSBezierPath()
        upper.move(to: NSPoint(x: 5.2, y: 10.2))
        upper.curve(to: NSPoint(x: 13.2, y: 14.8),
                    controlPoint1: NSPoint(x: 6.0, y: 13.4),
                    controlPoint2: NSPoint(x: 10.2, y: 15.0))
        upper.curve(to: NSPoint(x: 9.0, y: 9.6),
                    controlPoint1: NSPoint(x: 11.6, y: 12.6),
                    controlPoint2: NSPoint(x: 10.4, y: 10.8))
        upper.close()

        return [palm, lower, upper]
    }
}

private var retainedDelegate: AppDelegate?

@main
enum OpenClawMenuBarMain {
    static func main() {
        retainedDelegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = retainedDelegate
        app.run()
    }
}
