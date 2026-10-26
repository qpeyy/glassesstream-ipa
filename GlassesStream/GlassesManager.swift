import Foundation
import MWDATCore
import MWDATCamera

@MainActor
final class GlassesManager: ObservableObject {
    static let shared = GlassesManager()

    @Published var isConnected = false
    @Published var statusText = "Scanning..."

    private var session: DeviceSession?
    // Tokens must be retained or subscriptions are cancelled
    private var tokenBag = ListenerTokenBag()
    private var sessionTask: Task<Void, Never>?

    func start() {
        sessionTask = Task { await connect() }
    }

    private func connect() async {
        statusText = "Connecting to glasses..."
        let wearables = Wearables.shared
        let selector = AutoDeviceSelector(wearables: wearables)

        do {
            let session = try wearables.createSession(deviceSelector: selector)
            self.session = session
            try session.start()

            for await state in session.stateStream() {
                switch state {
                case .started:
                    isConnected = true
                    statusText = "Connected"
                    startStream(session: session)
                case .stopped:
                    isConnected = false
                    statusText = "Disconnected — retrying..."
                    tokenBag = ListenerTokenBag()
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

    private func startStream(session: DeviceSession) {
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .medium,
            frameRate: 24
        )
        do {
            guard let camera = try session.addCamera(config: config) else {
                statusText = "Camera not available"
                return
            }
            let stream = camera.stream

            let frameToken = stream.videoFramePublisher.listen { frame in
                guard let image = frame.makeUIImage(),
                      let jpeg = image.jpegData(compressionQuality: 0.7) else { return }
                StreamServer.shared.sendFrame(jpeg)
            }
            tokenBag.add(frameToken)

            stream.start()
        } catch {
            statusText = "Stream error: \(error.localizedDescription)"
        }
    }
}
