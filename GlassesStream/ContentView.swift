import SwiftUI
import MWDATCore

struct ContentView: View {
    @StateObject private var glasses = GlassesManager.shared
    @StateObject private var server = StreamServer.shared
    @State private var wifiIP: String = "..."

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("http://\(wifiIP):8080/stream")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                HStack(spacing: 14) {
                    statusDot("Registered", glasses.registrationState == .registered)
                    statusDot("Glasses", glasses.hasActiveDevice)
                    statusDot("Streaming", glasses.isStreaming)
                    statusDot("Server (\(server.viewerCount))", server.isRunning)
                }

                if glasses.needsFirmwareUpdate {
                    Button("Update glasses firmware") { glasses.openFirmwareUpdate() }
                        .font(.subheadline)
                        .foregroundColor(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.yellow)
                        .cornerRadius(10)
                }

                if glasses.registrationState != .registered {
                    Button("Connect to Meta AI") { glasses.register() }
                        .font(.headline)
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .cornerRadius(12)
                } else {
                    HStack(spacing: 12) {
                        Button("Retry") { glasses.retry() }
                        Button("Re-register") { glasses.unregister() }
                    }
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .buttonStyle(.bordered)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(glasses.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.75))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(8)
                    .onChange(of: glasses.logLines.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
                .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            refreshIP()
            server.start()
            glasses.start()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            refreshIP()
        }
    }

    private func statusDot(_ label: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundColor(.white.opacity(0.7))
        }
    }

    private func refreshIP() {
        wifiIP = Self.getWiFiIP() ?? "no-wifi"
    }

    static func getWiFiIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if name.hasPrefix("en"), fallback == nil { fallback = ip }
        }
        return fallback
    }
}
