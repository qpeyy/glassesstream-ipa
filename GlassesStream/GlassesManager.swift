import Foundation
import MWDATCore
import MWDATCamera

@MainActor
final class GlassesManager: ObservableObject {
    static let shared = GlassesManager()

    @Published var isConnected = false
    @Published var statusText = "Not registered"
    @Published var registrationState: RegistrationState = .available

    private var session: DeviceSession?
    private var tokens: [AnyListenerToken] = []
    private var registrationTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?

    func start() {
        let wearables = Wearables.shared
        registrationState = wearables.registrationState
        statusText = "Registration: \(wearables.registrationState)"

        registrationTask = Task {
            for await state in wearables.registrationStateStream() {
                registrationState = state
                statusText = "Registration: \(state)"
                if state == .registered {
                    sessionTask?.cancel()
                    sessionTask = Task { await connect() }
                }
            }
        }

        if wearables.registrationState == .registered {
            sessionTask = Task { await connect() }
        }
    }

    func register() {
        Task {
            do {
                try await Wearables.shared.startRegistration()
            } catch let error as RegistrationError {
                statusText = "Registration error: \(error.description)"
            } catch {
                statusText = "Registration error: \(error.localizedDescription)"
            }
        }
    }

    private func connect() async {
        let wearables = Wearables.shared
        let selector = AutoDeviceSelector(wearables: wearables)

        // Wait until a device is actually visible before creating a session
        statusText = "Waiting for glasses..."
        for await deviceId in selector.activeDeviceStream() {
            guard deviceId != nil else { continue }
            break
        }

        statusText = "Device found, connecting..."

        do {
            let session = try wearables.createSession(deviceSelector: selector)
            self.session = session

            do throws(DeviceSessionError) {
                try session.start()
            } catch {
                statusText = "Session start error: \(error)"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await connect()
                return
            }

            for await state in session.stateStream() {
                statusText = "Session: \(state)"
                switch state {
                case .started:
                    isConnected = true
                    startStream(session: session)
                case .stopped:
                    isConnected = false
                    tokens.removeAll()
                    statusText = "Disconnected — reconnecting..."
                    await connect()
                    return
                default:
                    break
                }
            }
        } catch {
            statusText = "createSession error: \(error)"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await connect()
        }
    }

    private func startStream(session: DeviceSession) {
        let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 24)
        do {
            guard let camera = try session.addCamera(config: config) else {
                statusText = "Camera unavailable"
                return
            }
            let stream = camera.stream
            let frameToken = stream.videoFramePublisher.listen { frame in
                guard let image = frame.makeUIImage(),
                      let jpeg = image.jpegData(compressionQuality: 0.7) else { return }
                Task { @MainActor in StreamServer.shared.sendFrame(jpeg) }
            }
            tokens.append(frameToken)
            stream.start()
            statusText = "Streaming"
        } catch {
            statusText = "Stream error: \(error)"
        }
    }
}
