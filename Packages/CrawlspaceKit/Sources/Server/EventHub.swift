import Foundation
import IOKit.pwr_mgt

/// One server-sent event: a name and a JSON payload.
struct ServerEvent: Sendable {
    var name: String
    var json: Data

    /// The event as it goes down the wire.
    var wireFormat: String {
        "event: \(name)\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
    }
}

/// Fans events out to every browser tab listening. A tab that disconnects simply stops receiving;
/// nothing waits on a slow one, because each listener keeps only its newest few events.
final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func subscribe() -> AsyncStream<ServerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ServerEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
        }
        lock.withLock { listeners[id] = continuation }
        return stream
    }

    func publish(_ name: String, _ value: some Encodable) {
        guard let json = try? encoder.encode(value) else { return }
        let event = ServerEvent(name: name, json: json)
        for continuation in lock.withLock({ Array(listeners.values) }) {
            continuation.yield(event)
        }
    }

    var listenerCount: Int { lock.withLock { listeners.count } }
}

/// Stops the Mac idle-sleeping while a crawl or Lighthouse run is going. The display may still
/// sleep. Held per reason, so a crawl finishing doesn't release a Lighthouse run's hold.
final class SleepGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var isActive = false

    func begin(reason: String) {
        lock.withLock {
            guard !isActive else { return }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                isActive = true
            }
        }
    }

    func end() {
        lock.withLock {
            guard isActive else { return }
            IOPMAssertionRelease(assertionID)
            isActive = false
        }
    }

    deinit {
        if isActive { IOPMAssertionRelease(assertionID) }
    }
}
