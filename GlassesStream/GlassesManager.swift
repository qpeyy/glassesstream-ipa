import Foundation
import UIKit
import MWDATCore
import MWDATCamera

@MainActor
final class GlassesManager: ObservableObject {
    static let shared = GlassesManager()
    nonisolated(unsafe) static var configureError: String?

    @Published var registrationState: RegistrationState = .unavailable
    @Published var hasActiveDevice = false
    @Published var isStreaming = false
    @Published var needsFirmwareUpdate = false
    @Published var logLines: [String] = []

    private var selector: AutoDeviceSelector?
    private var session: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private let sessionTokens = ListenerTokenBag()
    private let streamTokens = ListenerTokenBag()
    private var deviceTokens: [DeviceIdentifier: any AnyListenerToken] = [:]
    private var lastDeviceState: [String: String] = [:]
    private var monitorTasks: [Task<Void, Never>] = []
    private var retryTask: Task<Void, Never>?
    private var started = false

    private var sdkReady: Bool { Self.configureError == nil }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func addLog(_ message: String) {
        NSLog("[GlassesStream] %@", message)
        logLines.append("\(Self.timeFormat.string(from: Date())) \(message)")
        if logLines.count > 100 { logLines.removeFirst(logLines.count - 100) }
    }

    func start() {
        guard !started else { return }
        started = true

        // Touching Wearables.shared after a failed configure() can crash, so stop here.
        if let error = Self.configureError {
            addLog("Wearables.configure() FAILED: \(error)")
            return
        }

        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        self.selector = selector
        registrationState = Wearables.shared.registrationState
        addLog("Registration: \(registrationState.description)")

        monitorTasks.append(Task {
            for await state in Wearables.shared.registrationStateStream() {
                self.registrationState = state
                self.addLog("Registration: \(state.description)")
                self.evaluate()
            }
        })

        monitorTasks.append(Task {
            for await ids in Wearables.shared.devicesStream() {
                let names = ids.map { Wearables.shared.deviceForIdentifier($0)?.nameOrId() ?? $0 }
                self.addLog("Devices known to Meta AI: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
                self.monitorDevices(ids)
            }
        })

        monitorTasks.append(Task {
            for await id in selector.activeDeviceStream() {
                self.hasActiveDevice = id != nil
                self.addLog("Active device: \(id ?? "none")")
                self.evaluate()
            }
        })
    }

    // MARK: - Device state

    private func monitorDevices(_ ids: [DeviceIdentifier]) {
        let current = Set(ids)
        deviceTokens = deviceTokens.filter { current.contains($0.key) }
        for id in ids where deviceTokens[id] == nil {
            guard let device = Wearables.shared.deviceForIdentifier(id) else { continue }
            let name = device.nameOrId()
            deviceTokens[id] = device.addDeviceStateListener { [weak self] state in
                Task { @MainActor in self?.deviceStateChanged(name: name, state: state) }
            }
        }
    }

    private func deviceStateChanged(name: String, state: DeviceState) {
        let battery = state.batteryLevel.map { "\($0)%" } ?? "?"
        let line = "link=\(state.linkState) worn=\(state.donState) arms=\(state.hingeState) firmware=\(state.compatibility) battery=\(battery)"
        if lastDeviceState[name] != line {
            lastDeviceState[name] = line
            addLog("\(name): \(line)")
        }
        needsFirmwareUpdate = state.compatibility == .deviceUpdateRequired
        if state.compatibility == .sdkUpdateRequired {
            addLog("Glasses firmware is newer than this SDK supports (sdkUpdateRequired)")
        }
    }

    func openFirmwareUpdate() {
        Task {
            do {
                try await Wearables.shared.openFirmwareUpdate()
            } catch {
                addLog("openFirmwareUpdate error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Registration

    func register() {
        guard sdkReady else { return }
        addLog("Starting registration (opens Meta AI)...")
        Task {
            do {
                try await Wearables.shared.startRegistration()
            } catch {
                addLog("Registration error: \(error.localizedDescription)")
            }
        }
    }

    func unregister() {
        guard sdkReady else { return }
        addLog("Unregistering...")
        session?.stop()
        cleanupSession()
        Task {
            do {
                try await Wearables.shared.startUnregistration()
            } catch {
                addLog("Unregister error: \(error.localizedDescription)")
            }
        }
    }

    func handleURL(_ url: URL) {
        addLog("Opened via URL: \(url.absoluteString.prefix(100))")
        guard sdkReady,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else {
            addLog("Not a Meta AI callback, ignored")
            return
        }
        Task {
            do {
                // The callback variant also covers registration that Meta AI itself initiates.
                _ = try await Wearables.shared.handleUrl(url, onRegistrationRequest: { request in
                    Task { @MainActor in
                        let manager = GlassesManager.shared
                        manager.addLog("Meta AI initiated registration, continuing...")
                        do {
                            try await request.continueRegistration()
                            manager.addLog("Registration request continued")
                        } catch {
                            manager.addLog("continueRegistration error: \(error.localizedDescription)")
                        }
                    }
                })
                addLog("Meta AI callback handled")
            } catch {
                addLog("handleUrl error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Session

    func retry() {
        guard sdkReady else { return }
        addLog("Manual retry")
        session?.stop()
        cleanupSession()
        evaluate()
    }

    private func evaluate() {
        guard registrationState == .registered else { return }
        guard hasActiveDevice else {
            addLog("Registered. Waiting for glasses: wear them with arms open")
            return
        }
        guard session == nil else { return }
        startSession()
    }

    private func startSession() {
        guard let selector else { return }
        addLog("Creating session...")
        do throws(DeviceSessionError) {
            let newSession = try Wearables.shared.createSession(deviceSelector: selector)
            session = newSession
            newSession.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.sessionStateChanged(state) }
            }.store(in: sessionTokens)
            newSession.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.sessionErrorReceived(error) }
            }.store(in: sessionTokens)
            try newSession.start()
        } catch {
            sessionErrorReceived(error)
            cleanupSession()
            scheduleRetry()
        }
    }

    private func sessionErrorReceived(_ error: DeviceSessionError) {
        addLog("Session error: \(error.localizedDescription)")
        if error == .datAppOnTheGlassesUpdateRequired {
            addLog("Glasses-side app needs an update, opening Meta AI...")
            Task {
                do {
                    try await Wearables.shared.openDATGlassesAppUpdate()
                } catch {
                    addLog("openDATGlassesAppUpdate error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sessionStateChanged(_ state: DeviceSessionState) {
        addLog("Session: \(state.description)")
        switch state {
        case .started:
            Task { await startStreaming() }
        case .stopped:
            cleanupSession()
            scheduleRetry()
        default:
            break
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self.retryTask = nil
            self.evaluate()
        }
    }

    private func cleanupSession() {
        streamTokens.clear()
        camera = nil
        isStreaming = false
        sessionTokens.clear()
        session = nil
    }

    // MARK: - Stream

    private func startStreaming() async {
        guard let session, session.state == .started, camera == nil else { return }
        do {
            let status = try await Wearables.shared.checkPermissionStatus(.camera)
            addLog("Camera permission: \(status)")
            if status != .granted {
                addLog("Requesting camera permission (opens Meta AI)...")
                let result = try await Wearables.shared.requestPermission(.camera)
                addLog("Camera permission result: \(result)")
                guard result == .granted else { return }
            }
        } catch {
            addLog("Camera permission error: \(error.localizedDescription)")
            return
        }
        guard let current = self.session, current.state == .started, camera == nil else { return }
        beginStream(on: current)
    }

    private func beginStream(on session: DeviceSession) {
        let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 24)
        do {
            guard let newCamera = try session.addCamera(config: config) else {
                addLog("addCamera returned nil")
                return
            }
            camera = newCamera
            let stream = newCamera.stream
            stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.streamStateChanged(state) }
            }.store(in: streamTokens)
            stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.addLog("Stream error: \(error.localizedDescription)") }
            }.store(in: streamTokens)
            stream.videoFramePublisher.listen { frame in
                guard let image = frame.makeUIImage(),
                      let jpeg = image.jpegData(compressionQuality: 0.6) else { return }
                Task { @MainActor in StreamServer.shared.sendFrame(jpeg) }
            }.store(in: streamTokens)
            addLog("Starting camera stream...")
            stream.start()
        } catch {
            addLog("addCamera error: \(error.localizedDescription)")
        }
    }

    private func streamStateChanged(_ state: StreamState) {
        addLog("Stream: \(state)")
        isStreaming = state == .streaming
        if state == .paused {
            addLog("Stream paused: tap the side of the glasses to resume")
        }
        if state == .stopped {
            streamTokens.clear()
            camera?.stop()
            camera = nil
        }
    }
}
