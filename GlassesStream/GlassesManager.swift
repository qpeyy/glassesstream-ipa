import Foundation
import MWDATCore
import MWDATCamera

@MainActor
final class GlassesManager: ObservableObject {
    static let shared = GlassesManager()

    @Published var isConnected = false
    @Published var statusText = "Scanning..."

    private var session: DeviceSession?
    private var tokens: [AnyListenerToken] = []
    private var sessionTask: Task<Void, Never>?

    func start() {
        sessionTask = Task { await connect() }
    }

    private func connect() async {
        statusText = "Connecting..."
        let wearables = Wearables.shared
        let selector = AutoDeviceSelector(wearables: wearables)

        // Log active device before attempting session
        let active = await selector.activeDevice
        statusText = "Active device: \(active ?? "nil")"
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        do {
            let session = try wearables.createSession(deviceSelector: selector)
            self.session = session

            do throws(DeviceSessionError) {
                try session.start()
            } catch {
                statusText = "start() threw: \(error)"
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await connect()
                return
            }

            for await state in session.stateStream() {
                statusText = "Session state: \(state)"
                switch state {
                case .started:
                    isConnected = true
                    startStream(session: session)
                case .stopped:
                    isConnected = false
                    statusText = "Stopped — retrying in 5s"
                    tokens.removeAll()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await connect()
                    return
                default:
                    break
                }
            }
        } catch {
            statusText = "createSession threw: \(error) | type: \(type(of: error))"
            try? await Task.sleep(nanoseconds: 10_000_000_000)
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
                Task { @MainActor in
                    StreamServer.shared.sendFrame(jpeg)
                }
            }
            tokens.append(frameToken)

            stream.start()
        } catch {
            statusText = "Stream error: \(error.localizedDescription)"
        }
    }
}
