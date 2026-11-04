import AppKit
import CDKit
import SwiftUI

struct PlayerPanelBackground: View {
    @ObservedObject var transparency: PanelTransparency
    let reduceTransparency: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(red: 0.04, green: 0.09, blue: 0.07)
                .opacity(transparency.opacity(reduceTransparency: reduceTransparency)))
    }
}

struct PlayerView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject var transparency = PanelTransparency()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let displayTint = Color(red: 0.65, green: 0.95, blue: 0.75)
    private let powerTint = Color(red: 1, green: 0.09, blue: 0.18)
    private static let width: CGFloat = 426
    static let padding: CGFloat = 18
    private static let rowSpacing: CGFloat = 10
    static let audioLevelsHeight: CGFloat = 42
    /// What showing the audio levels adds to the window: a row gap, then the meters.
    static let audioLevelsAddedHeight = rowSpacing + audioLevelsHeight
    static let audioLevelsAnimationDuration = 0.25
    /// The full width of each row, including row 2's rate icon.
    static let rowWidth = width - 2 * padding
    /// Each label sits under the first segment its level lights, so the scale matches the bars.
    static let audioLevelScaleLabels: [String?] = AudioLevelMeter.segmentThresholds.map { level in
        [-40, -20, -10, -6, -3, -1, 0].contains(level) ? String(Int(level)) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            playerRows
            audioLevelSlot
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(displayTint)
        .padding(Self.padding)
        .frame(width: Self.width)
        // Only the window sets its height. The panel fills it, with the rows pinned to its top.
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            PlayerPanelBackground(transparency: transparency, reduceTransparency: reduceTransparency)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    /// Fills whatever height the window adds below the transport buttons. Its ideal height is zero, so the
    /// player keeps its size until the window grows, and the meters are uncovered as the bottom edge moves.
    private var audioLevelSlot: some View {
        Color.clear
            .frame(minHeight: 0, idealHeight: 0, maxHeight: .infinity)
            .overlay(alignment: .top) {
                ZStack(alignment: .topLeading) {
                    AudioLevelMeters(player: player, tint: displayTint, peakHoldTint: powerTint)
                        .padding(.top, Self.rowSpacing)
                        .accessibilityHidden(true)
                        // Only the Reduce Motion fade animates: hidden meters go dark at once, not over the fade.
                        .animation(.easeInOut(duration: Self.audioLevelsAnimationDuration)) {
                            $0.opacity(reduceMotion && !player.showsAudioLevels ? 0 : 1)
                        }
                    AudioLevelsAccessibilityMarker(isHidden: !player.showsAudioLevels)
                        .frame(width: 1, height: 1)
                }
            }
            .clipped()
            .accessibilityHidden(!player.showsAudioLevels)
    }

    private var playerRows: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if player.source == .opticalDrive, let drive = player.displayedDrive {
                        HStack(spacing: 5) {
                            if player.showsDriveSelector {
                                TransportButton(
                                    symbol: "opticaldiscdrive", label: player.driveSelectorLabel,
                                    tint: displayTint, height: 20, pointSize: 11
                                ) {
                                    player.selectNextDrive()
                                }
                                .disabled(!player.driveSelectorEnabled)
                                .frame(width: 20)
                            }
                            Text(drive.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(drive.name)
                                .accessibilityLabel("Optical drive, \(drive.name)")
                        }
                    }
                    Spacer(minLength: 12)
                    // An empty Text is measured with a taller default line and would grow the window.
                    if !player.formatText.isEmpty {
                        // Fixed, so the drive name truncates first.
                        Text(player.formatText)
                            .lineLimit(1)
                            .fixedSize()
                            .help(player.formatHelp ?? player.formatText)
                            .accessibilityLabel(player.formatAccessibilityLabel)
                    }
                    TransportButton(
                        symbol: "power", label: "Quit CD Player",
                        tint: powerTint, height: 20
                    ) {
                        NSApplication.shared.terminate(nil)
                    }
                    .frame(width: 24)
                }

                HStack(spacing: 0) {
                    OutputStatusLine(content: outputStatusLine) { id in
                        Task { await player.selectOutput(id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if player.showsOutputRateSwitch {
                        // Lit while the output runs at the source's 44.1 kHz; the tint stays truthful when disabled.
                        TransportButton(
                            symbol: player.outputRateSymbol, label: player.outputRateLabel,
                            tint: player.outputMatchesSource ? displayTint : displayTint.opacity(0.35),
                            height: 12, pointSize: 10, dimsWhenDisabled: false
                        ) {
                            Task { await player.toggleOutputRate() }
                        }
                        .disabled(!player.outputRateSwitchEnabled)
                        .frame(width: 16)
                        .padding(.leading, 6)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("TRK")
                    .font(.system(size: 14, design: .monospaced))
                Text(player.trackText)
                Spacer()
                Text(player.timeText)
            }
            .font(.system(size: 38, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(player.displayAccessibilityLabel)

            HStack(spacing: 8) {
                transport(
                    "backward.end.fill", label: "Previous track; hold to go back 10 seconds",
                    hold: TransportHold(symbol: "backward.fill", label: "Back 10 seconds") {
                        Task { await player.scan(.backward) }
                    }
                ) {
                    await player.previousTrack()
                }
                transport(player.state == .playing ? "pause.fill" : "play.fill",
                          label: player.state == .playing ? "Pause" : "Play") {
                    await player.togglePlayback()
                }
                transport(
                    "forward.end.fill", label: "Next track; hold to go forward 10 seconds",
                    hold: TransportHold(symbol: "forward.fill", label: "Forward 10 seconds") {
                        Task { await player.scan(.forward) }
                    }
                ) {
                    await player.nextTrack()
                }
                transport(
                    player.stopOrEjectSymbol, label: player.stopOrEjectLabel,
                    enabled: player.stopOrEjectEnabled
                ) {
                    await player.stopOrEject()
                }
            }
        }
    }

    private struct AudioLevelMeters: View {
        @ObservedObject var player: PlayerModel
        let tint: Color
        let peakHoldTint: Color

        var body: some View {
            VStack(spacing: AudioLevelBarsView.rowSpacing) {
                HStack(spacing: 5) {
                    VStack(spacing: AudioLevelBarsView.rowSpacing) {
                        legend("L", height: AudioLevelBarsView.rowHeight)
                        legend("R", height: AudioLevelBarsView.rowHeight)
                    }
                    // Paused, the meters are already dark; a player change redraws them once without the timer.
                    AudioLevelBars(
                        isLive: player.audioLevelsAreLive, read: { [player] in player.refreshAudioLevels() },
                        tint: tint, peakHoldTint: peakHoldTint
                    )
                }
                .frame(height: AudioLevelBarsView.height)
                HStack(spacing: 5) {
                    legend("dB", height: 10)
                    HStack(spacing: AudioLevelBarsView.segmentSpacing) {
                        ForEach(PlayerView.audioLevelScaleLabels.indices, id: \.self) { segment in
                            Color.clear
                                .overlay {
                                    if let label = PlayerView.audioLevelScaleLabels[segment] {
                                        Text(label).fixedSize()
                                    }
                                }
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 10)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
            }
            .frame(height: PlayerView.audioLevelsHeight)
        }

        private func legend(_ text: String, height: CGFloat) -> some View {
            Text(text)
                .frame(width: 10, height: height, alignment: .leading)
        }
    }

    private struct AudioLevelsAccessibilityMarker: NSViewRepresentable {
        let isHidden: Bool

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            view.setAccessibilityLabel("Audio levels")
            view.setAccessibilityHidden(isHidden)
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            view.setAccessibilityHidden(isHidden)
        }
    }

    private var outputStatusLine: OutputStatusLine.Content {
        OutputStatusLine.Content(
            status: player.statusText,
            tone: player.statusIsError ? .error : player.statusIsWarning ? .warning : .normal,
            statusAccessibilityLabel: player.statusAccessibilityLabel,
            outputName: player.outputSelectorName,
            outputHelp: player.outputSelectorHelp,
            outputAccessibilityValue: player.outputSelectorAccessibilityValue,
            outputEnabled: player.outputSelectorEnabled,
            choices: player.outputChoices,
            selectedID: player.selectedOutputID,
            // Half of the whole row, whether or not the rate icon is shown.
            maximumNameWidth: Double(Self.rowWidth / 2)
        )
    }

    private func transport(
        _ symbol: String, label: String, enabled: Bool? = nil, hold: TransportHold? = nil,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        let isEnabled = enabled ?? player.controlsEnabled
        return TransportButton(symbol: symbol, label: label, tint: displayTint, hold: hold) {
            Task { await action() }
        }
        .disabled(!isEnabled)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(displayTint.opacity(isEnabled ? 0.7 : 0.2), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }
}
