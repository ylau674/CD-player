import Foundation
import Testing
@testable import CDKit

private final class FakeRefreshTimer: AudioLevelRefreshTimer {
    let interval: TimeInterval
    private let tick: @MainActor () -> Bool
    private(set) var isValid = true

    init(interval: TimeInterval, tick: @escaping @MainActor () -> Bool) {
        self.interval = interval
        self.tick = tick
    }

    func invalidate() { isValid = false }

    @MainActor func fire() {
        guard isValid else { return }
        if !tick() { isValid = false }
    }
}

@MainActor
private final class MeterDriverProbe {
    var next = level(0)
    var reads = 0
    var drawn: [AudioLevelMeter.Reading] = []
    var timers: [FakeRefreshTimer] = []

    func makeDriver() -> AudioLevelMeterDriver {
        AudioLevelMeterDriver(
            read: { [unowned self] in
                reads += 1
                return next
            },
            draw: { [unowned self] in drawn.append($0) },
            makeTimer: { [unowned self] interval, tick in
                let timer = FakeRefreshTimer(interval: interval, tick: tick)
                timers.append(timer)
                return timer
            }
        )
    }
}

private func level(
    _ leftLit: Int, hold leftHold: Int? = nil, right rightLit: Int = 0, rightHold: Int? = nil,
    decibels: Double? = nil
) -> AudioLevelMeter.Reading {
    AudioLevelMeter.Reading(
        left: .init(decibels: decibels, litSegments: leftLit, peakHoldSegment: leftHold),
        right: .init(decibels: decibels, litSegments: rightLit, peakHoldSegment: rightHold)
    )
}

@Test func audioLevelSegmentStatesMatchTheBarAndItsHeldPeak() {
    let channel = level(5, hold: 9).left
    let states = (0..<20).map(channel.state(ofSegment:))
    #expect(states[0..<5].allSatisfy { $0 == .lit })
    #expect(states[5..<8].allSatisfy { $0 == .unlit })
    #expect(states[8] == .peakHold)
    #expect(states[9...].allSatisfy { $0 == .unlit })

    // A hold level with the bar's top shows red on that top segment.
    let topHeld = level(5, hold: 5).left
    #expect(topHeld.state(ofSegment: 3) == .lit)
    #expect(topHeld.state(ofSegment: 4) == .peakHold)
    #expect(topHeld.state(ofSegment: 5) == .unlit)

    let dark = level(0).left
    #expect((0..<20).allSatisfy { dark.state(ofSegment: $0) == .unlit })
}

@Test func audioLevelReadingsCompareOnlyWhatTheBarsDraw() {
    #expect(level(5, hold: 9, decibels: -30).drawsSameSegments(as: level(5, hold: 9, decibels: -30.5)))
    #expect(!level(5, hold: 9).drawsSameSegments(as: level(6, hold: 9)))
    #expect(!level(5, hold: 9).drawsSameSegments(as: level(5, hold: 10)))
    #expect(!level(5, hold: 9).drawsSameSegments(as: level(5)))
    #expect(!level(5).drawsSameSegments(as: level(5, right: 1)))
    #expect(!level(5).drawsSameSegments(as: level(5, rightHold: 3)))
}

@MainActor
@Test func audioLevelDriverReadsAtFifteenHertzOnlyWhileLive() throws {
    let probe = MeterDriverProbe()
    let driver = probe.makeDriver()

    probe.next = level(4, hold: 6)
    driver.update(isLive: true)
    #expect(probe.reads == 1)
    #expect(probe.drawn == [level(4, hold: 6)])
    let timer = try #require(probe.timers.first)
    #expect(timer.interval == 1.0 / 15)
    #expect(driver.isRefreshing)

    // Player changes while live re-read but keep the one timer.
    driver.update(isLive: true)
    #expect(probe.timers.count == 1)
    #expect(probe.reads == 2)

    timer.fire()
    timer.fire()
    #expect(probe.reads == 4)

    // Paused, covered or hidden: one read redraws the dark meters, and the timer stops.
    probe.next = level(0)
    driver.update(isLive: false)
    #expect(probe.reads == 5)
    #expect(probe.drawn.last == level(0))
    #expect(!timer.isValid)
    #expect(!driver.isRefreshing)
    timer.fire()
    #expect(probe.reads == 5)

    driver.update(isLive: false)
    #expect(probe.timers.count == 1)
    #expect(probe.reads == 6)

    driver.update(isLive: true)
    #expect(probe.timers.count == 2)
    #expect(driver.isRefreshing)
    driver.stop()
    #expect(!driver.isRefreshing)
    #expect(probe.timers.allSatisfy { !$0.isValid })
}

@MainActor
@Test func audioLevelDriverDrawsOnlyWhenASegmentChanges() throws {
    let probe = MeterDriverProbe()
    let driver = probe.makeDriver()

    // The first read always draws, even dark, so a new view shows its unlit segments.
    driver.update(isLive: true)
    #expect(probe.drawn == [level(0)])
    let timer = try #require(probe.timers.first)

    probe.next = level(10, hold: 12, decibels: -11)
    timer.fire()
    probe.next = level(10, hold: 12, decibels: -11.6)
    timer.fire()
    timer.fire()
    #expect(probe.reads == 4)
    #expect(probe.drawn == [level(0), level(10, hold: 12, decibels: -11)])

    probe.next = level(9, hold: 12)
    timer.fire()
    probe.next = level(9)
    timer.fire()
    probe.next = level(9, right: 2)
    timer.fire()
    #expect(probe.drawn.count == 5)

    probe.next = level(0)
    driver.update(isLive: false)
    driver.update(isLive: false)
    #expect(probe.drawn.count == 6)
    #expect(probe.drawn.last == level(0))
}

@MainActor
@Test func audioLevelDriverTimerStopsOnceTheDriverIsGone() throws {
    let probe = MeterDriverProbe()
    var driver: AudioLevelMeterDriver? = probe.makeDriver()
    driver?.update(isLive: true)
    let timer = try #require(probe.timers.first)
    timer.fire()
    #expect(probe.reads == 2)

    driver = nil
    timer.fire()
    #expect(!timer.isValid)
    #expect(probe.reads == 2)
}

@MainActor
@Test func audioLevelMainRunLoopTimerRepeatsUntilItsTickDeclines() async throws {
    final class Ticks { var count = 0 }
    let ticks = Ticks()
    let timer = AudioLevelMeterDriver.mainRunLoopTimer(interval: 0.005) {
        ticks.count += 1
        return ticks.count < 3
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while ticks.count < 3, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(ticks.count == 3)
    #expect(!(try #require(timer as? Timer)).isValid)
}
