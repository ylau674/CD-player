import Foundation

public protocol AudioLevelRefreshTimer: AnyObject {
    func invalidate()
}

extension Timer: AudioLevelRefreshTimer {}

/// Redraws the meters without SwiftUI. A SwiftUI timeline updated the whole player view on every frame, which
/// cost several times the CPU of playback itself. This reads on a plain timer only while the meters are live
/// and draws only when a lit or held segment changes.
@MainActor
public final class AudioLevelMeterDriver {
    public static let refreshInterval: TimeInterval = 1.0 / 15
    /// Makes a repeating timer that calls `tick` on the main actor until `tick` returns false.
    public typealias TimerFactory = @MainActor (
        _ interval: TimeInterval, _ tick: @escaping @MainActor () -> Bool
    ) -> any AudioLevelRefreshTimer

    private let read: @MainActor () -> AudioLevelMeter.Reading
    private let draw: @MainActor (AudioLevelMeter.Reading) -> Void
    private let makeTimer: TimerFactory
    private var timer: (any AudioLevelRefreshTimer)?
    private var drawn: AudioLevelMeter.Reading?

    public init(
        read: @escaping @MainActor () -> AudioLevelMeter.Reading,
        draw: @escaping @MainActor (AudioLevelMeter.Reading) -> Void,
        makeTimer: @escaping TimerFactory = AudioLevelMeterDriver.mainRunLoopTimer
    ) {
        self.read = read
        self.draw = draw
        self.makeTimer = makeTimer
    }

    public var isRefreshing: Bool { timer != nil }

    /// Called whenever the player changes. Live meters keep reading on the timer. At any other time they are
    /// already dark, so one read redraws them and the timer stops.
    public func update(isLive: Bool) {
        refresh()
        guard isLive else {
            stop()
            return
        }
        guard timer == nil else { return }
        timer = makeTimer(Self.refreshInterval) { [weak self] in
            guard let self else { return false }
            self.refresh()
            return true
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let reading = read()
        if let drawn, reading.drawsSameSegments(as: drawn) { return }
        drawn = reading
        draw(reading)
    }

    /// Runs in common modes, so the meters keep moving while a menu is open.
    public static func mainRunLoopTimer(
        interval: TimeInterval, tick: @escaping @MainActor () -> Bool
    ) -> any AudioLevelRefreshTimer {
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            let keepRunning = MainActor.assumeIsolated { tick() }
            if !keepRunning { timer.invalidate() }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
