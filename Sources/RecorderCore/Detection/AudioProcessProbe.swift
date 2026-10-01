import Foundation
import CoreAudio

/// Un processus connu de Core Audio, et s'il capte une entrée (micro) en ce moment.
public struct AudioProcessUsage: Equatable, Sendable {
    public let bundleID: String
    public let isRunningInput: Bool

    public init(bundleID: String, isRunningInput: Bool) {
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
    }
}

/// Lit, via Core Audio, quels processus utilisent le micro. Aucune permission
/// requise (contrairement aux titres de fenêtres, qui exigent l'enregistrement
/// d'écran). API disponible à partir de macOS 14.
enum AudioProcessProbe {
    /// `nil` si Core Audio n'a pas répondu : état inconnu, pas « aucun appel ».
    @available(macOS 14.0, *)
    static func snapshot() -> [AudioProcessUsage]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }

        return ids.compactMap { id in
            guard let bundleID = bundleID(of: id) else { return nil }
            return AudioProcessUsage(bundleID: bundleID, isRunningInput: isRunningInput(id))
        }
    }

    @available(macOS 14.0, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let bundleID = value?.takeRetainedValue() as String?, !bundleID.isEmpty
        else { return nil }
        return bundleID
    }

    @available(macOS 14.0, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }
}
