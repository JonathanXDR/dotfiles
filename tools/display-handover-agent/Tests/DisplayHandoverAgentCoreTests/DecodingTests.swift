import Foundation
import Testing
@testable import DisplayHandoverAgentCore

@Suite struct MonitorInputTests {
    @Test(arguments: [
        (0x1919, MonitorInput.thunderbolt),
        (0x1911, .hdmi),
        (0x0019, .thunderbolt),
        (0x0011, .hdmi),
        (0x0F0F, .displayPort),
        (0x1212, .other(0x12)),
    ])
    func decodesDellInputCodes(raw: Int, expected: MonitorInput) {
        #expect(MonitorInput(vcp60: raw) == expected)
    }

    @Test(arguments: [-1, 0x10000])
    func rejectsMalformedValues(raw: Int) {
        #expect(MonitorInput(vcp60: raw) == nil)
    }
}

@Suite struct SyncBoxStatusTests {
    private func state(mode: String, source: String, input1: String, input2: String, output: String) -> Data {
        Data("""
        {"device": {"name": "Sync Box"},
         "execution": {"mode": "\(mode)", "hdmiSource": "\(source)", "syncActive": false, "hdmiActive": true},
         "hdmi": {"input1": {"name": "Switch 2", "type": "game", "status": "\(input1)"},
                  "input2": {"name": "Apple TV", "type": "video", "status": "\(input2)"},
                  "input3": {"name": "HDMI 3", "type": "generic", "status": "unplugged"},
                  "input4": {"name": "HDMI 4", "type": "generic", "status": "unplugged"},
                  "output": {"name": "Dell", "type": "generic", "status": "\(output)"},
                  "contentSpecs": "3840 x 2160 @ 60000 - SDR", "videoSyncSupported": true}}
        """.utf8)
    }

    @Test func linkedSelectedInputIsActive() throws {
        let status = try SyncBoxStatus.parse(state(mode: "passthrough", source: "input2", input1: "plugged", input2: "linked", output: "linked"))
        #expect(status.selectedInput == "input2")
        #expect(status.selectedInputName == "Apple TV")
        #expect(status.signal == .active)
    }

    @Test func unselectedLinkedInputDoesNotCount() throws {
        let status = try SyncBoxStatus.parse(state(mode: "passthrough", source: "input2", input1: "linked", input2: "plugged", output: "linked"))
        #expect(status.signal == .inactive)
    }

    @Test func powersaveIsInactive() throws {
        let status = try SyncBoxStatus.parse(state(mode: "powersave", source: "input1", input1: "linked", input2: "plugged", output: "plugged"))
        #expect(status.signal == .inactive)
    }

    @Test func pluggedSelectedInputCountsOnlyOutsidePowersave() throws {
        #expect(try SyncBoxStatus.parse(state(mode: "passthrough", source: "input2", input1: "linked", input2: "plugged", output: "plugged")).selectedInputPlugged)
        #expect(try !SyncBoxStatus.parse(state(mode: "passthrough", source: "input1", input1: "unplugged", input2: "plugged", output: "plugged")).selectedInputPlugged)
        #expect(try !SyncBoxStatus.parse(state(mode: "powersave", source: "input2", input1: "unplugged", input2: "plugged", output: "plugged")).selectedInputPlugged)
        #expect(try !SyncBoxStatus.parse(state(mode: "video", source: "input2", input1: "plugged", input2: "linked", output: "linked")).selectedInputPlugged)
    }

    @Test func unexpectedStatusIsUnknown() throws {
        let status = try SyncBoxStatus.parse(state(mode: "video", source: "input1", input1: "unknown", input2: "plugged", output: "linked"))
        #expect(status.signal == .unknown)
    }

    @Test func rejectsDocumentsWithoutHDMIState() {
        #expect(throws: (any Error).self) { try SyncBoxStatus.parse(Data(#"{"device": {}}"#.utf8)) }
    }
}
