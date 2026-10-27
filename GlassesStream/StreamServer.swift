import Foundation
import Network

@MainActor
final class StreamServer: ObservableObject {
    static let shared = StreamServer()
    @Published var isRunning = false
    @Published var viewerCount = 0

    private var listener: NWListener?
    private var viewers: [ObjectIdentifier: NWConnection] = [:]
    // Viewers with a frame still in flight are skipped so slow clients can't pile up memory.
    private var sending: Set<ObjectIdentifier> = []
    private let queue = DispatchQueue(label: "mjpeg.server")

    private static let indexPage = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>GlassesStream</title></head><body style="margin:0;background:#000;display:flex;\
    align-items:center;justify-content:center;height:100vh">
    <img src="/stream" style="max-width:100%;max-height:100vh"></body></html>
    """

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: 8080)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRunning = state == .ready
                    if case .failed(let error) = state {
                        GlassesManager.shared.addLog("HTTP server failed: \(error)")
                        self.listener?.cancel()
                        self.listener = nil
                    }
                }
            }
            listener.start(queue: queue)
        } catch {
            GlassesManager.shared.addLog("HTTP server could not start: \(error)")
        }
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(id) }
            default:
                break
            }
        }
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            Task { @MainActor in self?.route(firstLine, conn) }
        }
    }

    private func route(_ requestLine: String, _ conn: NWConnection) {
        if requestLine.hasPrefix("GET /stream") {
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                + "Cache-Control: no-cache, no-store\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
            let id = ObjectIdentifier(conn)
            conn.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if error == nil {
                        self.viewers[id] = conn
                        self.viewerCount = self.viewers.count
                    } else {
                        conn.cancel()
                    }
                }
            })
        } else if requestLine.hasPrefix("GET / ") {
            respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.indexPage.utf8))
        } else {
            respond(conn, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
        }
    }

    private func respond(_ conn: NWConnection, status: String, type: String, body: Data) {
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func drop(_ id: ObjectIdentifier) {
        viewers[id]?.cancel()
        viewers[id] = nil
        sending.remove(id)
        viewerCount = viewers.count
    }

    func sendFrame(_ jpegData: Data) {
        guard !viewers.isEmpty else { return }
        var payload = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n".utf8)
        payload.append(jpegData)
        payload.append(Data("\r\n".utf8))

        for (id, conn) in viewers where !sending.contains(id) {
            sending.insert(id)
            conn.send(content: payload, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.sending.remove(id)
                    if error != nil { self.drop(id) }
                }
            })
        }
    }
}
