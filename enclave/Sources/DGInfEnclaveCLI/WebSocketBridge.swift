/// WebSocket bridge: stdin/stdout relay with Apple-attested TLS client cert.
///
/// The Rust provider spawns this process. It connects to the coordinator
/// using URLSession (which presents the ACME managed profile cert), and
/// relays WebSocket frames between stdin/stdout and the coordinator.
///
/// Protocol:
///   stdin  → one JSON message per line → sent as WebSocket text frame
///   stdout ← one JSON message per line ← received WebSocket text frame
///   stderr ← log messages
///
/// Usage:
///   dginf-enclave tls-bridge --url wss://coordinator/ws/provider

import Foundation

private func log(_ msg: String) {
    let line = "bridge: \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

func runWebSocketBridge(coordinatorURL: String, socketPath: String) {
    guard let url = URL(string: coordinatorURL) else {
        log("invalid URL: \(coordinatorURL)")
        exit(1)
    }

    let delegate = TLSDelegate()
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    let ws = session.webSocketTask(with: url)

    log("connecting to \(coordinatorURL)")
    ws.resume()

    // Verify connection
    let connectSem = DispatchSemaphore(value: 0)
    var connected = false
    ws.sendPing { error in
        if let error = error {
            log("connection failed: \(error.localizedDescription)")
        } else {
            log("connected")
            connected = true
        }
        connectSem.signal()
    }
    connectSem.wait()

    guard connected else {
        exit(1)
    }

    // Start reading from coordinator (WebSocket → stdout)
    startReceiveLoop(ws: ws)

    // Read from stdin (provider → WebSocket)
    startStdinLoop(ws: ws)
}

/// Read WebSocket messages from coordinator, write to stdout (one JSON per line).
private func startReceiveLoop(ws: URLSessionWebSocketTask) {
    func receive() {
        ws.receive { result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    // Write the message as a single line to stdout
                    let line = text.replacingOccurrences(of: "\n", with: "") + "\n"
                    if let data = line.data(using: .utf8) {
                        FileHandle.standardOutput.write(data)
                    }
                case .data(let data):
                    // Binary frame — base64 encode it
                    let b64 = data.base64EncodedString()
                    let line = "{\"_binary\":\"\(b64)\"}\n"
                    if let data = line.data(using: .utf8) {
                        FileHandle.standardOutput.write(data)
                    }
                @unknown default:
                    break
                }
                receive() // continue
            case .failure(let error):
                log("receive error: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
    receive()
}

/// Read lines from stdin, send as WebSocket text frames to coordinator.
private func startStdinLoop(ws: URLSessionWebSocketTask) {
    DispatchQueue.global(qos: .userInitiated).async {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }

            let sem = DispatchSemaphore(value: 0)
            ws.send(.string(line)) { error in
                if let error = error {
                    log("send error: \(error.localizedDescription)")
                }
                sem.signal()
            }
            sem.wait()
        }
        // stdin closed — provider process exited
        log("stdin closed, shutting down")
        ws.cancel(with: .goingAway, reason: nil)
        exit(0)
    }

    // Keep the main thread alive
    RunLoop.current.run()
}

/// TLS delegate — lets macOS present the ACME managed profile cert.
class TLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            log("client cert requested — using system identity")
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
