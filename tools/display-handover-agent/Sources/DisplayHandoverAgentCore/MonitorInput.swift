public enum MonitorInput: Equatable, Sendable, CustomStringConvertible {
    case thunderbolt
    case displayPort
    case hdmi
    case other(UInt8)

    /// VCP 0x60 is a non-continuous value, so MCCS puts the input code in the low byte. The U2725QE
    /// reports `0x1919` on Thunderbolt and `0x1911` on HDMI.
    public init?(vcp60 raw: Int) {
        guard (0...0xFFFF).contains(raw) else { return nil }
        let low = UInt8(raw & 0xFF)
        switch low {
        case 0x19: self = .thunderbolt  // Dell code for the USB-C/Thunderbolt upstream input
        case 0x0F: self = .displayPort
        case 0x11: self = .hdmi
        default: self = .other(low)
        }
    }

    public var description: String {
        switch self {
        case .thunderbolt: "Thunderbolt"
        case .displayPort: "DisplayPort"
        case .hdmi: "HDMI"
        case .other(let code): "input 0x" + String(code, radix: 16, uppercase: true)
        }
    }
}
