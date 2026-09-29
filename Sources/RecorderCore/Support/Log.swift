import Foundation
import os

public enum Log {
    public static let recorder     = Logger(subsystem: "com.yvanbetremieux.onyx", category: "recorder")
    public static let pipeline     = Logger(subsystem: "com.yvanbetremieux.onyx", category: "pipeline")
    public static let storage      = Logger(subsystem: "com.yvanbetremieux.onyx", category: "storage")
    public static let transcription = Logger(subsystem: "com.yvanbetremieux.onyx", category: "transcription")
    public static let diarization  = Logger(subsystem: "com.yvanbetremieux.onyx", category: "diarization")
    public static let ui           = Logger(subsystem: "com.yvanbetremieux.onyx", category: "ui")
}
