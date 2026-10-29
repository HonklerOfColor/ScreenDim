import Foundation
import Testing
@testable import ScreenDimKit

@MainActor
@Suite("Entprellung der Writes")
struct LatestValueThrottleTests {
    private let sleeper = ManualSleeper()
    private let sent: AsyncStream<Int>
    private let sentContinuation: AsyncStream<Int>.Continuation

    init() {
        (sent, sentContinuation) = AsyncStream.makeStream()
    }

    private func makeThrottle() -> LatestValueThrottle<Int> {
        let sleeper = sleeper
        let sentContinuation = sentContinuation
        return LatestValueThrottle(interval: .milliseconds(50), sleep: { await sleeper.sleep($0) }) { value in
            sentContinuation.yield(value)
        }
    }

    @Test("Erster Wert sofort, danach nur der letzte Wert nach dem Intervall")
    func latestValueWins() async {
        let throttle = makeThrottle()
        var sentValues = sent.makeAsyncIterator()
        var sleeps = sleeper.started.makeAsyncIterator()

        throttle.submit(10)
        #expect(await sentValues.next() == 10)
        #expect(await sleeps.next() == .milliseconds(50))

        // Während der Sperrzeit: 20 und 30 werden von 40 überholt.
        throttle.submit(20)
        throttle.submit(30)
        throttle.submit(40)
        sleeper.wake()
        #expect(await sentValues.next() == 40)

        // Nichts mehr ausstehend: nach dem Intervall wird der Throttle leer.
        #expect(await sleeps.next() == .milliseconds(50))
        sleeper.wake()
        await waitUntilIdle(throttle)

        // Nach Leerlauf geht ein neuer Wert wieder sofort raus. 20/30 kamen nie an.
        throttle.submit(50)
        #expect(await sentValues.next() == 50)
        #expect(await sleeps.next() == .milliseconds(50))
        sleeper.wake()
        await waitUntilIdle(throttle)
    }

    @Test("Wiederholt gleicher Wert während der Sperrzeit geht genau einmal raus")
    func burstOfSameValue() async {
        let throttle = makeThrottle()
        var sentValues = sent.makeAsyncIterator()
        var sleeps = sleeper.started.makeAsyncIterator()

        throttle.submit(1)
        #expect(await sentValues.next() == 1)
        #expect(await sleeps.next() != nil)
        for _ in 0..<100 { throttle.submit(7) }
        sleeper.wake()
        #expect(await sentValues.next() == 7)
        #expect(await sleeps.next() != nil)
        sleeper.wake()
        await waitUntilIdle(throttle)
        sentContinuation.finish()
        #expect(await sentValues.next() == nil)
    }

    @Test("Zusammen mit DDCService: nur erstes und letztes Paket erreichen den Monitor")
    func throttledDDCWrites() async {
        let transport = MockTransport()
        let service = DDCService(transport: transport, label: "test", timing: .immediate)
        let sleeper = sleeper
        let sentContinuation = sentContinuation
        let throttle = LatestValueThrottle<UInt16>(sleep: { await sleeper.sleep($0) }) { value in
            try? await service.write(.brightness, value: value)
            sentContinuation.yield(Int(value))
        }
        var sentValues = sent.makeAsyncIterator()
        var sleeps = sleeper.started.makeAsyncIterator()

        for value in stride(from: UInt16(0), through: 100, by: 10) {
            throttle.submit(value)
            if value == 0 {
                #expect(await sentValues.next() == 0)
                #expect(await sleeps.next() != nil)
            }
        }
        sleeper.wake()
        #expect(await sentValues.next() == 100)
        #expect(await sleeps.next() != nil)
        sleeper.wake()
        await waitUntilIdle(throttle)

        #expect(transport.written == [
            DDCPacket.setVCPRequest(0x10, value: 0),
            DDCPacket.setVCPRequest(0x10, value: 100),
        ])
    }

    private func waitUntilIdle<Value: Sendable>(_ throttle: LatestValueThrottle<Value>) async {
        for _ in 0..<1_000 where !throttle.isIdle {
            await Task.yield()
        }
        #expect(throttle.isIdle)
    }
}
