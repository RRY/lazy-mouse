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
            return "Could not open IOHIDManager (IOReturn \(code))"
        case .deviceNotFound:
            return "No matching Logitech mouse found. Is it paired over Bluetooth and switched on?"
        case .deviceOpenFailed(let code):
            return "Could not open HID device (IOReturn \(code))"
        case .notConnected:
            return "No device connected. Call connect() first."
        case .sendFailed(let code):
            return "Sending the HID++ report failed (IOReturn \(code))"
        case .timeout:
            return "Timed out waiting for the mouse to answer"
        case .protocolError(let featureIndex, let function, let errorCode):
            return "HID++ error: feature=\(featureIndex) function=\(function) code=0x\(String(errorCode, radix: 16))"
        case .malformedResponse:
            return "Unexpected or too short HID++ response"
        }
    }
}
