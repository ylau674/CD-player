import AppKit
import Combine
import CDKit
import OSLog
import SwiftUI

@MainActor
final class PlayerWindow: NSWindow {
    /// The player, which is the content of the window's Liquid Glass.
    let hostingView: PlayerHostingView
    private let player: PlayerModel
    private let reduceMotion: @MainActor () -> Bool
    private let isMeterWindowVisible: @MainActor (NSWindow) -> Bool
    /// The player's height without the audio levels, which add their own height below it.
    private let closedHeight: CGFloat
    private var audioLevelsSubscription: AnyCancellable?
    private var resizeSubscription: AnyCancellable?
    private var glassTintSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?
    private var visibilitySubscriptions: [AnyCancellable] = []
    private var audioLevelsVisible = false
    /// Identifies the latest show or hide, so a resize or fade that a later toggle replaced cannot report
    /// the meters fully shown, and a pending Reduce Motion shrink is cancelled.
    private var audioLevelsResizeGeneration = 0

    init(
        player: PlayerModel,
        transparency: PanelTransparency = PanelTransparency(),
        panelAppearance: PanelAppearance = PanelAppearance(),
        reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        isMeterWindowVisible: @escaping @MainActor (NSWindow) -> Bool = { window in
            window.isVisible && !window.isMiniaturized && !NSApplication.shared.isHidden &&
                window.occlusionState.contains(.visible) && NSScreen.screens.contains {
                    $0.frame.intersects(window.frame)
                }
        }
    ) {
        let content = PlayerHostingView(rootView: PlayerView(player: player))
        // Measured first: without its intrinsic size the hosting view no longer reports a fit.
        let closedSize = content.fittingSize
        // The window alone sets its height as the audio levels show or hide. Fitting the window to the
        // content as well made the two fight, which clipped the display and moved the window.
        content.sizingOptions = [.minSize]
        hostingView = content
        self.player = player
        self.reduceMotion = reduceMotion
        self.isMeterWindowVisible = isMeterWindowVisible
        closedHeight = closedSize.height
        super.init(
            contentRect: NSRect(origin: .zero, size: closedSize),
            styleMask: [.borderless, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        title = "CD Player"
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: closedSize))
        glass.style = .clear
        glass.cornerRadius = PlayerView.cornerRadius
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.contentView = content
        contentView = glass
        // The setting tints the glass toward the window background.
        // `@Published` sends the new value before storing it, so the tint uses the value it is given.
        glassTintSubscription = transparency.$percentage.sink { [weak glass] percentage in
            MainActor.assumeIsolated {
                glass?.tintColor = PlayerPalette.glass.panel.scalingAlpha(by: 1 - percentage / 100)
            }
        }
        appearanceSubscription = panelAppearance.$selection.sink { [weak self] selection in
            MainActor.assumeIsolated {
                self?.appearance = switch selection {
                case .system: nil
                case .light: NSAppearance(named: .aqua)
                case .dark: NSAppearance(named: .darkAqua)
                }
            }
        }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        // `@Published` sends before the value changes; the main queue runs this after it, in order.
        audioLevelsSubscription = player.$showsAudioLevels
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                MainActor.assumeIsolated { self?.setAudioLevelsVisible(isVisible) }
            }
        // A transparent window's shadow keeps its old outline until recomputed, so it follows each step.
        resizeSubscription = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
            .sink { [weak self] notification in
                guard let self, notification.object as AnyObject? === self else { return }
                MainActor.assumeIsolated { self.invalidateShadow() }
            }
        let windowVisibilityNotifications = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMoveNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ]
        visibilitySubscriptions += windowVisibilityNotifications.map { name in
            NotificationCenter.default.publisher(for: name, object: self)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateAudioLevelsWindowVisibility() }
                }
        }
        let applicationVisibilityNotifications = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        visibilitySubscriptions += applicationVisibilityNotifications.map { name in
            NotificationCenter.default.publisher(for: name, object: NSApplication.shared)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateAudioLevelsWindowVisibility() }
                }
        }
        updateAudioLevelsWindowVisibility()
    }

    // Borderless windows otherwise cannot receive keyboard focus or menu commands.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        updateAudioLevelsWindowVisibility()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        updateAudioLevelsWindowVisibility()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        updateAudioLevelsWindowVisibility()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSWindow.performMiniaturize(_:)) {
            return isVisible && isMiniaturizable && !isMiniaturized
        }
        return super.validateMenuItem(menuItem)
    }

    override func performMiniaturize(_ sender: Any?) {
        // AppKit's standard action clicks a title-bar button that a borderless window doesn't have.
        miniaturize(sender)
    }

    override func miniaturize(_ sender: Any?) {
        super.miniaturize(sender)
        updateAudioLevelsWindowVisibility()
    }

    override func deminiaturize(_ sender: Any?) {
        super.deminiaturize(sender)
        updateAudioLevelsWindowVisibility()
    }

    private func updateAudioLevelsWindowVisibility() {
        player.audioLevelsWindowVisibilityDidChange(isMeterWindowVisible(self))
    }

    private func setAudioLevelsVisible(_ isVisible: Bool) {
        guard audioLevelsVisible != isVisible else { return }
        audioLevelsVisible = isVisible
        audioLevelsResizeGeneration &+= 1
        let generation = audioLevelsResizeGeneration

        guard reduceMotion() else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PlayerView.audioLevelsAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                resizeForAudioLevels(animated: true)
            } completionHandler: { [weak self] in
                // AppKit does not document which thread runs this handler.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.audioLevelsDidSettle(generation) }
                }
            }
            return
        }
        // Without motion the window grows at once and the meters fade in. When hiding, they fade out first,
        // and their space goes only after the fade.
        if isVisible { resizeForAudioLevels(animated: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerView.audioLevelsAnimationDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.audioLevelsResizeGeneration == generation else { return }
                if !isVisible { self.resizeForAudioLevels(animated: false) }
                self.audioLevelsDidSettle(generation)
            }
        }
    }

    /// The meters measure only once fully shown, so only the latest toggle's finished show is reported.
    private func audioLevelsDidSettle(_ generation: Int) {
        guard generation == audioLevelsResizeGeneration, audioLevelsVisible else { return }
        player.audioLevelsDidFinishShowing()
    }

    private func resizeForAudioLevels(animated: Bool) {
        let newFrame = Self.resizedFrame(
            from: frame, closedHeight: closedHeight, showingAudioLevels: audioLevelsVisible,
            visibleFrame: (screen ?? NSScreen.main)?.visibleFrame
        )
        guard newFrame != frame else { return }
        if animated {
            animator().setFrame(newFrame, display: true)
        } else {
            setFrame(newFrame, display: true)
        }
    }

    /// The frame with the audio levels shown or hidden, from absolute heights so a toggle mid-animation still
    /// lands exactly. The top edge stays put unless the taller window would go below the visible screen.
    static func resizedFrame(
        from frame: NSRect, closedHeight: CGFloat, showingAudioLevels: Bool, visibleFrame: NSRect?
    ) -> NSRect {
        let height = closedHeight + (showingAudioLevels ? PlayerView.audioLevelsAddedHeight : 0)
        var newFrame = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        if showingAudioLevels, let visibleFrame, newFrame.minY < visibleFrame.minY {
            newFrame.origin.y = visibleFrame.minY
        }
        return newFrame
    }
}

