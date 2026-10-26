import Foundation
import Combine

// Meta Wearables Device Access Toolkit SDK integration.
// Import the SDK module once SPM resolves it; stub types allow compilation
// without the physical glasses during CI.
#if canImport(MetaWearablesSDK)
import MetaWearablesSDK
#endif

final class GlassesManager: ObservableObject {
    static let shared = GlassesManager()

    @Published var isConnected = false
    @Published var statusText = "Scanning..."

    private var reconnectTimer: Timer?

#if canImport(MetaWearablesSDK)
    private var client: MetaWearablesClient?
    private var streamSession: MediaStreamSession?

    func start() {
        connect()
    }

    private func connect() {
        statusText = "Scanning for glasses..."
        client = MetaWearablesClient()
        client?.delegate = self
        client?.startDiscovery()
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }
#else
    // Stub for CI builds without the SDK hardware
    func start() {
        statusText = "SDK unavailable (simulator/CI)"
    }
#endif
}

#if canImport(MetaWearablesSDK)
extension GlassesManager: MetaWearablesClientDelegate {
    func client(_ client: MetaWearablesClient, didDiscover device: MetaWearablesDevice) {
        client.connect(to: device)
        statusText = "Connecting to \(device.name)..."
    }

    func client(_ client: MetaWearablesClient, didConnect device: MetaWearablesDevice) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.statusText = "Connected: \(device.name)"
        }
        startStreaming(device: device)
    }

    func client(_ client: MetaWearablesClient, didDisconnect device: MetaWearablesDevice, error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.statusText = "Disconnected — retrying…"
        }
        streamSession?.stop()
        streamSession = nil
        scheduleReconnect()
    }

    private func startStreaming(device: MetaWearablesDevice) {
        streamSession = device.startMediaStream(type: .camera) { [weak self] frame in
            guard let jpegData = frame.jpegData else { return }
            StreamServer.shared.sendFrame(jpegData)
        }
    }
}
#endif
