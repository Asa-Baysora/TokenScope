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
                    self.store.updateRuntimeHealth(.ollama) {
                        $0.collectorRunning = true
                        $0.state = $0.serverRunning ? .connected : .degraded
                        $0.lastError = nil
                    }
                    FileLog.log("proxy listening on \(port) → \(upstream)")
                case .failed(let err):
                    DispatchQueue.main.async {
                        self.store.proxyStatus = "proxy failed: \(err.localizedDescription)"
                        self.store.proxyHealthy = false
                    }
                    self.store.updateRuntimeHealth(.ollama) {
                        $0.collectorRunning = false
                        $0.state = .degraded
                        $0.lastError = "proxy listener failed"
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
            store.updateRuntimeHealth(.ollama) {
                $0.collectorRunning = false
                $0.state = .degraded
                $0.lastError = "proxy listener failed"
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
    private let requestScanner: HTTPRequestScanner
    private let identityRewriter = HTTPIdentityEncodingRewriter()
    private let queue = DispatchQueue(label: "tokenscope.relay")
    private var closed = false
    var onClose: ((Relay) -> Void)?

    init(client: NWConnection, upstreamPort: UInt16, store: UsageStore) {
        self.client = client
        self.upstream = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? 11434,
            using: .tcp)
        let responseScanner = ResponseScanner(
            onUpdate: { [weak store] st in store?.upsertLiveCall(st) },
            onFinal: { [weak store] st in store?.finishLiveCall(st) })
        self.scanner = responseScanner
        self.requestScanner = HTTPRequestScanner { request in
            responseScanner.enqueueRequest(request)
        }
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
                self.requestScanner.consume(data)
                var out = self.identityRewriter.consume(data)
                if complete { out.append(self.identityRewriter.flush()) }
                if out.isEmpty {
                    if complete { self.halfCloseUpstream() }
                    else { self.pumpClientToUpstream() }
                    return
                }
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

    static func == (a: Relay, b: Relay) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
