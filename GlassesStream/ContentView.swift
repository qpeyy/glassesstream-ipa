import SwiftUI
import MWDATCore

struct ContentView: View {
    @StateObject private var glasses = GlassesManager.shared
    @StateObject private var server = StreamServer.shared
    @State private var wifiIP: String = "..."

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("GlassesStream")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.6))

                if glasses.registrationState == .registered {
                    Text("http://\(wifiIP):8080/stream")
                        .font(.system(.title3, design: .monospaced))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    Button(action: { glasses.register() }) {
                        Text("Connect to Meta AI")
                            .font(.headline)
                            .foregroundColor(.black)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .cornerRadius(12)
                    }
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(glasses.isConnected ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(glasses.statusText)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                if server.isRunning && glasses.isConnected {
                    Text("Live")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            refreshIP()
            glasses.start()
            server.start()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            refreshIP()
        }
    }

    private func refreshIP() {
        wifiIP = Self.getWiFiIP() ?? "No WiFi"
    }

    static func getWiFiIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(firstAddr) }
        var ptr = firstAddr
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET), flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0 {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: ptr.pointee.ifa_name)
                    if name.hasPrefix("en") {
                        return String(cString: hostname)
                    }
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return nil
    }
}
