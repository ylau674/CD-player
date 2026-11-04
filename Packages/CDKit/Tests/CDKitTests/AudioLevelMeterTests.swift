import Foundation
import Testing
@testable import CDKit

private final class MeterTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

@Test func audioLevelSegmentsFollowTheDocumentedThresholds() {
    #expect(AudioLevelMeter.segmentThresholds.count == 20)
    for (index, threshold) in AudioLevelMeter.segmentThresholds.enumerated() {
        #expect(AudioLevelMeter.segmentCount(for: threshold) == index + 1)
        if index > 0 {
            #expect(AudioLevelMeter.segmentCount(for: threshold - 0.001) == index)
        }
    }
    #expect(AudioLevelMeter.segmentCount(for: nil) == 0)
    #expect(AudioLevelMeter.segmentCount(for: -.infinity) == 0)
}

@Test func audioLevelFullScaleIncludesBothInt16Extremes() {
    #expect(AudioLevelMeter.decibels(for: 32_767) == 0)
    #expect(AudioLevelMeter.decibels(for: 32_768) == 0)
    #expect(AudioLevelMeter.segmentCount(for: AudioLevelMeter.decibels(for: 32_767)) == 20)
    #expect(AudioLevelMeter.decibels(for: 0) == nil)
}

@Test func audioLevelRisesImmediatelyAndFallsTwentyDecibelsInOnePointSevenSeconds() throws {
    let clock = MeterTestClock()
    var meter = AudioLevelMeter(clock: { clock.now })

    meter.update(with: AudioLevelPeaks(leftPeak: 3_277, rightPeak: 0))
    #expect(try #require(meter.reading.left.decibels) > -20.01)
    #expect(try #require(meter.reading.left.decibels) < -19.99)
    #expect(meter.reading.right.litSegments == 0)

    clock.advance(by: .milliseconds(850))
    meter.update(with: nil)
    #expect(try #require(meter.reading.left.decibels) > -30.01)
    #expect(try #require(meter.reading.left.decibels) < -29.99)
}

@Test func audioLevelPeakHoldExpiresAfterOnePointFiveSeconds() {
    let clock = MeterTestClock()
    var meter = AudioLevelMeter(clock: { clock.now })

    meter.update(with: AudioLevelPeaks(leftPeak: 3_277, rightPeak: 0))
    #expect(meter.reading.left.peakHoldSegment == 6)

    clock.advance(by: .milliseconds(1_499))
    meter.update(with: nil)
    #expect(meter.reading.left.peakHoldSegment == 6)

    clock.advance(by: .milliseconds(2))
    meter.update(with: nil)
    #expect(meter.reading.left.peakHoldSegment == nil)
    #expect(meter.reading.left.litSegments > 0)
}

@Test func audioLevelPeakHoldShowsOnlyAtOrAboveTheTopOfTheBar() {
    let clock = MeterTestClock()
    var meter = AudioLevelMeter(clock: { clock.now })

    // −6 dBFS: a new peak's hold is the bar's top segment.
    meter.update(with: AudioLevelPeaks(leftPeak: 16_423, rightPeak: 0))
    #expect(meter.reading.left.litSegments == 13)
    #expect(meter.reading.left.peakHoldSegment == 13)

    // The next hold starts from a −30 dBFS block while the bar is still falling from −6, so it is in the bar.
    clock.advance(by: .milliseconds(1_501))
    meter.update(with: AudioLevelPeaks(leftPeak: 1_036, rightPeak: 0))
    #expect(meter.reading.left.litSegments == 5)
    #expect(meter.reading.left.peakHoldSegment == nil)
    #expect(!meter.reading.isDark)

    // It shows once the bar falls to it, then stays above the bar.
    clock.advance(by: .milliseconds(400))
    meter.update(with: nil)
    #expect(meter.reading.left.litSegments == 3)
    #expect(meter.reading.left.peakHoldSegment == 3)

    clock.advance(by: .milliseconds(500))
    meter.update(with: nil)
    #expect(meter.reading.left.litSegments == 2)
    #expect(meter.reading.left.peakHoldSegment == 3)
}

@Test func resettingAudioLevelsClearsBarsAndPeakHold() {
    let clock = MeterTestClock()
    var meter = AudioLevelMeter(clock: { clock.now })
    meter.update(with: AudioLevelPeaks(leftPeak: 32_768, rightPeak: 3_277))
    #expect(!meter.reading.isDark)

    meter.reset()

    #expect(meter.reading.isDark)
    #expect(meter.reading.left.litSegments == 0)
    #expect(meter.reading.left.peakHoldSegment == nil)
    #expect(meter.reading.right.litSegments == 0)
}
