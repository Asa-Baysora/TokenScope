import Foundation
import Network

/// Transparent TCP relay: 127.0.0.1:<proxyPort> → 127.0.0.1:<upstreamPort>.
/// Bytes pass through untouched except that request Accept-Encoding headers are
/// forced to identity so responses stay scannable. A ResponseScanner taps the
/// response direction to extract live token usage.
final class OllamaProxy {
    private let store: UsageStore
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tokenscope.proxy")
    private var relays = Set<Relay>()

    init(store: UsageStore) { self.store = store }

    func start() {
        let port = store.proxyPort
        let upstream = store.upstreamPort
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    DispatchQueue.main.async {
                        self.store.proxyStatus = "proxy :\(port) → :\(upstream)"
                        self.store.proxyHealthy = true
                    }
                    FileLog.log("proxy listening on \(port) → \(upstream)")
                case .failed(let err):
                    DispatchQueue.main.async {
                        self.store.proxyStatus = "proxy failed: \(err.localizedDescription)"
                        self.store.proxyHealthy = false
                    }
                    FileLog.log("proxy failed: \(err)")
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            DispatchQueue.main.async {
                self.store.proxyStatus = "proxy failed: \(error.localizedDescription)"
                self.store.proxyHealthy = false
            }
            FileLog.log("proxy start error: \(error)")
        }
    }

    private func accept(_ client: NWConnection) {
        let relay = Relay(client: client, upstreamPort: store.upstreamPort, store: store)
        relays.insert(relay)
        relay.onClose = { [weak self] r in
            self?.queue.async { self?.relays.remove(r) }
        }
        relay.start()
    }
}

final class Relay: Hashable {
    private let client: NWConnection
    private let upstream: NWConnection
    private let scanner: ResponseScanner
    private let queue = DispatchQueue(label: "tokenscope.relay")
    private var closed = false
    var onClose: ((Relay) -> Void)?

    init(client: NWConnection, upstreamPort: UInt16, store: UsageStore) {
        self.client = client
        self.upstream = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? 11434,
            using: .tcp)
        self.scanner = ResponseScanner(
            onUpdate: { [weak store] st in store?.upsertLiveCall(st) },
            onFinal: { [weak store] st in store?.finishLiveCall(st) })
    }

    func start() {
        client.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.close() }
        }
        upstream.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.close() }
        }
        client.start(queue: queue)
        upstream.start(queue: queue)
        pumpClientToUpstream()
        pumpUpstreamToClient()
    }

    private func pumpClientToUpstream() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                let out = Self.forceIdentityEncoding(data)
                self.upstream.send(content: out, completion: .contentProcessed { [weak self] err in
                    guard let self, !self.closed else { return }
                    if err != nil {
                        self.close()
                    } else if complete {
                        self.halfCloseUpstream()
                    } else {
                        self.pumpClientToUpstream()
                    }
                })
            } else if error != nil {
                self.close()
            } else if complete {
                self.halfCloseUpstream()
            } else {
                self.pumpClientToUpstream()
            }
        }
    }

    private func halfCloseUpstream() {
        upstream.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    private func pumpUpstreamToClient() {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.scanner.consume(data)
                self.client.send(content: data, completion: .contentProcessed { [weak self] err in
                    guard let self, !self.closed else { return }
                    if err != nil || complete {
                        self.close()
                    } else {
                        self.pumpUpstreamToClient()
                    }
                })
            } else if complete || error != nil {
                self.close()
            } else {
                self.pumpUpstreamToClient()
            }
        }
    }

    private func close() {
        if closed { return }
        closed = true
        scanner.connectionClosed()
        client.cancel()
        upstream.cancel()
        onClose?(self)
    }

    /// Rewrites Accept-Encoding to identity inside request headers so the upstream
    /// never gzips responses. Bodies are JSON and can't contain this header string,
    /// so a plain text replace on the byte stream is safe.
    private static func forceIdentityEncoding(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8), s.contains("Accept-Encoding") else { return data }
        let replaced = s.replacingOccurrences(
            of: "Accept-Encoding:[^\r\n]*",
            with: "Accept-Encoding: identity",
            options: [.regularExpression, .caseInsensitive])
        return Data(replaced.utf8)
    }

    static func == (a: Relay, b: Relay) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
