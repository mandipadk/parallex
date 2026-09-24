import CoreAudio
import Foundation

/// Quitting instances you aren't using: an instance can ask to be quit (as
/// ⌘Q does) once it hasn't been in front for a while, which frees its
/// memory. One playing sound isn't idle (music in a background Spotify
/// copy), so it's left alone.
public enum IdleQuit {
    /// The choices offered, in minutes.
    public static let choices = [15, 60, 240]

    /// The choices, plus a limit set some other way (`parallex edit`).
    public static func choices(including current: Int?) -> [Int] {
        guard let current, !choices.contains(current) else { return choices }
        return (choices + [current]).sorted()
    }

    /// "15 minutes", "1 hour", "4 hours", "90 minutes".
    public static func describe(_ minutes: Int) -> String {
        guard minutes >= 60, minutes % 60 == 0 else { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }

    /// Whether it's time: running, not in front, unused for its limit.
    public static func isDue(limitMinutes: Int?, lastInFront: Date, isFront: Bool, now: Date = Date()) -> Bool {
        guard let limitMinutes, limitMinutes > 0, !isFront else { return false }
        return now.timeIntervalSince(lastInFront) >= TimeInterval(limitMinutes * 60)
    }

    /// Whether this Mac can tell which apps are playing sound (macOS 14.4
    /// and later). Without that, music would count as unused, so the
    /// setting isn't offered and nothing is quit.
    public static var isAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Processes with sound going out right now, as Core Audio sees them
    /// (nil where it can't tell). An app holding its output open counts
    /// too (a call app), which errs on the side of leaving it be.
    public static func processesPlayingSound() -> Set<pid_t>? {
        guard #available(macOS 14.4, *) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else {
            return nil
        }
        var playing = Set<pid_t>()
        for object in objects {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else {
                continue
            }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr {
                playing.insert(pid)
            }
        }
        return playing
    }
}
