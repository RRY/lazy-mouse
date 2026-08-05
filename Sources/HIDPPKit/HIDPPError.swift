import Foundation
import IOKit

public enum HIDPPError: Error, CustomStringConvertible {
    case managerOpenFailed(IOReturn)
    case deviceNotFound
    case deviceOpenFailed(IOReturn)
    case notConnected
    case sendFailed(IOReturn)
    case timeout
    case protocolError(featureIndex: UInt8, function: UInt8, errorCode: UInt8)
    case malformedResponse

    /// Fehlende Berechtigung "Eingabeüberwachung". Sie lässt sich nur vom Nutzer in den
    /// Systemeinstellungen erteilen — ein erneuter Verbindungsversuch bringt vorher nichts.
    public var isPermissionDenied: Bool {
        switch self {
        case .managerOpenFailed(let code), .deviceOpenFailed(let code):
            return code == kIOReturnNotPermitted
        default:
            return false
        }
    }

    public var description: String {
        switch self {
        case .managerOpenFailed(let code):
            return "IOHIDManager konnte nicht geöffnet werden (IOReturn \(code))"
        case .deviceNotFound:
            return "Keine passende Logitech-Maus gefunden. Ist sie per Bluetooth gekoppelt und eingeschaltet?"
        case .deviceOpenFailed(let code):
            return "HID-Gerät konnte nicht geöffnet werden (IOReturn \(code))"
        case .notConnected:
            return "Kein Gerät verbunden. Zuerst connect() aufrufen."
        case .sendFailed(let code):
            return "Senden des HID++ Reports fehlgeschlagen (IOReturn \(code))"
        case .timeout:
            return "Zeitüberschreitung beim Warten auf Antwort der Maus"
        case .protocolError(let featureIndex, let function, let errorCode):
            return "HID++ Fehler: feature=\(featureIndex) function=\(function) code=0x\(String(errorCode, radix: 16))"
        case .malformedResponse:
            return "Unerwartetes/zu kurzes HID++ Antwortformat"
        }
    }
}
