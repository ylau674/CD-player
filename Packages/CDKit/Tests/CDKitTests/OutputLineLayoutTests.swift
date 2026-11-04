import Testing
@testable import CDKit

private let characterWidth = 6.2
private func measure(_ text: String) -> Double { Double(text.count) * characterWidth }
private let indicatorWidth = measure(OutputLineLayout.indicator)

@Test func outputLineKeepsFittingStatusAndNameAtOppositeEnds() {
    let line = OutputLineLayout(
        status: "CD PLAYING", name: "MacBook Pro Speakers", width: 390, reduceMotion: false,
        measure: measure
    )

    #expect(line.mode == .fitted)
    #expect(line.status == "CD PLAYING")
    #expect(line.name == "MacBook Pro Speakers")
    #expect(line.indicatorX == 390 - indicatorWidth)
    #expect(line.nameX == line.indicatorX - line.nameWidth)
    #expect(line.nameSpaceWidth == line.nameWidth)
    #expect(line.nameX > line.statusWidth)
    #expect(line.cycle == 0)
    #expect(line.duration == 0)
}

@Test func outputLineMatchesRoadmapFitAtTheAvailableWidth() {
    let status = "CD PLAYING | ERR 12 | UNVERIFIED"
    let builtIn = OutputLineLayout(
        status: status, name: "MacBook Pro Speakers", width: 368, reduceMotion: false,
        measure: measure
    )
    let external = OutputLineLayout(
        status: status, name: "Pioneer USB Audio Device", width: 368, reduceMotion: false,
        measure: measure
    )

    #expect(builtIn.mode == .fitted)
    #expect(external.mode == .scrolling)
    #expect(external.statusWidth + OutputLineLayout.gap + external.nameWidth + indicatorWidth > 368)
}

@Test func outputLineScrollsOnlyTheNameBetweenTheFixedStatusAndIndicator() {
    let line = OutputLineLayout(
        status: "CD PLAYING | ERR 12 | UNVERIFIED",
        name: "Pioneer USB Audio Device", width: 360, reduceMotion: false, measure: measure
    )

    #expect(line.mode == .scrolling)
    #expect(line.status == "CD PLAYING | ERR 12 | UNVERIFIED")
    #expect(line.name == "Pioneer USB Audio Device")
    #expect(line.nameX == line.statusWidth + OutputLineLayout.gap)
    #expect(line.indicatorX == 360 - indicatorWidth)
    #expect(line.nameSpaceWidth < line.nameWidth)
    #expect(line.selectorWidth == 360 - line.nameX)
    #expect(line.cycle == line.nameWidth + OutputLineLayout.loopGap)
    #expect(line.duration == OutputLineLayout.pause + line.cycle / OutputLineLayout.speed)
}

@Test func outputLineWithReduceMotionTruncatesOnlyWhenItDoesNotFit() {
    let line = OutputLineLayout(
        status: "CD PLAYING | ERR 12 | UNVERIFIED",
        name: "Pioneer USB Audio Device", width: 360, reduceMotion: true, measure: measure
    )

    #expect(line.mode == .truncated)
    #expect(line.status == "CD PLAYING | ERR 12 | UNVERIFIED")
    #expect(line.name.contains("…"))
    #expect(!line.name.contains("▾"))
    #expect(line.indicatorX == 360 - indicatorWidth)
    #expect(line.nameX + line.nameWidth == line.indicatorX)
    #expect(line.statusWidth + OutputLineLayout.gap + line.nameWidth + indicatorWidth <= 360)
    #expect(line.offset(at: 10) == 0)
}

@Test func outputLineStatusUpdateMovesOnlyTheStartOfTheNameSpace() {
    let previous = OutputLineLayout(
        status: "CD PLAYING", name: "Pioneer USB Audio Device", width: 220, reduceMotion: false,
        measure: measure
    )
    let updated = OutputLineLayout(
        status: "CD PLAYING | ERR 1", name: "Pioneer USB Audio Device", width: 220, reduceMotion: false,
        measure: measure
    )
    let renamed = OutputLineLayout(
        status: "CD PLAYING | ERR 1", name: "Pioneer USB Audio DEVICE", width: 220, reduceMotion: false,
        measure: measure
    )

    #expect(previous.mode == .scrolling)
    #expect(updated.status == "CD PLAYING | ERR 1")
    #expect(updated.scrollsLike(previous))
    #expect(updated.nameX > previous.nameX)
    #expect(updated.indicatorX == previous.indicatorX)
    #expect(updated.offset(at: OutputLineLayout.pause + 1) == OutputLineLayout.speed)
    #expect(!renamed.scrollsLike(updated))
}

