import Foundation
import Network

final class StreamServer: ObservableObject {
    static let shared = StreamServer()
    @Published var isRunning = false

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "mjpeg.server")

    func start() {
        let params = NWParameters.tcp
        guard let listener = try? NWListener(using: params, on: port) else { return }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.isRunning = state == .ready
            }
        }
        listener.start(queue: queue)
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        connections.append(conn)
        readRequest(conn)
    }

    private func readRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let data = data, let request = String(data: data, encoding: .utf8) else { return }
            if request.contains("GET /stream") {
                self?.sendMJPEGHeaders(conn)
            } else {
                self?.send404(conn)
            }
        }
    }

    private func sendMJPEGHeaders(_ conn: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        conn.send(content: headers.data(using: .utf8), completion: .idempotent)
    }

    private func send404(_ conn: NWConnection) {
        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed({ _ in conn.cancel() }))
    }

    func sendFrame(_ jpegData: Data) {
        let header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n"
        var payload = header.data(using: .utf8)!
        payload.append(jpegData)
        payload.append("\r\n".data(using: .utf8)!)

        connections = connections.filter { conn in
            switch conn.state {
            case .ready: return true
            default: return false
            }
        }
        for conn in connections {
            conn.send(content: payload, completion: .idempotent)
        }
    }
}
