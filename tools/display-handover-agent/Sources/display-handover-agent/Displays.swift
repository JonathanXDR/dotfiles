import ColorSync
import CoreGraphics

/// A display that BetterDisplay disconnected is missing from the online list
struct DisplaySnapshot {
    struct Entry {
        var id: CGDirectDisplayID
        var isPrimary: Bool
        var isBuiltin: Bool
        var isMain: Bool
        var isAsleep: Bool
    }

    var entries: [Entry]

    var primary: Entry? { entries.first { $0.isPrimary } }
    var primaryOnline: Bool { primary != nil }
    var primaryIsMain: Bool { primary?.isMain ?? false }
    var others: [Entry] { entries.filter { !$0.isPrimary } }
    /// Another online display is awake, so disconnecting the primary leaves a screen with the desktop
    var otherDisplayOnline: Bool { others.contains { !$0.isAsleep } }
    var othersAsleep: Bool { !others.isEmpty && others.allSatisfy(\.isAsleep) }

    var summary: String {
        entries.map { entry in
            let name = entry.isPrimary ? "primary" : entry.isBuiltin ? "built-in" : "display \(entry.id)"
            return name + (entry.isMain ? " (main)" : "") + (entry.isAsleep ? " (asleep)" : "")
        }.joined(separator: ", ")
    }

    static func current(primaryUUID: String) -> DisplaySnapshot {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return DisplaySnapshot(entries: []) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return DisplaySnapshot(entries: []) }
        return DisplaySnapshot(entries: ids.prefix(Int(count)).map { id in
            Entry(
                id: id,
                isPrimary: uuid(of: id)?.caseInsensitiveCompare(primaryUUID) == .orderedSame,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0,
                isAsleep: CGDisplayIsAsleep(id) != 0
            )
        })
    }

    private static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
