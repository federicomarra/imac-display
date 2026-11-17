import Foundation
import Network

struct DiscoveredReceiver: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// Finds iMacs running the receiver app through Bonjour.
final class ReceiverBrowser {
    /// Called on the main thread.
    var onChange: (([DiscoveredReceiver]) -> Void)?

    private var browser: NWBrowser?

    func start() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: IMD.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            var receivers: [DiscoveredReceiver] = []
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var id = name
                if case let .bonjour(txt) = result.metadata, let value = txt["id"] {
                    id = value
                }
                // The same iMac shows up once per network interface.
                if seen.insert(id).inserted {
                    receivers.append(DiscoveredReceiver(id: id, name: name, endpoint: result.endpoint))
                }
            }
            receivers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self?.onChange?(receivers)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.browser?.cancel()
                self?.browser = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.start() }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }
}

/// Opens a connection to the iMac, trying the fastest kind of link first:
/// Thunderbolt Bridge / Ethernet, then any other interface (Wi-Fi).
enum Connector {
    static func connect(to endpoint: NWEndpoint, queue: DispatchQueue, completion: @escaping (NWConnection?) -> Void) {
        let attempts: [(NWInterface.InterfaceType?, TimeInterval)] = [
            (.wiredEthernet, 2.5),
            (.other, 2.0),
            (nil, 8.0),
        ]
        attempt(attempts[...], endpoint: endpoint, queue: queue, completion: completion)
    }

    private static func attempt(_ remaining: ArraySlice<(NWInterface.InterfaceType?, TimeInterval)>,
                                endpoint: NWEndpoint,
                                queue: DispatchQueue,
                                completion: @escaping (NWConnection?) -> Void) {
        guard let next = remaining.first else {
            completion(nil)
            return
        }
        let (interface, timeout) = next
        let rest = remaining.dropFirst()
        let connection = NWConnection(to: endpoint, using: NetworkParameters.tcp(requiredInterface: interface))
        var finished = false

        func finish(success: Bool) {
            guard !finished else { return }
            finished = true
            if success {
                connection.stateUpdateHandler = nil
                completion(connection)
            } else {
                connection.stateUpdateHandler = nil
                connection.cancel()
                attempt(rest, endpoint: endpoint, queue: queue, completion: completion)
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(success: true)
            case .failed, .cancelled:
                finish(success: false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(success: false)
        }
    }
}
