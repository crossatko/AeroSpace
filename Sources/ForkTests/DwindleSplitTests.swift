@testable import AppBundle
import Common
import Testing

// Swift Testing suite that runs without XCTest (toolchains without Xcode).
// The full tree tests live in AppBundleTests/tree/DwindleTest.swift
@Suite struct DwindleSplitTests {
    @Test func wideRectSplitsHorizontally() {
        #expect(dwindleSplit(Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600), fallback: .v) == .h)
    }

    @Test func tallRectSplitsVertically() {
        #expect(dwindleSplit(Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 800), fallback: .h) == .v)
    }

    @Test func squareSplitsHorizontally() {
        #expect(dwindleSplit(Rect(topLeftX: 0, topLeftY: 0, width: 700, height: 700), fallback: .v) == .h)
    }

    @Test func missingRectUsesFallback() {
        #expect(dwindleSplit(nil, fallback: .v) == .v)
        #expect(dwindleSplit(nil, fallback: .h) == .h)
    }

    @MainActor @Test func configKey() {
        #expect(parseConfig("dwindle = true").config.dwindle == true)
        #expect(parseConfig("").config.dwindle == false)
    }
}
