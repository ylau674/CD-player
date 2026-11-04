import AppKit
@testable import CDKit
import SwiftUI
import XCTest

@MainActor
final class OutputStatusLineTests: XCTestCase {
    private func content(
        status: String = "CD PLAYING | ERR 12 | UNVERIFIED",
        name: String = "Pioneer USB Audio Device",
        enabled: Bool = true
    ) -> OutputStatusLine.Content {
        .init(
            status: status, tone: .error, statusAccessibilityLabel: "CD playing. 12 audio sectors concealed",
            outputName: name, outputHelp: "\(name), Built-in", outputAccessibilityValue: "\(name), built-in",
            outputEnabled: enabled,
            choices: [OutputChoice(id: .device(uid: name), name: name, connection: "Built-in")],
            selectedID: .device(uid: name)
        )
    }

    private func window(for view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.level = .floating
        window.center()
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func wait(_ seconds: Double = 0.15) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func text(_ layer: CATextLayer) -> String? { (layer.string as? NSAttributedString)?.string }

    /// Where `layer` is drawn now, in the view's coordinates, including any animation.
    private func shownFrame(_ layer: CALayer, in view: NSView) throws -> CGRect {
        let root = try XCTUnwrap(view.layer?.presentation() ?? view.layer)
        let shown = try XCTUnwrap(layer.presentation())
        return root.convert(shown.bounds, from: shown)
    }

    func testMeasuredFitReduceMotionAndSeparateAccessibility() throws {
        let view = OutputStatusLineView(frame: NSRect(x: 0, y: 0, width: 368, height: 14))
        let window = window(for: view)
        defer { window.close() }
        view.update(content(name: "MacBook Pro Speakers"), reduceMotion: false)
        wait()
        XCTAssertNil(view.scroller.animation(forKey: OutputStatusLineView.scrollKey))
        XCTAssertEqual(view.indicatorLayer.frame.maxX, 368, accuracy: 0.5)
        XCTAssertEqual(view.nameSpace.frame.maxX, view.indicatorLayer.frame.minX, accuracy: 0.01)
        view.update(content(), reduceMotion: true)
        XCTAssertEqual(text(view.statusLayer), "CD PLAYING | ERR 12 | UNVERIFIED")
        XCTAssertEqual(text(view.indicatorLayer), " ▾")
        let truncated = try XCTUnwrap(text(view.nameLayers[0]))
        XCTAssertTrue(truncated.contains("…"))
        XCTAssertFalse(truncated.contains("▾"))
        XCTAssertNil(view.scroller.animation(forKey: OutputStatusLineView.scrollKey))
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].accessibilityRole(), .staticText)
        XCTAssertEqual(children[1].accessibilityRole(), .popUpButton)
        XCTAssertEqual(children[1].accessibilityLabel(), "Audio output")
        XCTAssertEqual(children[1].accessibilityHelp(), "Pioneer USB Audio Device, Built-in")
        XCTAssertEqual(children[1].accessibilityFrameInParentSpace(), view.selectorFrame)
        view.update(content(enabled: false), reduceMotion: true)
        XCTAssertFalse(children[1].isAccessibilityEnabled())
    }

    func testOnlyTheNameScrollsWhileStatusAndIndicatorStayFixed() throws {
        let view = OutputStatusLineView(frame: NSRect(x: 0, y: 0, width: 368, height: 14))
        let window = window(for: view)
        defer { window.close() }
        view.update(content(), reduceMotion: false)
        // The status and indicator are not inside the moving layer, and nothing animates them.
        XCTAssertTrue(view.statusLayer.superlayer === view.layer)
        XCTAssertTrue(view.indicatorLayer.superlayer === view.layer)
        XCTAssertTrue(view.nameSpace.masksToBounds)
        XCTAssertEqual(view.nameSpace.frame.minX, view.statusLayer.frame.maxX + OutputLineLayout.gap, accuracy: 0.01)
        XCTAssertEqual(view.nameSpace.frame.maxX, view.indicatorLayer.frame.minX, accuracy: 0.01)
        XCTAssertEqual(view.indicatorLayer.frame.maxX, 368, accuracy: 0.5)
        wait(0.3)
        let status = try shownFrame(view.statusLayer, in: view)
        let indicator = try shownFrame(view.indicatorLayer, in: view)
        let nameAtRest = try shownFrame(view.nameLayers[0], in: view)
        XCTAssertEqual(status.minX, 0, accuracy: 0.01)
        wait(2.4)
        let animation = try XCTUnwrap(view.scroller.animation(forKey: OutputStatusLineView.scrollKey))
        let nameMoved = try shownFrame(view.nameLayers[0], in: view)
        XCTAssertLessThan(nameMoved.minX, nameAtRest.minX - 3)
        XCTAssertEqual(try shownFrame(view.statusLayer, in: view), status)
        XCTAssertEqual(try shownFrame(view.indicatorLayer, in: view), indicator)
        for layer in [view.statusLayer, view.indicatorLayer, view.nameSpace] {
            XCTAssertNil(layer.animationKeys())
        }

        // The selector does not move with the name: its whole space and the indicator open the menu.
        XCTAssertTrue(view.selectorContains(NSPoint(x: view.nameSpace.frame.minX + 2, y: 7)))
        XCTAssertTrue(view.selectorContains(NSPoint(x: indicator.midX, y: 7)))
        XCTAssertFalse(view.selectorContains(NSPoint(x: 0, y: 7)))

        // A status update keeps the pass; a longer status only moves the start of the name's space.
        view.update(content(status: "CD PLAYING | ERR 13 | UNVERIFIED"), reduceMotion: false)
        XCTAssertEqual(view.scroller.animation(forKey: OutputStatusLineView.scrollKey)?.beginTime, animation.beginTime)
        let spaceStart = view.nameSpace.frame.minX
        view.update(content(status: "CD PLAYING | ERR 123 | UNVERIFIED"), reduceMotion: false)
        XCTAssertEqual(view.scroller.animation(forKey: OutputStatusLineView.scrollKey)?.beginTime, animation.beginTime)
        XCTAssertGreaterThan(view.nameSpace.frame.minX, spaceStart)
        XCTAssertEqual(view.statusLayer.frame.minX, 0)
        XCTAssertEqual(view.indicatorLayer.frame, indicator)
        wait(0.05)
        XCTAssertLessThan(try XCTUnwrap(view.scroller.presentation()).transform.m41, -3)

        // Another name starts a new pass.
        view.update(content(status: "CD PLAYING | ERR 123 | UNVERIFIED", name: "Pioneer USB Audio DEVICE"),
                    reduceMotion: false)
        XCTAssertNotEqual(view.scroller.animation(forKey: OutputStatusLineView.scrollKey)?.beginTime,
                          animation.beginTime)

        window.orderOut(nil)
        wait()
        XCTAssertNil(view.scroller.animation(forKey: OutputStatusLineView.scrollKey))
        window.orderFrontRegardless()
        wait()
        XCTAssertNotNil(view.scroller.animation(forKey: OutputStatusLineView.scrollKey))
        view.update(content(status: "CD PLAYING", name: "Speakers"), reduceMotion: false)
        XCTAssertNil(view.scroller.animation(forKey: OutputStatusLineView.scrollKey))
        XCTAssertEqual(view.scroller.transform.m41, 0)
        XCTAssertEqual(view.indicatorLayer.frame, indicator)
        XCTAssertEqual(view.nameSpace.frame.maxX, indicator.minX, accuracy: 0.01)
    }

    func testMenuTickSelectionAndAccessibilityOpeningWhileScrolling() throws {
        let view = OutputStatusLineView(frame: NSRect(x: 0, y: 0, width: 368, height: 14))
        let window = window(for: view)
        defer { window.close() }
        var menuContent = content()
        menuContent.choices.append(OutputChoice(
            id: .device(uid: "unsupported-hdmi"), name: "HDMI Receiver", connection: "HDMI", symbol: "tv",
            isEnabled: false, disabledReason: "Does not support 44.1 kHz."
        ))
        menuContent.choices.append(.systemDefault(AudioOutputDevice(
            uid: "airpods", deviceID: 9, name: "AirPods Pro", transport: .bluetooth, sampleRate: 48_000,
            hogOwner: -1, supportsSourceRate: true, hasStereoOutput: true, isDefaultOutput: true, terminalType: 0,
            usesSpeakers: false, restoreRate: 48_000
        )))
        view.update(menuContent, reduceMotion: false)
        wait(2.2)
        var selected: OutputChoice.ID?
        view.select = { selected = $0 }
        let menu = view.makeOutputMenu()
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(menu.items.count, 4)
        XCTAssertEqual(item.title, "Pioneer USB Audio Device — Built-in")
        XCTAssertEqual(item.state, .on)
        XCTAssertNotNil(item.image)
        XCTAssertEqual(menu.items[1].title, "HDMI Receiver — HDMI (Does not support 44.1 kHz.)")
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertNotNil(menu.items[1].image)
        // System Default follows macOS, so a separator keeps it apart from the wired outputs.
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].title, "System Default — AirPods Pro (Bluetooth), best effort")
        XCTAssertTrue(menu.items[3].isEnabled)
        XCTAssertEqual(menu.items[3].state, .off)
        XCTAssertNotNil(menu.items[3].image)
        menu.performActionForItem(at: 3)
        XCTAssertEqual(selected, .systemDefault)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(selected, .device(uid: "Pioneer USB Audio Device"))

        let probe = MenuProbe()
        NotificationCenter.default.addObserver(
            probe, selector: #selector(MenuProbe.opened(_:)), name: NSMenu.didBeginTrackingNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(probe) }
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertTrue(children[1].accessibilityPerformShowMenu())
        wait(0.4)
        XCTAssertTrue(probe.didOpen)
    }

    func testDemoAndEmptyWindowKeepTheirWidthAndRateButton() async throws {
        let model = PlayerModel(engine: UIEngine(), automaticallyMonitor: false, outputRateControl: UIRateControl(),
                                outputSelectionStore: UISelectionStore())
        await model.inspectOutput()
        let host = NSHostingView(rootView: PlayerView(player: model))
        host.frame.size = host.fittingSize
        let window = window(for: host)
        defer { window.close() }
        wait()
        XCTAssertEqual(host.fittingSize.width, 426, accuracy: 0.5)
        let height = host.fittingSize.height
        attach(host, name: "Demo ready")
        let line = try XCTUnwrap(descendant(OutputStatusLineView.self, in: host))
        XCTAssertEqual(line.bounds.width, 368, accuracy: 0.5)
        let initialFrame = line.convert(line.bounds, to: host)
        await model.eject()
        wait()
        XCTAssertEqual(host.fittingSize.height, height, accuracy: 1)
        XCTAssertEqual(line.convert(line.bounds, to: host), initialFrame)
        XCTAssertEqual(model.formatText, "")
        try await model.shutdown()
    }

    func testOnlyThePanelFillIsTranslucentUnlessReduceTransparencyIsOn() async throws {
        XCTAssertEqual(PanelTransparency().opacity(reduceTransparency: false), 0.3, accuracy: 0.001)
        XCTAssertEqual(PanelTransparency().opacity(reduceTransparency: true), 1)
        let model = PlayerModel.offline()
        await model.inspectOutput()
        let window = await playerWindow(for: model, reduceMotion: false)
        defer { window.close() }
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.alphaValue, 1, "Fading the whole window would fade the display too")
        let host = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let transparent = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
        func pixel(x: Int, y: Int) -> NSColor {
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? transparent
        }

        // Halfway into the left padding, at mid height, nothing but the fill is drawn.
        let fill = pixel(x: Int(PlayerView.padding / 2 * scale), y: bitmap.pixelsHigh / 2)
        let expected = PanelTransparency().opacity(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        XCTAssertEqual(fill.alphaComponent, expected, accuracy: 0.02)
        let border = pixel(x: 0, y: bitmap.pixelsHigh / 2)
        XCTAssertTrue(isWhite(border) && border.alphaComponent > 0.99, "The border stays opaque")
        var opaqueText = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = pixel(x: x, y: y)
                if color.alphaComponent > 0.99, isDisplayTint(color) { opaqueText += 1 }
            }
        }
        // The track number and time alone draw far more fully opaque pixels than this.
        XCTAssertGreaterThan(opaqueText, 500, "The display's text stays opaque")
        attach(host, name: "Translucent panel")
        try await model.shutdown()
    }

    func testTransparencySettingChangesRenderedFillLiveWithoutFadingControls() async throws {
        let model = PlayerModel.offline()
        let transparency = PanelTransparency()
        await model.inspectOutput()
        let playerWindow = PlayerWindow(player: model, transparency: transparency)
        playerWindow.center()
        playerWindow.orderFrontRegardless()
        defer { playerWindow.close() }
        let host = try XCTUnwrap(playerWindow.contentView)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        for percentage in [0.0, 40, 70, 90] {
            transparency.setPercentage(percentage)
            await settle(0.1)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let fill = try XCTUnwrap(bitmap.colorAt(
                x: Int(PlayerView.padding / 2 * scale), y: bitmap.pixelsHigh / 2
            ))
            XCTAssertEqual(fill.alphaComponent, reduced ? 1 : 1 - percentage / 100, accuracy: 0.02)
            let border = try XCTUnwrap(bitmap.colorAt(x: 0, y: bitmap.pixelsHigh / 2))
            XCTAssertEqual(border.alphaComponent, 1, accuracy: 0.01)
        }
        try await model.shutdown()
    }

    func testPanelBackgroundRendersBothAccessibilitySettings() async throws {
        let transparency = PanelTransparency()
        for reduced in [false, true] {
            let host = NSHostingView(rootView: PlayerPanelBackground(
                transparency: transparency, reduceTransparency: reduced
            ))
            host.frame.size = NSSize(width: 100, height: 100)
            let window = window(for: host)
            defer { window.close() }
            for percentage in [0.0, 40, 70, 90] {
                transparency.setPercentage(percentage)
                await settle(0.1)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let fill = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
                XCTAssertEqual(fill.alphaComponent, reduced ? 1 : 1 - percentage / 100, accuracy: 0.02)
            }
        }
    }

    func testAudioLevelsExtendTheWindowDownwardWithTheDisplayFixed() async throws {
        let model = PlayerModel(engine: UIEngine(), automaticallyMonitor: false, outputRateControl: UIRateControl(),
                                outputSelectionStore: UISelectionStore())
        let window = await playerWindow(for: model, reduceMotion: false)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)

        let closedFrame = window.frame
        XCTAssertEqual(closedFrame.size, NSHostingView(rootView: PlayerView(player: model)).fittingSize)
        XCTAssertEqual(closedFrame.width, 426, accuracy: 0.5)
        XCTAssertFalse(model.showsAudioLevels)
        assertPanelFillsWindow(host, settled: true, "Closed")
        let shownHeight = closedFrame.height + PlayerView.audioLevelsAddedHeight

        // Hiding once let the content fit the window too: the display was clipped and the window moved up.
        for (showing, height) in [(true, shownHeight), (false, closedFrame.height)] {
            model.toggleAudioLevels()
            XCTAssertEqual(model.showsAudioLevels, showing)
            let phase = showing ? "Showing" : "Hiding"
            var heights: Set<Int> = []
            for _ in 0..<15 {
                await settle(0.03)
                heights.insert(Int(window.frame.height.rounded()))
                XCTAssertEqual(window.frame.maxY, closedFrame.maxY, accuracy: 0.5)
                XCTAssertEqual(window.frame.width, 426, accuracy: 0.5)
                assertPanelFillsWindow(host, settled: false, phase)
            }
            XCTAssertGreaterThan(heights.count, 2, "The window should animate")
            XCTAssertEqual(window.frame.height, height, accuracy: 0.5)
            assertPanelFillsWindow(host, settled: true, phase)
            if showing { attach(host, name: "Audio levels shown") }
        }
        await settle(1)
        XCTAssertEqual(window.frame, closedFrame)
        try await model.shutdown()
    }

    func testAudioLevelsSettleWhenToggledMidAnimation() async throws {
        let model = PlayerModel(engine: UIEngine(), automaticallyMonitor: false, outputRateControl: UIRateControl(),
                                outputSelectionStore: UISelectionStore())
        let window = await playerWindow(for: model, reduceMotion: false)
        defer { window.close() }
        let closedFrame = window.frame
        let shownHeight = closedFrame.height + PlayerView.audioLevelsAddedHeight

        model.toggleAudioLevels()
        await settle(0.1)
        model.toggleAudioLevels()
        await settle(0.6)
        XCTAssertEqual(window.frame, closedFrame)

        model.toggleAudioLevels()
        await settle(0.1)
        model.toggleAudioLevels()
        await settle(0.05)
        model.toggleAudioLevels()
        await settle(0.6)
        XCTAssertTrue(model.showsAudioLevels)
        XCTAssertEqual(window.frame.height, shownHeight, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, closedFrame.maxY, accuracy: 0.5)
        assertPanelFillsWindow(try XCTUnwrap(window.contentView), settled: true, "Shown")
        try await model.shutdown()
    }

    func testReduceMotionShrinksTheWindowOnlyAfterTheMetersFade() async throws {
        let model = PlayerModel(engine: UIEngine(), automaticallyMonitor: false, outputRateControl: UIRateControl(),
                                outputSelectionStore: UISelectionStore())
        let window = await playerWindow(for: model, reduceMotion: true)
        defer { window.close() }
        let closedFrame = window.frame
        let shownFrame = PlayerWindow.resizedFrame(
            from: closedFrame, closedHeight: closedFrame.height, showingAudioLevels: true, visibleFrame: nil
        )

        model.toggleAudioLevels()
        await settle(0.05)
        XCTAssertEqual(window.frame, shownFrame)

        model.toggleAudioLevels()
        await settle(0.1)
        XCTAssertEqual(window.frame, shownFrame)
        await settle(0.3)
        XCTAssertEqual(window.frame, closedFrame)

        // Showing them again during the fade cancels the pending shrink.
        model.toggleAudioLevels()
        await settle(0.05)
        model.toggleAudioLevels()
        await settle(0.1)
        model.toggleAudioLevels()
        await settle(0.4)
        XCTAssertTrue(model.showsAudioLevels)
        XCTAssertEqual(window.frame, shownFrame)
        try await model.shutdown()
    }

    func testAudioLevelsMeasureOnlyWhileTheWindowIsFullyExtended() async throws {
        let source = UILevelSource()
        let model = await fullScalePlayer(source)
        let window = await playerWindow(for: model, reduceMotion: false)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        let closedHeight = window.frame.height
        let shownHeight = closedHeight + PlayerView.audioLevelsAddedHeight

        let start = ContinuousClock.now
        model.toggleAudioLevels()
        var extending = 0
        while !model.audioLevelsAreFullyShown, ContinuousClock.now - start < .seconds(2) {
            await model.refreshPlayback()
            await settle(0.02)
            guard window.frame.height < shownHeight - 0.5 else { continue }
            extending += 1
            XCTAssertFalse(model.audioLevelsAreFullyShown, "Measuring while the window extends")
            XCTAssertEqual(source.reads, 0, "Read while the window extends")
            XCTAssertEqual(litBarPoints(in: host, closedHeight: closedHeight), 0, "Lit while the window extends")
        }
        XCTAssertGreaterThan(extending, 3, "The window should animate")
        XCTAssertTrue(model.audioLevelsAreFullyShown, "Fully extended, but not reported")
        XCTAssertEqual(window.frame.height, shownHeight, accuracy: 0.5)
        XCTAssertGreaterThan(source.reads, 0, "The first reading comes with the report")
        await model.refreshPlayback()
        await settle(0.1)
        XCTAssertGreaterThan(litBarPoints(in: host, closedHeight: closedHeight), 1_000)

        model.toggleAudioLevels()
        XCTAssertFalse(model.audioLevelsAreFullyShown)
        XCTAssertFalse(model.audioLevelsAreLive)
        XCTAssertTrue(model.audioLevelReading.isDark)
        let reads = source.reads
        var shrinking = 0
        repeat {
            await model.refreshPlayback()
            await settle(0.02)
            if window.frame.height > closedHeight + 0.5 { shrinking += 1 }
            XCTAssertEqual(litBarPoints(in: host, closedHeight: closedHeight), 0, "Lit while the window shrinks")
        } while window.frame.height > closedHeight + 0.5 && ContinuousClock.now - start < .seconds(4)
        XCTAssertGreaterThan(shrinking, 3, "The window should animate")
        for _ in 0..<5 {
            await model.refreshPlayback()
            await settle(0.05)
        }
        XCTAssertEqual(window.frame.height, closedHeight, accuracy: 0.5)
        XCTAssertFalse(model.audioLevelsAreFullyShown)
        XCTAssertEqual(source.reads, reads, "Read while the window shrinks or is closed")
        try await model.shutdown()
    }

    func testAudioLevelsStopMeasuringWhenTheWindowIsNotVisible() async throws {
        let source = UILevelSource()
        source.level = AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768)
        let visibility = UIWindowVisibilityProbe()
        let model = PlayerModel(
            engine: UIAdvancingEngine(), audioLevelSource: source, automaticallyMonitor: false,
            outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore()
        )
        await model.inspectOutput()
        await model.togglePlayback()
        await model.refreshPlayback()
        XCTAssertEqual(model.state, .playing)

        let window = await playerWindow(
            for: model, reduceMotion: true,
            isMeterWindowVisible: { window in
                window.isVisible && !window.isMiniaturized &&
                    !visibility.isOccluded && !visibility.isApplicationHidden
            }
        )
        defer { window.close() }
        model.toggleAudioLevels()
        let showStarted = ContinuousClock.now
        while !model.audioLevelsAreFullyShown, ContinuousClock.now - showStarted < .seconds(2) {
            await settle(0.02)
        }
        XCTAssertTrue(model.audioLevelsAreFullyShown)
        XCTAssertTrue(model.audioLevelsWindowIsVisible)
        await sampleMeter(source, model: model)
        XCTAssertGreaterThan(source.reads, 2)

        let cover = NSWindow(
            contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        cover.isOpaque = true
        cover.backgroundColor = .gray
        cover.level = .floating
        cover.isReleasedWhenClosed = false
        cover.orderFrontRegardless()
        defer { cover.close() }
        visibility.isOccluded = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await settle(0.05)
        XCTAssertFalse(model.audioLevelsWindowIsVisible, "A fully covered window must stop measuring")
        var reads = source.reads
        await sampleMeter(source, model: model)
        XCTAssertEqual(source.reads, reads, "Read while fully covered")

        cover.close()
        visibility.isOccluded = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await settle(0.05)
        XCTAssertTrue(model.audioLevelsWindowIsVisible)
        await sampleMeter(source, model: model)
        XCTAssertGreaterThan(source.reads, reads, "Reads should resume when the window is uncovered")

        visibility.isApplicationHidden = true
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApplication.shared)
        await settle(0.05)
        XCTAssertFalse(model.audioLevelsWindowIsVisible, "A hidden app must stop measuring")
        reads = source.reads
        await sampleMeter(source, model: model)
        XCTAssertEqual(source.reads, reads, "Read while the app is hidden")

        visibility.isApplicationHidden = false
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApplication.shared)
        await settle(0.05)
        XCTAssertTrue(model.audioLevelsWindowIsVisible)
        await sampleMeter(source, model: model)
        XCTAssertGreaterThan(source.reads, reads, "Reads should resume when the app is shown")

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(model.audioLevelsWindowIsVisible)
        reads = source.reads
        await sampleMeter(source, model: model)
        XCTAssertEqual(source.reads, reads, "Read after the window is ordered out")

        window.orderFrontRegardless()
        XCTAssertTrue(model.audioLevelsWindowIsVisible)
        await sampleMeter(source, model: model)
        XCTAssertGreaterThan(source.reads, reads, "Reads should resume when the window returns")
        try await model.shutdown()
    }

    func testPlayerWindowMinimizeMenuStopsMeterReadsUntilRestored() async throws {
        let source = UILevelSource()
        source.level = AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768)
        let model = PlayerModel(
            engine: UIAdvancingEngine(), audioLevelSource: source, automaticallyMonitor: false,
            outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore()
        )
        await model.inspectOutput()
        await model.togglePlayback()
        await model.refreshPlayback()
        let window = await playerWindow(for: model, reduceMotion: true)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        model.toggleAudioLevels()
        await settle(PlayerView.audioLevelsAnimationDuration + 0.1)
        XCTAssertTrue(model.audioLevelsAreLive)
        await sampleMeter(source, model: model)

        let menu = NSMenu(title: "Window")
        let minimize = NSMenuItem(
            title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
        )
        minimize.target = window
        minimize.keyEquivalentModifierMask = .command
        menu.addItem(minimize)
        menu.update()
        XCTAssertTrue(window.validateMenuItem(minimize))
        XCTAssertTrue(minimize.isEnabled, "The native Minimize command must be enabled for the player")
        menu.performActionForItem(at: 0)
        let minimizing = ContinuousClock.now
        while !window.isMiniaturized || model.audioLevelsWindowIsVisible,
              ContinuousClock.now - minimizing < .seconds(2) {
            await settle(0.02)
        }
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertFalse(window.validateMenuItem(minimize))
        XCTAssertFalse(model.audioLevelsWindowIsVisible)
        XCTAssertFalse(model.audioLevelsAreLive)
        XCTAssertTrue(model.audioLevelReading.isDark)
        let reads = source.reads
        await sampleMeter(source, model: model)
        XCTAssertEqual(source.reads, reads, "Read while minimized")
        XCTAssertEqual(model.state, .playing)

        window.deminiaturize(nil)
        let restoring = ContinuousClock.now
        while window.isMiniaturized || !model.audioLevelsWindowIsVisible,
              ContinuousClock.now - restoring < .seconds(2) {
            await settle(0.02)
        }
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.validateMenuItem(minimize))
        XCTAssertTrue(model.audioLevelsWindowIsVisible)
        XCTAssertTrue(model.audioLevelsAreLive)
        await sampleMeter(source, model: model)
        XCTAssertGreaterThan(source.reads, reads, "Reads should resume after restoring")
        XCTAssertEqual(model.state, .playing)
        try await model.shutdown()
    }

    private func sampleMeter(_ source: UILevelSource, model: PlayerModel) async {
        for _ in 0..<4 {
            await model.refreshPlayback()
            _ = model.refreshAudioLevels()
            await settle(0.04)
        }
    }

    /// The bars read on their own timer, outside SwiftUI, and only a segment change recolours them: their
    /// segment layers change at once, and the view itself never draws.
    func testAudioLevelBarsReadOnTheirOwnTimerAndRedrawOnlyWhenASegmentChanges() async throws {
        let source = UILevelSource()
        source.level = AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768)
        let model = PlayerModel(
            engine: UIAdvancingEngine(), audioLevelSource: source, automaticallyMonitor: false,
            outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore()
        )
        await model.inspectOutput()
        await model.togglePlayback()
        await model.refreshPlayback()
        let window = await playerWindow(for: model, reduceMotion: true)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        let closedHeight = window.frame.height
        let bars = try XCTUnwrap(descendant(AudioLevelBarsView.self, in: host))
        XCTAssertFalse(bars.isRefreshing, "Hidden meters must not run a timer")

        model.toggleAudioLevels()
        await settle(PlayerView.audioLevelsAnimationDuration + 0.1)
        XCTAssertTrue(model.audioLevelsAreLive)
        XCTAssertTrue(bars.isRefreshing)

        // Nothing else reads the levels here, and the position stays fresh for 0.2 s after a poll.
        await model.refreshPlayback()
        await settle(0.02)
        var reads = source.reads
        await settle(0.15)
        XCTAssertGreaterThan(source.reads, reads, "The bars' timer should read by itself")
        XCTAssertGreaterThan(litBarPoints(in: host, closedHeight: closedHeight), 1_000)

        // A steady full-scale level keeps every segment, so further reads draw nothing new.
        let drawn = bars.drawnReadings
        reads = source.reads
        for _ in 0..<5 {
            await model.refreshPlayback()
            await settle(0.06)
        }
        XCTAssertGreaterThan(source.reads, reads)
        XCTAssertEqual(bars.drawnReadings, drawn, "Redrawn without a segment change")

        source.level = AudioLevelPeaks(leftPeak: 0, rightPeak: 0)
        for _ in 0..<5 {
            await model.refreshPlayback()
            await settle(0.06)
        }
        XCTAssertGreaterThan(bars.drawnReadings, drawn, "A falling bar should redraw")
        // The top segments go out a tick or two apart, so a 0.25 s implicit fade would still be running.
        XCTAssertEqual(bars.segmentLayers.compactMap { $0.animationKeys() }, [], "A segment change animated")
        XCTAssertNil(bars.layer?.contents, "The bars view drew a backing store")

        model.toggleAudioLevels()
        await settle(0.05)
        XCTAssertFalse(bars.isRefreshing, "Hidden meters must stop their timer")
        XCTAssertEqual(litBarPoints(in: host, closedHeight: closedHeight), 0)
        try await model.shutdown()
    }

    func testAudioLevelsMeasureOnlyOnceTheLastShowFinishesExtending() async throws {
        let source = UILevelSource()
        let model = await fullScalePlayer(source)
        let window = await playerWindow(for: model, reduceMotion: false)
        defer { window.close() }
        let closedHeight = window.frame.height
        let shownHeight = closedHeight + PlayerView.audioLevelsAddedHeight

        // A show cut short by a hide never reports, even after its animation would have ended.
        model.toggleAudioLevels()
        await settle(0.1)
        model.toggleAudioLevels()
        await settle(0.6)
        XCTAssertEqual(window.frame.height, closedHeight, accuracy: 0.5)
        XCTAssertFalse(model.audioLevelsAreFullyShown)

        // Nor does an earlier show or a cut-short hide while the last show is still extending.
        model.toggleAudioLevels()
        await settle(0.1)
        model.toggleAudioLevels()
        await settle(0.05)
        let start = ContinuousClock.now
        model.toggleAudioLevels()
        var extending = 0
        while !model.audioLevelsAreFullyShown, ContinuousClock.now - start < .seconds(2) {
            await settle(0.01)
            guard window.frame.height < shownHeight - 0.5 else { continue }
            extending += 1
            XCTAssertFalse(model.audioLevelsAreFullyShown, "Reported by an earlier toggle")
        }
        XCTAssertGreaterThan(extending, 3, "The window should animate")
        XCTAssertTrue(model.audioLevelsAreFullyShown)
        XCTAssertEqual(window.frame.height, shownHeight, accuracy: 0.5)
        XCTAssertEqual(source.reads, 1, "Only the last show's report reads")
        try await model.shutdown()
    }

    func testReduceMotionMeasuresOnlyOnceTheMetersHaveFadedIn() async throws {
        let source = UILevelSource()
        let model = await fullScalePlayer(source)
        let window = await playerWindow(for: model, reduceMotion: true)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        let closedFrame = window.frame
        let shownFrame = PlayerWindow.resizedFrame(
            from: closedFrame, closedHeight: closedFrame.height, showingAudioLevels: true, visibleFrame: nil
        )

        // Showing them again while they fade out restarts the fade-in; only its end reports.
        model.toggleAudioLevels()
        await settle(0.05)
        model.toggleAudioLevels()
        await settle(0.1)
        let start = ContinuousClock.now
        model.toggleAudioLevels()
        var fading = 0
        while !model.audioLevelsAreFullyShown, ContinuousClock.now - start < .seconds(2) {
            XCTAssertEqual(source.reads, 0, "Read while the meters fade in")
            XCTAssertEqual(litBarPoints(in: host, closedHeight: closedFrame.height), 0, "Lit while fading in")
            await model.refreshPlayback()
            await settle(0.02)
            fading += 1
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .seconds(PlayerView.audioLevelsAnimationDuration))
        XCTAssertGreaterThan(fading, 3)
        XCTAssertTrue(model.audioLevelsAreFullyShown)
        XCTAssertEqual(window.frame, shownFrame)
        XCTAssertGreaterThan(source.reads, 0)
        await model.refreshPlayback()
        await settle(0.1)
        XCTAssertGreaterThan(litBarPoints(in: host, closedHeight: closedFrame.height), 1_000)

        model.toggleAudioLevels()
        XCTAssertFalse(model.audioLevelsAreFullyShown)
        let reads = source.reads
        await model.refreshPlayback()
        await settle(0.05)
        XCTAssertEqual(window.frame, shownFrame, "The meters fade before the window shrinks")
        XCTAssertEqual(litBarPoints(in: host, closedHeight: closedFrame.height), 0, "Lit while fading out")
        await model.refreshPlayback()
        await settle(0.4)
        XCTAssertEqual(window.frame, closedFrame)
        XCTAssertFalse(model.audioLevelsAreFullyShown)
        XCTAssertEqual(source.reads, reads, "Read while fading out or closed")
        try await model.shutdown()
    }

    func testAudioLevelsLightWhilePlayingAndDarkenWhenPaused() async throws {
        let source = UILevelSource()
        let model = PlayerModel(engine: UIEngine(), audioLevelSource: source, automaticallyMonitor: false,
                                outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore())
        await model.inspectOutput()
        await model.togglePlayback()
        await model.refreshPlayback()
        XCTAssertEqual(model.state, .playing)
        let window = await playerWindow(for: model, reduceMotion: false)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)

        model.toggleAudioLevels()
        await settle(0.4)
        let silent = litMeterPixels(in: host)

        // Nothing published changes here, so only the meters' timed reads can show the new level.
        source.level = AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768)
        for _ in 0..<4 {
            await model.refreshPlayback()
            await settle(0.1)
        }
        let lit = litMeterPixels(in: host)
        XCTAssertGreaterThan(lit, silent + 1_000)
        attach(host, name: "Audio levels at full scale")

        await model.togglePlayback()
        XCTAssertEqual(model.state, .paused)
        await settle(0.2)
        XCTAssertLessThan(litMeterPixels(in: host), lit - 1_000)
        try await model.shutdown()
    }

    func testAudioLevelPeakHoldIsThePowerButtonRed() async throws {
        let source = UILevelSource()
        let model = PlayerModel(engine: UIEngine(), audioLevelSource: source, automaticallyMonitor: false,
                                outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore())
        await model.inspectOutput()
        await model.togglePlayback()
        await model.refreshPlayback()
        XCTAssertEqual(model.state, .playing)
        let window = await playerWindow(for: model, reduceMotion: false)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        model.toggleAudioLevels()
        await settle(0.4)
        let silent = litMeterPixels(in: host)
        XCTAssertNil(drawnPeakHold(in: host), "Silent meters have no hold")

        // −6 dBFS lights 13 of the 20 segments, and the top one is the hold.
        // Segments are about 17 pt wide and 2 pt apart.
        source.level = AudioLevelPeaks(leftPeak: 16_423, rightPeak: 16_423)
        await model.refreshPlayback()
        await settle(0.1)
        let peak = try XCTUnwrap(drawnPeakHold(in: host), "No hold at a new peak")
        attach(host, name: "Peak hold at a new peak")
        XCTAssertEqual(peak.span.upperBound - peak.span.lowerBound, 17, accuracy: 1.5, "One segment")
        XCTAssertLessThanOrEqual(peak.span.lowerBound - peak.barEnd, 3, "The hold caps the bar")
        XCTAssertEqual(peak.colour, try XCTUnwrap(powerButtonRed(in: host)), "The power button's red")

        // With no further poll the position stops 0.2 s later, so the bar falls while the hold stays.
        source.level = AudioLevelPeaks(leftPeak: 0, rightPeak: 0)
        await settle(0.6)
        let falling = try XCTUnwrap(drawnPeakHold(in: host), "The hold went before 1.5 s")
        attach(host, name: "Peak hold above the falling bar")
        XCTAssertEqual(falling.span, peak.span, "The hold stays put")
        XCTAssertGreaterThan(falling.span.lowerBound - falling.barEnd, 17, "Unlit segments below the hold")
        XCTAssertEqual(falling.colour, peak.colour)

        await settle(1.3)
        XCTAssertNil(drawnPeakHold(in: host), "The hold should drop after 1.5 s")
        XCTAssertGreaterThan(litMeterPixels(in: host), silent + 100, "The bar is still falling")
        try await model.shutdown()
    }

    func testAudioLevelScaleLabelsSitUnderTheSegmentsTheyLight() throws {
        let labels = PlayerView.audioLevelScaleLabels
        XCTAssertEqual(labels.count, AudioLevelMeter.segmentThresholds.count)
        let labelled = labels.indices.filter { labels[$0] != nil }
        XCTAssertEqual(labelled, [0, 5, 10, 12, 15, 17, 19])
        XCTAssertEqual(labelled.compactMap { labels[$0] }, ["-40", "-20", "-10", "-6", "-3", "-1", "0"])
        for index in labelled {
            // A level at the label's value lights its segment as the top one.
            let level = try XCTUnwrap(labels[index].flatMap { Double($0) })
            XCTAssertEqual(AudioLevelMeter.segmentCount(for: level), index + 1)
        }
    }

    func testAudioLevelsViewCommandTitleAndShortcutWithoutADisc() async throws {
        let model = PlayerModel(
            engine: UIEngine(), automaticallyMonitor: false, opticalService: UIOpticalService(drives: []),
            outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore()
        )
        XCTAssertNil(model.disc)
        XCTAssertEqual(AudioLevelsCommand.title(showsAudioLevels: false), "Show Audio Levels")
        XCTAssertEqual(AudioLevelsCommand.title(showsAudioLevels: true), "Hide Audio Levels")
        XCTAssertEqual(AudioLevelsCommand.shortcut, KeyboardShortcut("l"))
        model.toggleAudioLevels()
        XCTAssertTrue(model.showsAudioLevels)
        XCTAssertEqual(AudioLevelsCommand.title(showsAudioLevels: model.showsAudioLevels), "Hide Audio Levels")
        try await model.shutdown()
    }

    func testAudioLevelsAreHiddenFromVoiceOverUntilShown() async throws {
        let model = PlayerModel(
            engine: UIEngine(), automaticallyMonitor: false, opticalService: UIOpticalService(drives: []),
            outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore()
        )
        let window = await playerWindow(for: model, reduceMotion: false)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        await settle(0.1)
        let meter = try XCTUnwrap(audioLevelsAccessibilityElement(in: host))
        XCTAssertEqual(meter.accessibilityLabel(), "Audio levels")
        XCTAssertTrue(meter.isAccessibilityHidden())

        model.toggleAudioLevels()
        await settle(PlayerView.audioLevelsAnimationDuration + 0.1)
        XCTAssertFalse(meter.isAccessibilityHidden())

        model.toggleAudioLevels()
        await settle(PlayerView.audioLevelsAnimationDuration + 0.1)
        XCTAssertTrue(try XCTUnwrap(audioLevelsAccessibilityElement(in: host)).isAccessibilityHidden())
        try await model.shutdown()
    }

    func testAudioLevelsMoveTheWindowUpToStayOnScreen() {
        let closedFrame = NSRect(x: 0, y: 21, width: 426, height: 150)
        let visibleFrame = NSRect(x: 0, y: 20, width: 1_000, height: 800)
        let shownFrame = PlayerWindow.resizedFrame(
            from: closedFrame, closedHeight: 150, showingAudioLevels: true, visibleFrame: visibleFrame
        )
        XCTAssertEqual(PlayerView.audioLevelsAddedHeight, 52)
        XCTAssertEqual(shownFrame.minY, visibleFrame.minY, accuracy: 0.01)
        XCTAssertEqual(shownFrame.height, 150 + PlayerView.audioLevelsAddedHeight, accuracy: 0.01)
        XCTAssertGreaterThan(shownFrame.maxY, closedFrame.maxY)

        let hiddenAgain = PlayerWindow.resizedFrame(
            from: shownFrame, closedHeight: 150, showingAudioLevels: false, visibleFrame: visibleFrame
        )
        XCTAssertEqual(hiddenAgain.maxY, shownFrame.maxY, accuracy: 0.01)
        XCTAssertEqual(hiddenAgain.height, 150, accuracy: 0.01)

        // Heights are absolute, so a frame caught mid-animation still lands exactly.
        let midway = NSRect(x: 0, y: 400, width: 426, height: 191)
        let settled = PlayerWindow.resizedFrame(
            from: midway, closedHeight: 150, showingAudioLevels: false, visibleFrame: nil
        )
        XCTAssertEqual(settled, NSRect(x: 0, y: 441, width: 426, height: 150))
    }

    private func playerWindow(
        for model: PlayerModel, reduceMotion: Bool,
        isMeterWindowVisible: (@MainActor (NSWindow) -> Bool)? = nil
    ) async -> PlayerWindow {
        let visibilityProbe = isMeterWindowVisible ?? { window in
            window.isVisible && !window.isMiniaturized &&
                NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        }
        let window = PlayerWindow(
            player: model, reduceMotion: { reduceMotion }, isMeterWindowVisible: visibilityProbe
        )
        // `center()` picks the display in use, so pixel checks would vary with it; always use the sharpest.
        if let visible = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor })?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: (visible.midX - window.frame.width / 2).rounded(),
                                          y: (visible.midY - window.frame.height / 2).rounded()))
        } else {
            window.center()
        }
        window.orderFrontRegardless()
        await settle(0.15)
        return window
    }

    /// A player playing the demo at full scale on both channels, so measured meters light every segment.
    private func fullScalePlayer(_ source: UILevelSource) async -> PlayerModel {
        source.level = AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768)
        let model = PlayerModel(engine: UIEngine(), audioLevelSource: source, automaticallyMonitor: false,
                                outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore())
        await model.inspectOutput()
        await model.togglePlayback()
        await model.refreshPlayback()
        XCTAssertEqual(model.state, .playing)
        return model
    }

    /// An async test runs inside a main-queue callout, where `wait()` never drains the main queue.
    /// Suspending lets the window's main-queue work, animations and the meters' timer run.
    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The panel fills the window with the display pinned to the top. A gap would show the transparent
    /// window, and a clipped or shifted display would lose its white top border from the first row.
    private func assertPanelFillsWindow(
        _ view: NSView, settled: Bool, _ phase: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let column = middleColumn(in: view)
        XCTAssertEqual(column.first.map(isWhite), true, "\(phase): display top border", file: file, line: line)
        // Mid-animation the window's height can end partway through the last pixel row. A gap shows nothing,
        // where the panel's fill is at least its translucent opacity.
        let panelAlpha = PanelTransparency().opacity(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        XCTAssertTrue(column.dropLast().allSatisfy { $0.alphaComponent > panelAlpha - 0.02 }, "\(phase): gap",
                      file: file, line: line)
        if settled {
            XCTAssertEqual(column.last.map(isWhite), true, "\(phase): panel bottom border", file: file, line: line)
        }
    }

    /// The middle pixel column, top to bottom.
    private func middleColumn(in view: NSView) -> [NSColor] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let x = bitmap.pixelsWide / 2
        let transparent = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
        return (0..<bitmap.pixelsHigh).map { y in
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? transparent
        }
    }

    private func isWhite(_ color: NSColor) -> Bool {
        color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9
    }

    /// Pixels below the transport buttons drawn in the display tint: labels, plus every lit segment.
    private func litMeterPixels(in view: NSView) -> Int {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let meterRows = Int(((PlayerView.audioLevelsAddedHeight + PlayerView.padding) * scale).rounded())
        var count = 0
        for y in (bitmap.pixelsHigh - meterRows)..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if isDisplayTint(color) { count += 1 }
            }
        }
        return count
    }

    private func isDisplayTint(_ color: NSColor) -> Bool {
        color.greenComponent > 0.75 && color.redComponent > 0.45 && color.redComponent < color.greenComponent
            && color.blueComponent < color.greenComponent
    }

    /// Points of the L and R bars drawn lit, in the display tint or the peak hold's red, sampled once per
    /// point. The legend and scale lie outside the bars, so dark meters count zero.
    private func litBarPoints(in view: NSView, closedHeight: CGFloat) -> Int {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        // The meters start a row gap below the transport buttons. The two 12 pt bars and the 4 pt between
        // them come first, and each bar starts after its legend column and gap.
        let top = closedHeight - PlayerView.padding + PlayerView.audioLevelsAddedHeight - PlayerView.audioLevelsHeight
        var count = 0
        for y in stride(from: top, to: min(top + 28, view.bounds.height), by: 1) {
            for x in stride(from: PlayerView.padding + 15, to: view.bounds.width - PlayerView.padding, by: 1) {
                guard let color = bitmap.colorAt(x: Int((x + 0.5) * scale), y: Int((y + 0.5) * scale))?
                    .usingColorSpace(.deviceRGB) else { continue }
                if isDisplayTint(color) || isPowerRed(color) { count += 1 }
            }
        }
        return count
    }

    private func audioLevelsAccessibilityElement(in view: NSView) -> NSView? {
        if view.accessibilityLabel() == "Audio levels" { return view }
        return view.subviews.lazy.compactMap { self.audioLevelsAccessibilityElement(in: $0) }.first
    }

    private func isPowerRed(_ color: NSColor) -> Bool {
        color.redComponent > 0.75 && color.greenComponent < 0.4 && color.blueComponent < 0.45
    }

    private func eightBit(_ color: NSColor) -> [Int] {
        [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    /// The meters' red pixels, which only the peak hold draws. Positions are in points from the left.
    private struct DrawnPeakHold {
        let span: ClosedRange<CGFloat>
        /// The right end of the mint bar in the hold's pixel rows.
        let barEnd: CGFloat
        /// The hold's most common colour, as 8-bit device RGB.
        let colour: [Int]
    }

    private func drawnPeakHold(in view: NSView) -> DrawnPeakHold? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let meterRows = Int(((PlayerView.audioLevelsAddedHeight + PlayerView.padding) * scale).rounded())
        var red: [Int] = []
        var barEnd = 0
        var colours: [[Int]: Int] = [:]
        for y in (bitmap.pixelsHigh - meterRows)..<bitmap.pixelsHigh {
            var rowRed: [Int] = []
            var rowBarEnd = 0
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if isPowerRed(color) {
                    rowRed.append(x)
                    colours[eightBit(color), default: 0] += 1
                } else if isDisplayTint(color) {
                    rowBarEnd = x + 1
                }
            }
            guard !rowRed.isEmpty else { continue }
            red += rowRed
            barEnd = max(barEnd, rowBarEnd)
        }
        guard let first = red.min(), let last = red.max(),
              let colour = colours.max(by: { $0.value < $1.value })?.key else { return nil }
        return DrawnPeakHold(span: CGFloat(first) / scale...CGFloat(last + 1) / scale,
                             barEnd: CGFloat(barEnd) / scale, colour: colour)
    }

    /// The power icon's most common colour, as 8-bit device RGB. It is the only red in the top-right corner.
    private func powerButtonRed(in view: NSView) -> [Int]? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        var colours: [[Int]: Int] = [:]
        for y in 0..<Int(40 * scale) {
            for x in Int((view.bounds.width - 60) * scale)..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      isPowerRed(color) else { continue }
                colours[eightBit(color), default: 0] += 1
            }
        }
        return colours.max(by: { $0.value < $1.value })?.key
    }

    func testOutputNameUsesAtMostHalfOfRowTwo() async throws {
        let model = PlayerModel(engine: UIEngine(output: longNameOutput), automaticallyMonitor: false,
                                outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore())
        await model.inspectOutput()
        let host = NSHostingView(rootView: PlayerView(player: model))
        host.frame.size = host.fittingSize
        let window = window(for: host)
        defer { window.close() }
        wait(0.3)
        XCTAssertEqual(model.statusText, "DEMO READY")
        XCTAssertTrue(model.showsOutputRateSwitch)
        let line = try XCTUnwrap(descendant(OutputStatusLineView.self, in: host))
        XCTAssertEqual(PlayerView.rowWidth, 390)
        XCTAssertEqual(line.bounds.width, 368, accuracy: 0.5)
        XCTAssertEqual(line.nameSpace.frame.width, PlayerView.rowWidth / 2, accuracy: 0.01)
        XCTAssertEqual(line.nameSpace.frame.maxX, line.indicatorLayer.frame.minX, accuracy: 0.01)
        XCTAssertEqual(line.indicatorLayer.frame.maxX, 368, accuracy: 0.5)
        XCTAssertGreaterThan(line.nameSpace.frame.minX, line.statusLayer.frame.maxX + OutputLineLayout.gap)
        XCTAssertNotNil(line.scroller.animation(forKey: OutputStatusLineView.scrollKey))
        XCTAssertEqual(line.selectorFrame.minX, line.nameSpace.frame.minX, accuracy: 0.01)
        attach(host, name: "Long output name capped at half of row 2")
        try await model.shutdown()
    }

    func testLongDriveNamesWithAndWithoutDriveSelector() async throws {
        let table = try CDTableOfContents(data: Data(
            [0, 46, 1, 1] +
            [1, 16, 0, 0xA0, 0, 0, 0, 0, 1, 0, 0] +
            [1, 16, 0, 0xA1, 0, 0, 0, 0, 1, 0, 0] +
            [1, 16, 0, 0xA2, 0, 0, 0, 0, 0, 32, 0] +
            [1, 16, 0, 1, 0, 0, 0, 0, 0, 2, 0]
        ))
        let media = OpticalMedia(id: 10, bsdName: "fixture", contents: .audioCD(table),
                                 isMounted: false, isEjectable: true)
        for count in [1, 2] {
            let service = UIOpticalService(drives: (1...count).map {
                OpticalDrive(id: UInt64($0), name: "PIONEER BD-RW VERY LONG OPTICAL DRIVE NAME BDR-XS07U",
                             media: media)
            })
            let model = PlayerModel(engine: UIEngine(), automaticallyMonitor: false,
                                    opticalService: service, outputRateControl: UIRateControl(),
                                    outputSelectionStore: UISelectionStore())
            model.startOpticalMonitoring()
            await model.inspectOutput()
            let host = NSHostingView(rootView: PlayerView(player: model))
            host.frame.size = host.fittingSize
            let window = window(for: host)
            wait()
            XCTAssertEqual(host.fittingSize.width, 426, accuracy: 0.5)
            XCTAssertEqual(model.showsDriveSelector, count == 2)
            XCTAssertEqual(model.formatText, "44.1 kHz / 16-bit source")
            XCTAssertEqual(model.state, .ready)
            attach(host, name: "Long drive, \(count) drives")
            window.close()
            try await model.shutdown()
        }
    }

    private func attach(_ view: NSView, name: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Cannot capture \(name)"); return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}

@MainActor
private final class MenuProbe: NSObject {
    var didOpen = false
    @objc func opened(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu.title == "Audio output" else { return }
        didOpen = true
        let timer = Timer(timeInterval: 0.1, target: menu, selector: #selector(NSMenu.cancelTracking),
                          userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
}

private let testOutput = OutputInfo(
    deviceID: 1, name: "MacBook Pro Speakers", sampleRate: 48_000, hogOwner: -1,
    supportsSourceRate: true, usesSpeakers: true, restoreRate: 48_000
)
private let longNameOutput = OutputInfo(
    deviceID: 1, name: "Pioneer USB Audio Device With A Long Product Name", sampleRate: 48_000, hogOwner: -1,
    supportsSourceRate: true, usesSpeakers: false, restoreRate: 48_000
)
private struct UIAdvancingEngine: PlaybackEngine {
    let began = ContinuousClock.now
    var output = testOutput
    func inspectOutput(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo { output }
    func start(at frame: UInt64, on target: OutputTarget) async throws -> OutputInfo { output }
    func snapshot() async throws -> PlaybackSnapshot { .init(currentFrame: frame()) }
    func stop() async throws -> PlaybackSnapshot { .init(currentFrame: frame()) }
    private func frame() -> UInt64 { UInt64((ContinuousClock.now - began) / .seconds(1) * 44_100) }
}

private struct UIEngine: PlaybackEngine {
    var output = testOutput
    func inspectOutput(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo { output }
    func start(at frame: UInt64, on target: OutputTarget) async throws -> OutputInfo { output }
    func snapshot() async throws -> PlaybackSnapshot { .init(currentFrame: 0) }
    func stop() async throws -> PlaybackSnapshot { .init(currentFrame: 0) }
}
private struct UIRateControl: OutputRateControl {
    func matchSourceRate(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo { testOutput }
    func restoreRate(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo { testOutput }
    func restoreChangedRates() async throws {}
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Keeps the app's saved output choice out of the fixtures.
@MainActor private final class UISelectionStore: OutputSelectionStore {
    private(set) var selectedID: OutputChoice.ID?
    func save(_ id: OutputChoice.ID) { selectedID = id }
}

@MainActor private final class UIWindowVisibilityProbe {
    var isOccluded = false
    var isApplicationHidden = false
}

/// Reports the same peaks for any position, and counts the meters' reads.
private final class UILevelSource: AudioLevelSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current = AudioLevelPeaks(leftPeak: 0, rightPeak: 0)
    private var readCount = 0
    var level: AudioLevelPeaks {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); defer { lock.unlock() }; current = newValue }
    }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    func peaks(fromFrame: UInt64, throughFrame: UInt64) -> AudioLevelPeaks? {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return current
    }
}

@MainActor private final class UIOpticalService: OpticalDriveService {
    let drives: [OpticalDrive]
    init(drives: [OpticalDrive]) { self.drives = drives }
    func start(onChange: @escaping @MainActor (OpticalSnapshot) -> Void) throws {
        onChange(OpticalSnapshot(drives: drives))
    }
    func refresh() {}
    func stop() {}
    func eject(media: OpticalMedia, from driveID: UInt64) async throws {
        XCTFail("UI fixtures must never eject")
    }
}

private extension PlayerModel {
    static func offline() -> PlayerModel {
        PlayerModel(
            engine: UIEngine(), audioLevelSource: UILevelSource(), automaticallyMonitor: false,
            discOpener: UIDiscOpener(), makeDiscEngine: { _ in
                XCTFail("Appearance tests must not open a disc engine")
                return UIEngine()
            },
            outputRateControl: UIRateControl(), outputSelectionStore: UISelectionStore(),
            hdcdDecodePreferenceStore: UIHDCDPreference(), volumeMirror: UIVolumeMirror(),
            sleepPrevention: UISleepPrevention(), powerMonitor: UIPowerMonitor()
        )
    }
}

private struct UIDiscOpener: DiscOpener {
    struct UnexpectedDiscAccess: Error {}
    func open(_ media: OpticalMedia, driveID: UInt64) throws -> any CDSectorSource {
        XCTFail("Appearance tests must not open a disc")
        throw UnexpectedDiscAccess()
    }
}

@MainActor private final class UIHDCDPreference: HDCDDecodePreferenceStore {
    var isEnabled = true
    func save(isEnabled: Bool) { self.isEnabled = isEnabled }
}

private final class UIVolumeMirror: VolumeMirroring {
    func mirror(_ pair: VolumeMirrorPair?) {}
}

@MainActor private final class UISleepPrevention: SleepPreventing {
    func setActive(_ active: Bool) {}
}

private struct UIPowerMonitor: SystemPowerMonitoring {
    func events() -> AsyncStream<SystemPowerEvent> { AsyncStream { $0.finish() } }
}