/// SwiftUI consumes display clicks, so AppKit's movable-by-background handling never starts a drag.
/// Clicks on the display itself drag the window; buttons keep their own handling.
final class PlayerHostingView: NSHostingView<PlayerView> {
    override func mouseDown(with event: NSEvent) {
        // AppKit controls can pass clicks up the responder chain; those must never move the window.
        guard let superview, hitTest(superview.convert(event.locationInWindow, from: nil)) === self else {
            super.mouseDown(with: event)
            return
        }
        window?.performDrag(with: event)
    }

    // Allows dragging with the first click while another app is active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PlayerAppDelegate: NSObject, NSApplicationDelegate {
    let player = PlayerModel(opticalService: MacOpticalDriveService())
    let transparency = PanelTransparency(defaults: .standard)
    let appearance = PanelAppearance(defaults: .standard)
    private var window: PlayerWindow?
    private var transparencyMenu: PanelTransparencyMenuController?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        transparencyMenu = PanelTransparencyMenuController(transparency: transparency)
        player.startOpticalMonitoring()
        player.startOutputMonitoring()
        player.startPowerMonitoring()
        let window = PlayerWindow(player: player, transparency: transparency, panelAppearance: appearance)
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        Task { await player.inspectOutput() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            do {
                try await player.shutdown()
            } catch {
                Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Lifecycle")
                    .fault("Could not fully restore audio before exit: \(error.localizedDescription, privacy: .public)")
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
