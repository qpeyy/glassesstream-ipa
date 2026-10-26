import Foundation
import MWDATCore
import MWDATCamera

@MainActor
final class GlassesManager: ObservableObject {
    static let shared = GlassesManager()

    @Published var isConnected = false
    @Published var statusText = "Scanning..."

    private var session: DeviceSession?
    private var streamTask: Task<Void, Never>?

    func start() {
        Task { await connect() }
    }

    private func connect() async {
        statusText = "Requesting camera permission..."
        let permStatus = await Wearables.shared.checkPermissionStatus(.camera)
        if permStatus != .granted {
            let granted = await Wearables.shared.requestPermission(.camera)
            guard granted else {
                statusText = "Camera permission denied"
                return
            }
        }

        statusText = "Connecting to glasses..."
        let selector = AutoDeviceSelector()
        do {
            let session = try await Wearables.shared.createSession(deviceSelector: selector)
            self.session = session
            try await session.start()

            for await state in session.stateStream() {
                switch state {
                case .started:
                    isConnected = true
                    statusText = "Connected"
                    await startStream(session: session)
                case .stopped:
                    isConnected = false
                    statusText = "Disconnected — retrying..."
                    streamTask?.cancel()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await connect()
                    return
                default:
                    break
                }
            }
        } catch {
            statusText = "Error: \(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await connect()
        }
    }

    private func startStream(session: DeviceSession) async {
        let config = StreamConfiguration(codec: .h264, resolution: .medium, frameRate: 24)
        do {
            let camera = try await session.addCamera(config: config)
            let stream = camera.stream
            try await stream.start()
            isConnected = true

            streamTask = Task {
                for await frame in stream.videoFrames {
                    if let jpeg = frame.jpegData {
                        StreamServer.shared.sendFrame(jpeg)
                    }
                }
            }
        } catch {
            statusText = "Stream error: \(error.localizedDescription)"
        }
    }
}
