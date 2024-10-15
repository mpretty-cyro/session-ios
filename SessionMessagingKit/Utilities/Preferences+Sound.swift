// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AudioToolbox
import GRDB
import DifferenceKit
import SessionUtilitiesKit

public extension Preferences {
    enum Sound: Int, Codable, DatabaseValueConvertible, EnumIntSetting, Differentiable {
        public static var defaultiOSIncomingRingtone: Sound = .opening
        public static var defaultNotificationSound: Sound = .note
        
        // Don't store too many sounds in memory (Most users will only use 1 or 2 sounds anyway)
        private static let maxCachedSounds: Int = 4
        private static var cachedSystemSounds: Atomic<[String: (url: URL?, soundId: SystemSoundID)]> = Atomic([:])
        private static var cachedSystemSoundOrder: Atomic<[String]> = Atomic([])
        
        // Values
        
        case `default`
        
        // Notification Sounds
        case aurora = 1000
        case bamboo
        case chord
        case circles
        case complete
        case hello
        case input
        case keys
        case note
        case popcorn
        case pulse
        case synth
        case signalClassic
        
        // Ringtone Sounds
        case opening = 2000
        
        // Calls
        case callConnecting = 3000
        case callOutboundRinging
        case callBusy
        case callFailure
        
        // Other
        case messageSent = 4000
        case none
        
        public static var notificationSounds: [Sound] {
            return [
                // None and Note (default) should be first.
                .none,
                .note,
                
                .aurora,
                .bamboo,
                .chord,
                .circles,
                .complete,
                .hello,
                .input,
                .keys,
                .popcorn,
                .pulse,
                .synth
            ]
        }
        
        public var displayName: String {
            // TODO: Should we localize these sound names?
            switch self {
                case .`default`: return ""
                
                // Notification Sounds
                case .aurora: return "Aurora"
                case .bamboo: return "Bamboo"
                case .chord: return "Chord"
                case .circles: return "Circles"
                case .complete: return "Complete"
                case .hello: return "Hello"
                case .input: return "Input"
                case .keys: return "Keys"
                case .note: return "Note"
                case .popcorn: return "Popcorn"
                case .pulse: return "Pulse"
                case .synth: return "Synth"
                case .signalClassic: return "Signal Classic"
                
                // Ringtone Sounds
                case .opening: return "Opening"
                
                // Calls
                case .callConnecting: return "Call Connecting"
                case .callOutboundRinging: return "Call Outboung Ringing"
                case .callBusy: return "Call Busy"
                case .callFailure: return "Call Failure"
                
                // Other
                case .messageSent: return "Message Sent"
                case .none: return "none".localized()
            }
        }
        
        // MARK: - Functions
        
        public func filename(quiet: Bool = false) -> String? {
            switch self {
                case .`default`: return ""
                
                // Notification Sounds
                case .aurora: return (quiet ? "aurora-quiet.aifc" : "aurora.aifc")              // stringlint:disable
                case .bamboo: return (quiet ? "bamboo-quiet.aifc" : "bamboo.aifc")              // stringlint:disable
                case .chord: return (quiet ? "chord-quiet.aifc" : "chord.aifc")                 // stringlint:disable
                case .circles: return (quiet ? "circles-quiet.aifc" : "circles.aifc")           // stringlint:disable
                case .complete: return (quiet ? "complete-quiet.aifc" : "complete.aifc")        // stringlint:disable
                case .hello: return (quiet ? "hello-quiet.aifc" : "hello.aifc")                 // stringlint:disable
                case .input: return (quiet ? "input-quiet.aifc" : "input.aifc")                 // stringlint:disable
                case .keys: return (quiet ? "keys-quiet.aifc" : "keys.aifc")                    // stringlint:disable
                case .note: return (quiet ? "note-quiet.aifc" : "note.aifc")                    // stringlint:disable
                case .popcorn: return (quiet ? "popcorn-quiet.aifc" : "popcorn.aifc")           // stringlint:disable
                case .pulse: return (quiet ? "pulse-quiet.aifc" : "pulse.aifc")                 // stringlint:disable
                case .synth: return (quiet ? "synth-quiet.aifc" : "synth.aifc")                 // stringlint:disable
                case .signalClassic: return (quiet ? "classic-quiet.aifc" : "classic.aifc")     // stringlint:disable
                
                // Ringtone Sounds
                case .opening: return "Opening.m4r"                                             // stringlint:disable
                
                // Calls
                case .callConnecting: return "ringback_tone_ansi.caf"                           // stringlint:disable
                case .callOutboundRinging: return "ringback_tone_ansi.caf"                      // stringlint:disable
                case .callBusy: return "busy_tone_ansi.caf"                                     // stringlint:disable
                case .callFailure: return "end_call_tone_cept.caf"                              // stringlint:disable
                
                // Other
                case .messageSent: return "message_sent.aiff"                                   // stringlint:disable
                case .none: return "silence.aiff"                                               // stringlint:disable
            }
        }
        
        public func soundUrl(quiet: Bool = false) -> URL? {
            guard let filename: String = filename(quiet: quiet) else { return nil }
            
            let url: URL = URL(fileURLWithPath: filename)
            
            return Bundle.main.url(
                forResource: url.deletingPathExtension().path,
                withExtension: url.pathExtension
            )
        }
        
        public func notificationSound(isQuiet: Bool) -> UNNotificationSound {
            guard let filename: String = filename(quiet: isQuiet) else {
                SNLog("[Preferences.Sound] filename was unexpectedly nil")
                return UNNotificationSound.default
            }
            
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: filename))
        }
        
        public static func systemSoundId(for sound: Sound, quiet: Bool) -> SystemSoundID {
            let cacheKey: String = "\(sound.rawValue):\(quiet ? 1 : 0)"
            
            if let cachedSound: SystemSoundID = cachedSystemSounds.wrappedValue[cacheKey]?.soundId {
                return cachedSound
            }
            
            let systemSound: (url: URL?, soundId: SystemSoundID) = (
                url: sound.soundUrl(quiet: quiet),
                soundId: SystemSoundID()
            )
            
            cachedSystemSounds.mutate { cache in
                cachedSystemSoundOrder.mutate { order in
                    if order.count > Sound.maxCachedSounds {
                        cache.removeValue(forKey: order[0])
                        order.remove(at: 0)
                    }
                    
                    order.append(cacheKey)
                }
                
                cache[cacheKey] = systemSound
            }
            
            return systemSound.soundId
        }
        
        // MARK: - AudioPlayer
        
        public static func audioPlayer(for sound: Sound, behavior: OWSAudioBehavior) -> OWSAudioPlayer? {
            guard let soundUrl: URL = sound.soundUrl(quiet: false) else { return nil }
            
            let player = OWSAudioPlayer(mediaUrl: soundUrl, audioBehavior: behavior)
            
            // These two cases should loop
            if sound == .callConnecting || sound == .callOutboundRinging {
                player.isLooping = true
            }
            
            return player
        }
    }
}
