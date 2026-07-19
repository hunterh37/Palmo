import XCTest
import Network

/// End-to-end delivery of a chosen reply into a session's local Palmo
/// channel, against a real localhost HTTP server spun up per test.
final class ClaudeReplySenderTests: XCTestCase {

    /// Minimal one-shot HTTP server capturing the request head + body.
    private final class StubChannel: @unchecked Sendable {
        let listener: NWListener
        private(set) var port: Int = 0
        private(set) var received: String = ""
        private let lock = NSLock()
        private let status: Int

        init(status: Int) throws {
            self.status = status
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global())
                self?.handle(conn)
            }
            listener.start(queue: .global())
            guard ready.wait(timeout: .now() + 5) == .success,
                  let p = listener.port?.rawValue else {
                throw XCTSkip("could not bind a localhost listener")
            }
            port = Int(p)
        }

        private func handle(_ conn: NWConnection) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                if let data, let text = String(data: data, encoding: .utf8) {
                    self.lock.lock(); self.received += text; self.lock.unlock()
                }
                // Keep reading until the headers AND full body have arrived.
                if err == nil && !done && !self.requestComplete {
                    self.handle(conn)
                    return
                }
                let reply = "HTTP/1.1 \(self.status) X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: reply.data(using: .utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }

        /// True once the buffered request contains its declared body length.
        private var requestComplete: Bool {
            let req = request
            guard let headerEnd = req.range(of: "\r\n\r\n") else { return false }
            let lengthLine = req.lowercased()
                .components(separatedBy: "\r\n")
                .first { $0.hasPrefix("content-length:") }
            let declared = Int(lengthLine?.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            return req[headerEnd.upperBound...].utf8.count >= declared
        }

        var request: String { lock.lock(); defer { lock.unlock() }; return received }
        func stop() { listener.cancel() }
    }

    func testSendPostsTextWithSessionRouting() async throws {
        let server = try StubChannel(status: 200)
        defer { server.stop() }
        let sender = ClaudeReplySender()
        let ok = try await sender.send(text: "Yes, go ahead",
                                       sessionID: "sess-42", port: server.port)
        XCTAssertTrue(ok)
        let req = server.request
        XCTAssertTrue(req.hasPrefix("POST "), "should POST to the channel")
        XCTAssertTrue(req.contains("X-Sender: palmo_app"))
        XCTAssertTrue(req.contains("X-Session: sess-42"))
        XCTAssertTrue(req.contains("Yes, go ahead"))
    }

    func testMissingPortThrowsNoPort() async {
        do {
            try await ClaudeReplySender().send(text: "hi", sessionID: "s", port: nil)
            XCTFail("expected noPort")
        } catch let e as ClaudeReplySender.SendError {
            guard case .noPort = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertNotNil(e.errorDescription)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRejectedRequestThrowsBadStatus() async throws {
        let server = try StubChannel(status: 403)
        defer { server.stop() }
        do {
            try await ClaudeReplySender().send(text: "hi", sessionID: "s",
                                               port: server.port)
            XCTFail("expected badStatus")
        } catch let e as ClaudeReplySender.SendError {
            guard case .badStatus(let code) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(code, 403)
        }
    }
}
