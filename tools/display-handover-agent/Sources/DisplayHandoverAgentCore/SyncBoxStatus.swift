import Foundation

public enum SourceSignal: String, Sendable {
    case active
    case inactive
    case unknown
}

public struct SyncBoxStatus: Equatable, Sendable {
    public var mode: String
    public var selectedInput: String
    public var selectedInputName: String?
    public var selectedInputStatus: String
    public var outputStatus: String
    public var contentSpecs: String?
    public var otherInputs: [String: String]

    public init(
        mode: String, selectedInput: String, selectedInputName: String? = nil,
        selectedInputStatus: String, outputStatus: String, contentSpecs: String? = nil,
        otherInputs: [String: String] = [:]
    ) {
        self.mode = mode
        self.selectedInput = selectedInput
        self.selectedInputName = selectedInputName
        self.selectedInputStatus = selectedInputStatus
        self.outputStatus = outputStatus
        self.contentSpecs = contentSpecs
        self.otherInputs = otherInputs
    }

    public var signal: SourceSignal {
        if mode == "powersave" { return .inactive }
        switch selectedInputStatus {
        case "linked": return .active
        case "plugged", "unplugged": return .inactive
        default: return .unknown
        }
    }

    /// A device is connected to the selected input but sends no video, as during an input change, a
    /// source restart or an Apple TV standby. In `powersave` every connected port reads `plugged`.
    public var selectedInputPlugged: Bool { mode != "powersave" && selectedInputStatus == "plugged" }

    public var summary: String {
        let name = selectedInputName.map { " (\($0))" } ?? ""
        return "mode=\(mode) source=\(selectedInput)\(name) input=\(selectedInputStatus) output=\(outputStatus)"
            + (contentSpecs.map { " specs=\($0)" } ?? "")
            + otherInputs.filter { $0.value != "unplugged" }.sorted { $0.key < $1.key }
                .map { " \($0.key)=\($0.value)" }.joined()
    }

    public static func parse(_ data: Data) throws -> SyncBoxStatus {
        let root = try JSONDecoder().decode(Root.self, from: data)
        let ports = [
            "input1": root.hdmi.input1, "input2": root.hdmi.input2,
            "input3": root.hdmi.input3, "input4": root.hdmi.input4,
        ]
        let selected = ports[root.execution.hdmiSource] ?? nil
        return SyncBoxStatus(
            mode: root.execution.mode,
            selectedInput: root.execution.hdmiSource,
            selectedInputName: selected?.name,
            selectedInputStatus: selected?.status ?? "unknown",
            outputStatus: root.hdmi.output.status,
            contentSpecs: root.hdmi.contentSpecs,
            otherInputs: ports.compactMapValues { $0?.status }.filter { $0.key != root.execution.hdmiSource }
        )
    }

    private struct Root: Decodable {
        let execution: Execution
        let hdmi: HDMI
    }

    private struct Execution: Decodable {
        let mode: String
        let hdmiSource: String
    }

    private struct HDMI: Decodable {
        let input1: Port?
        let input2: Port?
        let input3: Port?
        let input4: Port?
        let output: Port
        let contentSpecs: String?
    }

    private struct Port: Decodable {
        let name: String?
        let status: String
    }
}
