import XCTest

final class NarratorFactoryTests: XCTestCase {

    func testOnDeviceModeUsesFoundationModelsWhenAvailable() {
        let n = NarratorFactory.make(mode: .onDevice, onDeviceAvailable: true,
                                     apiKey: "", model: "m")
        XCTAssertTrue(n is FoundationModelsNarrator)
    }

    func testOnDeviceModeFallsBackToTemplateWhenUnavailable() {
        let n = NarratorFactory.make(mode: .onDevice, onDeviceAvailable: false,
                                     apiKey: "key", model: "m")
        XCTAssertTrue(n is TemplateNarrator)
    }

    func testOpenRouterModeNeedsKey() {
        let withKey = NarratorFactory.make(mode: .openRouter, onDeviceAvailable: true,
                                           apiKey: "key", model: "m")
        XCTAssertTrue(withKey is OpenRouterNarrator)
        let noKey = NarratorFactory.make(mode: .openRouter, onDeviceAvailable: true,
                                         apiKey: "", model: "m")
        XCTAssertTrue(noKey is TemplateNarrator)
    }

    func testAutoPrefersOnDeviceThenOpenRouterThenTemplate() {
        XCTAssertTrue(NarratorFactory.make(mode: .auto, onDeviceAvailable: true,
                                           apiKey: "key", model: "m") is FoundationModelsNarrator)
        XCTAssertTrue(NarratorFactory.make(mode: .auto, onDeviceAvailable: false,
                                           apiKey: "key", model: "m") is OpenRouterNarrator)
        XCTAssertTrue(NarratorFactory.make(mode: .auto, onDeviceAvailable: false,
                                           apiKey: "", model: "m") is TemplateNarrator)
    }
}