@Test func outputLineStatusGivesWayOnlyToKeepTheShortestName() {
    let status = "[ERR] Access denied | ERR 123456 | UNVERIFIED"
    let long = OutputLineLayout(
        status: status, name: "Pioneer USB Audio Device", width: 300, reduceMotion: false, measure: measure
    )
    let short = OutputLineLayout(status: status, name: "N-50", width: 300, reduceMotion: false, measure: measure)
    let roomy = OutputLineLayout(status: status, name: "Pioneer USB Audio Device", width: 368,
                                 reduceMotion: false, measure: measure)

    #expect(long.mode == .scrolling)
    #expect(long.status.hasSuffix("…"))
    #expect(long.nameSpaceWidth >= measure("Pio…ice"))
    #expect(long.statusWidth + OutputLineLayout.gap + long.nameSpaceWidth + indicatorWidth <= 300)
    #expect(short.mode == .fitted)
    #expect(short.status.hasSuffix("…"))
    #expect(short.name == "N-50")
    #expect(short.nameX + short.nameWidth == short.indicatorX)
    #expect(roomy.mode == .scrolling)
    #expect(roomy.status == status)
}

@Test func outputLineShowsTheNameInAtMostItsMaximumWidth() {
    let half = 195.0
    let longName = "Pioneer USB Audio Device With A Long Product Name"
    let scrolling = OutputLineLayout(status: "DEMO READY", name: longName, width: 368,
                                     maximumNameWidth: half, reduceMotion: false, measure: measure)
    let truncated = OutputLineLayout(status: "DEMO READY", name: longName, width: 368,
                                     maximumNameWidth: half, reduceMotion: true, measure: measure)
    let usual = OutputLineLayout(status: "DEMO READY", name: "Pioneer USB Audio Device", width: 368,
                                 maximumNameWidth: half, reduceMotion: false, measure: measure)
    let exact = String(repeating: "x", count: Int(half / characterWidth))
    let atLimit = OutputLineLayout(status: "DEMO READY", name: exact, width: 368,
                                   maximumNameWidth: measure(exact), reduceMotion: false, measure: measure)
    let overLimit = OutputLineLayout(status: "DEMO READY", name: exact, width: 368,
                                     maximumNameWidth: measure(exact) - 0.1, reduceMotion: false, measure: measure)
    let crowded = OutputLineLayout(status: "CD PLAYING | ERR 12 | UNVERIFIED", name: longName, width: 368,
                                   maximumNameWidth: half, reduceMotion: false, measure: measure)

    #expect(scrolling.mode == .scrolling)
    #expect(scrolling.status == "DEMO READY")
    #expect(scrolling.nameSpaceWidth == half)
    #expect(scrolling.indicatorX == 368 - indicatorWidth)
    #expect(scrolling.nameX == scrolling.indicatorX - half)
    #expect(scrolling.nameX > scrolling.statusWidth + OutputLineLayout.gap)
    #expect(scrolling.cycle == scrolling.nameWidth + OutputLineLayout.loopGap)
    #expect(truncated.mode == .truncated)
    #expect(truncated.name.contains("…"))
    #expect(truncated.nameWidth <= half)
    #expect(truncated.nameX + truncated.nameWidth == truncated.indicatorX)
    #expect(usual.mode == .fitted)
    #expect(usual.name == "Pioneer USB Audio Device")
    #expect(atLimit.mode == .fitted)
    #expect(overLimit.mode == .scrolling)
    #expect(crowded.mode == .scrolling)
    #expect(crowded.status == "CD PLAYING | ERR 12 | UNVERIFIED")
    #expect(crowded.nameSpaceWidth < half)
    #expect(crowded.nameX == crowded.statusWidth + OutputLineLayout.gap)
}

@Test func outputLinePauseLoopAndExactFitBoundaries() {
    let text = "CD PLAYING | ERR 12 | UNVERIFIED"
    let name = "Pioneer USB Audio Device"
    let exactWidth = measure(text) + OutputLineLayout.gap + measure(name) + indicatorWidth
    let fit = OutputLineLayout(status: text, name: name, width: exactWidth,
                               reduceMotion: false, measure: measure)
    let scroll = OutputLineLayout(status: text, name: name, width: exactWidth - 0.1,
                                  reduceMotion: false, measure: measure)
    let unlaid = OutputLineLayout(status: text, name: name, width: 0, reduceMotion: false, measure: measure)
    #expect(fit.mode == .fitted)
    #expect(scroll.mode == .scrolling)
    #expect(unlaid.mode == .fitted)
    #expect(scroll.offset(at: -1) == 0)
    #expect(scroll.offset(at: OutputLineLayout.pause) == 0)
    #expect(scroll.offset(at: scroll.duration) == 0)
    #expect(scroll.scrollsLike(scroll))
    #expect(!fit.scrollsLike(scroll))
    #expect(!scroll.scrollsLike(fit))
}
