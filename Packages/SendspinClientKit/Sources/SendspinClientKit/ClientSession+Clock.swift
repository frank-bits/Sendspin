import Foundation

// Clock synchronization (messaging.md, Clock Synchronization).
// Adapted from sendspin-mac's Client/SourceSession.swift (see UPSTREAM.md).

extension ClientSession {
    /// A server timestamp on this device's clock (`ServerClock.nowMicros()`, host time in µs).
    public func localTime(fromServer serverTime: Int64) -> Int64 {
        filter.clientTime(fromServer: serverTime)
    }

    /// A time on this device's clock as a server timestamp.
    public func serverTime(fromLocal localTime: Int64) -> Int64 {
        filter.serverTime(fromClient: localTime)
    }

    /// Bursts of 8 exchanges, each waiting for its reply, keeping the one with the smallest
    /// error: back to back until the filter converges, then one starting every 9 s, since
    /// bursts MUST start no more than 10 s apart. A re-handshake cuts a burst short; the filter
    /// itself carries over. A server that doesn't answer before the next burst is due can't
    /// keep bursts within 10 s, so the connection closes.
    func startTimeSync() {
        timeSync = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                let started = clock.now
                await self.syncBurst()
                let next = await self.converged ? started + .seconds(9) : clock.now + .milliseconds(100)
                try? await Task.sleep(until: next, clock: clock)
            }
        }
    }

    private func syncBurst() async {
        var best: (measurement: Int64, maxError: Int64, at: Int64)?
        let startUs = ServerClock.nowMicros()
        for _ in 0..<8 {
            guard !rehandshaking else { return }
            let t1 = ServerClock.nowMicros()
            guard t1 < startUs + 8_000_000 else { break }
            timeExchange += 1
            let exchange = timeExchange
            sendMessage("client/time", ClientTimeMessage(clientTransmitted: t1))
            let waitUs = startUs + 9_500_000 - t1
            let reply = await withCheckedContinuation { continuation in
                timeReply = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .microseconds(waitUs))
                    await self?.timeReplyTimedOut(exchange)
                }
            }
            guard let (time, t4) = reply else {
                // Cut short by a re-handshake, or the connection ended; otherwise no answer.
                guard !rehandshaking, !Task.isCancelled else { return }
                Log.warning("\(serverName ?? "The server") stopped answering client/time; closing")
                socket.close()
                return
            }
            guard time.clientTransmitted == t1 else { continue }
            let measurement = ((time.serverReceived - t1) + (time.serverTransmitted - t4)) / 2
            let maxError = ((t4 - t1) - (time.serverTransmitted - time.serverReceived)) / 2
            if best == nil || maxError < best!.maxError { best = (measurement, maxError, t4) }
        }
        guard let best else { return }
        let wasConverged = converged
        // As measured: the filter discards a max_error of 0 or less (messaging.md, Time filter update).
        filter.update(measurement: best.measurement, maxError: best.maxError, timeAdded: best.at)
        if converged && !wasConverged {
            emit.yield(.clockSynchronized(errorMicros: filter.error))
            sendState(force: true)
        }
    }

    /// Only the exchange that's still waiting gives up: a late timer of an earlier one doesn't.
    private func timeReplyTimedOut(_ exchange: Int) {
        guard exchange == timeExchange else { return }
        timeReply?.resume(returning: nil)
        timeReply = nil
    }
}
