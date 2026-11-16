import XCTest
@testable import SundialCore

final class SegmentGroupTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(_ start: TimeInterval, _ end: TimeInterval,
                         snapshot: Snapshot = Snapshot(bundleId: "com.openai.codex",
                                                       appName: "ChatGPT", windowTitle: "ChatGPT"),
                         state: TimeCategory = .work, ruleId: UUID? = nil,
                         reason: String = "Matched work rule", manual: Bool = false) -> Segment {
        Segment(start: base + start, end: base + end, state: state, snapshot: snapshot,
                ruleId: ruleId, reason: reason, manual: manual)
    }

    func testEmptyInputProducesNoGroups() {
        XCTAssertTrue(SegmentGroup.build(from: []).isEmpty)
    }

    func testSingleEntryPreservesItsDetails() throws {
        let entry = segment(0, 31)
        let group = try XCTUnwrap(SegmentGroup.build(from: [entry]).first)

        XCTAssertEqual(group.segments, [entry])
        XCTAssertEqual(group.first, entry)
        XCTAssertEqual(group.id, entry.id)
        XCTAssertEqual(group.start, entry.start)
        XCTAssertEqual(group.end, entry.end)
        XCTAssertEqual(group.duration, 31)
    }

    func testConsecutiveChatGPTAndFigmaEntriesCombineWithoutCountingGaps() {
        let figma = Snapshot(bundleId: "com.figma.Desktop", appName: "Figma",
                             windowTitle: "Double Shifts")
        let chatGPTFirst = segment(0, 31)
        let chatGPTSecond = segment(60, 85)
        let figmaFirst = segment(120, 143, snapshot: figma)
        let figmaSecond = segment(150, 178, snapshot: figma)

        let groups = SegmentGroup.build(from: [chatGPTFirst, chatGPTSecond, figmaFirst, figmaSecond])

        XCTAssertEqual(groups.map(\.segments), [[chatGPTFirst, chatGPTSecond], [figmaFirst, figmaSecond]])
        XCTAssertEqual(groups.map(\.duration), [56, 51])
        XCTAssertEqual(groups.map(\.start), [chatGPTFirst.start, figmaFirst.start])
        XCTAssertEqual(groups.map(\.end), [chatGPTSecond.end, figmaSecond.end])
        XCTAssertEqual(groups.map(\.id), [chatGPTFirst.id, figmaFirst.id])
    }

    func testAnInterveningAppKeepsRepeatedEntriesSeparate() {
        let first = segment(0, 30)
        let figma = segment(30, 60, snapshot: Snapshot(bundleId: "com.figma.Desktop", appName: "Figma"))
        let last = segment(60, 90)

        XCTAssertEqual(SegmentGroup.build(from: [first, figma, last]).map(\.segments),
                       [[first], [figma], [last]])
    }

    func testDifferentStatesStaySeparate() {
        let work = segment(0, 30)
        let personal = segment(30, 60, state: .personal)

        XCTAssertEqual(SegmentGroup.build(from: [work, personal]).map(\.segments), [[work], [personal]])
    }

    func testDifferentRulesStaySeparate() {
        let first = segment(0, 30, ruleId: UUID())
        let second = segment(30, 60, ruleId: UUID())

        XCTAssertEqual(SegmentGroup.build(from: [first, second]).map(\.segments), [[first], [second]])
    }

    func testDifferentReasonsStaySeparate() {
        let first = segment(0, 30, reason: "Matched work rule")
        let second = segment(30, 60, reason: "A call is active")

        XCTAssertEqual(SegmentGroup.build(from: [first, second]).map(\.segments), [[first], [second]])
    }

    func testDifferentWindowTitlesStaySeparate() {
        let first = segment(0, 30)
        let second = segment(30, 60, snapshot: Snapshot(bundleId: "com.openai.codex",
                                                       appName: "ChatGPT", windowTitle: "Another task"))

        XCTAssertEqual(SegmentGroup.build(from: [first, second]).map(\.segments), [[first], [second]])
    }

    func testDifferentBrowserProfilesStaySeparate() {
        let work = segment(0, 30, snapshot: Snapshot(bundleId: "app.zen-browser.zen", appName: "Zen",
                                                    host: "github.com", browserProfile: "Work"))
        let personal = segment(30, 60, snapshot: Snapshot(bundleId: "app.zen-browser.zen", appName: "Zen",
                                                         host: "github.com", browserProfile: "Personal"))

        XCTAssertEqual(SegmentGroup.build(from: [work, personal]).map(\.segments), [[work], [personal]])
    }

    func testDifferentPagesWithTheSameVisibleBrowserIdentityCombine() throws {
        let first = segment(0, 30, snapshot: Snapshot(bundleId: "app.zen-browser.zen", appName: "Zen",
                                                     url: "https://github.com/first", host: "github.com",
                                                     urlPath: "/first", browserProfile: "Work"))
        let second = segment(30, 60, snapshot: Snapshot(bundleId: "app.zen-browser.zen", appName: "Zen",
                                                      url: "https://github.com/second", host: "github.com",
                                                      urlPath: "/second", browserProfile: "Work"))

        let group = try XCTUnwrap(SegmentGroup.build(from: [first, second]).first)

        XCTAssertEqual(group.segments, [first, second])
        XCTAssertEqual(group.duration, 60)
    }

    func testProjectsWithTheSameNameButDifferentPathsStaySeparate() {
        let first = segment(0, 30, snapshot: Snapshot(bundleId: "com.microsoft.VSCode", appName: "Code",
                                                     projectName: "api", projectPath: "/work/api"))
        let second = segment(30, 60, snapshot: Snapshot(bundleId: "com.microsoft.VSCode", appName: "Code",
                                                      projectName: "api", projectPath: "/personal/api"))

        XCTAssertEqual(SegmentGroup.build(from: [first, second]).map(\.segments), [[first], [second]])
    }

    func testDifferentAppsWithTheSameProjectAndSummaryStaySeparate() {
        let first = segment(0, 30, snapshot: Snapshot(bundleId: "editor.stable", appName: "Code",
                                                     projectName: "api", projectPath: "/work/api"))
        let second = segment(30, 60, snapshot: Snapshot(bundleId: "editor.preview", appName: "Code",
                                                      projectName: "api", projectPath: "/work/api"))

        XCTAssertEqual(SegmentGroup.build(from: [first, second]).map(\.segments), [[first], [second]])
    }

    func testManualEntriesRemainIndividuallyEditable() {
        let observedFirst = segment(0, 30)
        let manualFirst = segment(30, 60, manual: true)
        let manualSecond = segment(60, 90, manual: true)
        let observedLast = segment(90, 120)
        let entries = [observedFirst, manualFirst, manualSecond, observedLast]

        XCTAssertEqual(SegmentGroup.build(from: entries).map(\.segments),
                       [[observedFirst], [manualFirst], [manualSecond], [observedLast]])
    }
}
