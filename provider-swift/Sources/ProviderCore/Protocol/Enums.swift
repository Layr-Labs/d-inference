import Foundation

public enum ProviderStatus: String, Codable, Sendable {
    case idle
    case serving
}

public enum ChipFamily: String, Codable, Sendable {
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
    case m4 = "M4"
    case m5 = "M5"
    case unknown = "Unknown"
}

public enum ChipTier: String, Codable, Sendable {
    case base = "Base"
    case pro = "Pro"
    case max = "Max"
    case ultra = "Ultra"
    case unknown = "Unknown"
}

public enum ThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}
