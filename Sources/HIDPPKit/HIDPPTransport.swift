import Foundation
import IOKit
import IOKit.hid

/// Low-level transport für HID++ 2.0 über IOKit.
///
/// Wichtig für Bluetooth LE auf macOS (empirisch an einer MX Master 3S ermittelt):
///
/// * Die HID++ Vendor-Collection erscheint NICHT als eigenes IOHIDDevice, sondern als
///   zusätzliches Usage-Pair auf demselben Gerät wie die Standard-Maus-Collection
///   (bei der MX Master 3S: Usage Page 0xFF43). Ein Matching-Dictionary, das auf die
///   Usage Page filtert, findet das Gerät deshalb nicht — es muss über die Vendor-ID
///   gematcht und die Collection danach über die Elemente gefunden werden.
///
/// * Es existiert nur Report-ID 0x11 (Long, 19 Byte Body), kein klassisches 0x10 (Short).
///
/// * `IOHIDDeviceSetReport` liefert zwar kIOReturnSuccess, sendet aber faktisch nichts.
///   Gesendet wird ausschließlich über `IOHIDDeviceSetValue` auf dem 19-Byte-Output-
///   Array-Element der Vendor-Collection.
///
/// * Empfangen läuft über `IOHIDDeviceRegisterInputReportCallback`. Der Callback liefert
///   den Report inklusive führender Report-ID, der HID++-Body beginnt also bei Index 1.
///   Das Input-*Element* taugt nicht als Quelle: es cacht nur den zuletzt empfangenen
///   Report, und viele SET-Aufrufe lösen unmittelbar nach der Antwort eine Notification
///   aus, die den Cache innerhalb weniger Millisekunden überschreibt — die Antwort ginge
///   dabei verloren.
///
/// Da das Matching die Vendor-ID ohne Usage-Page-Einschränkung verwendet, verlangt macOS
/// die Berechtigung "Eingabeüberwachung" (Input Monitoring) für die aufrufende Anwendung.
public final class HIDPPTransport {

    public static let vendorIDLogitech = 0x046D
    /// Report-ID aller HID++-Nachrichten auf diesem Transportweg.
    static let reportID: UInt8 = 0x11
    /// Body-Länge eines HID++ Long-Reports ohne Report-ID.
    static let reportBodyLength = 19

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var outputElement: IOHIDElement?

    private let inputBufferSize = 64
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    /// Seit dem letzten Request empfangene HID++-Bodies (ohne Report-ID).
    private var receivedBodies: [[UInt8]] = []

    public private(set) var productName: String = "unbekannt"
    /// Usage Page der gefundenen HID++ Vendor-Collection (z. B. 0xFF43 bei BLE).
    public private(set) var vendorUsagePage: UInt32 = 0

    /// Wird für jede Notification des Geräts (Software-ID 0) aufgerufen, sobald sie
    /// eintrifft — im Gegensatz zu `listen(...)` ohne zu blockieren. Läuft auf dem Thread,
    /// dessen RunLoop das Gerät bedient.
    public var onNotification: (([UInt8]) -> Void)?

    public init() {
        inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
    }

    deinit {
        if let device = device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        inputBuffer.deallocate()
    }

    /// Produkt-ID der MX Master 3S. Wird bevorzugt gewählt, wenn mehrere Logitech-Geräte
    /// angeschlossen sind; ist sie nicht dabei, kommt jedes Gerät mit HID++-Collection in
    /// Frage. Bewusst die Produkt-ID statt des Produktnamens: der Name ist über
    /// `FriendlyNameFeature` änderbar, und nach einer Umbenennung griffe ein Namensfilter
    /// nicht mehr — die Produkt-ID bleibt.
    public static let productIDMXMaster3S = 0xB034

    /// Meldet, wenn das Gerät verschwindet oder wieder auftaucht — etwa beim Ruhezustand
    /// des Rechners. Läuft auf dem Thread, dessen RunLoop den Manager bedient.
    public var onConnectionChange: ((Bool) -> Void)?

    private var preferredProductID: Int?

    /// Meldet den Manager für Zu- und Abgänge an. Ohne das behielte der Transport nach einem
    /// Ruhezustand die Referenz auf das alte, längst entfernte Gerät: macOS legt beim
    /// Wiederverbinden ein neues `IOHIDDevice` an, und sämtliche Zugriffe liefen still ins
    /// Leere, bis die Anwendung neu startet.
    private func registerDeviceCallbacks(_ mgr: IOHIDManager) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
            // Nur einspringen, wenn gerade kein Gerät bedient wird.
            guard transport.device == nil else { return }
            // Nach einem Wiederverbinden dasselbe Modell greifen wie zuvor, sonst könnte
            // bei mehreren Logitech-Geräten das falsche übernommen werden.
            if let wanted = transport.preferredProductID,
               (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) != wanted {
                return
            }
            if transport.adopt(device) {
                transport.onConnectionChange?(true)
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
            guard transport.device == device else { return }
            transport.device = nil
            transport.outputElement = nil
            transport.receivedBodies.removeAll()
            transport.onConnectionChange?(false)
        }, context)
    }

    /// Übernimmt ein Gerät, sofern es die HID++-Collection mitbringt.
    @discardableResult
    private func adopt(_ candidate: IOHIDDevice) -> Bool {
        guard let elements = IOHIDDeviceCopyMatchingElements(candidate, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return false
        }
        // Das HID++ Output-Array-Element: Vendor-Usage-Page, 19 Bytes à 8 Bit.
        let out = elements.first { el in
            IOHIDElementGetUsagePage(el) >= 0xFF00
                && IOHIDElementGetType(el) == kIOHIDElementTypeOutput
                && IOHIDElementGetReportCount(el) == UInt32(HIDPPTransport.reportBodyLength)
                && IOHIDElementGetReportSize(el) == 8
        }
        guard let outputElement = out else { return false }

        IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return false
        }

        IOHIDDeviceRegisterInputReportCallback(
            candidate,
            inputBuffer,
            inputBufferSize,
            { context, _, _, _, reportID, report, reportLength in
                guard let context = context, UInt8(truncatingIfNeeded: reportID) == HIDPPTransport.reportID else { return }
                let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
                // Der Callback liefert die Report-ID als erstes Byte mit.
                let raw = Array(UnsafeBufferPointer(start: report, count: reportLength))
                guard raw.count > 1 else { return }
                let body = Array(raw.dropFirst())
                transport.receivedBodies.append(body)
                if body.count >= 3, (body[2] & 0x0F) == 0 {
                    transport.onNotification?(body)
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        device = candidate
        // Die tatsächlich übernommene Produkt-ID wird zur Vorgabe für spätere Zugänge —
        // auch dann, wenn beim ersten Verbinden auf ein anderes Modell ausgewichen wurde.
        preferredProductID = IOHIDDeviceGetProperty(candidate, kIOHIDProductIDKey as CFString) as? Int
        self.outputElement = outputElement
        productName = (IOHIDDeviceGetProperty(candidate, kIOHIDProductKey as CFString) as? String) ?? "Logitech device"
        vendorUsagePage = IOHIDElementGetUsagePage(outputElement)
        return true
    }

    @discardableResult
    public func connect(preferredProductID: Int? = HIDPPTransport.productIDMXMaster3S) throws -> String {
        self.preferredProductID = preferredProductID
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey as String: HIDPPTransport.vendorIDLogitech] as CFDictionary)

        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw HIDPPError.managerOpenFailed(openResult)
        }
        self.manager = mgr
        registerDeviceCallbacks(mgr)
        // Der Manager muss auf der RunLoop liegen, sonst kämen die Zu-/Abgangsmeldungen nie an.
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
            throw HIDPPError.deviceNotFound
        }

        let candidates: [IOHIDDevice]
        if let preferred = preferredProductID {
            let matching = deviceSet.filter {
                (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int) == preferred
            }
            candidates = matching.isEmpty ? Array(deviceSet) : Array(matching)
        } else {
            candidates = Array(deviceSet)
        }

        for candidate in candidates where adopt(candidate) {
            return productName
        }

        throw HIDPPError.deviceNotFound
    }

    /// Ob gerade ein Gerät bedient wird.
    public var isConnected: Bool { device != nil }

    /// Prüft, ob ein empfangener Body die Antwort auf einen Request mit dieser Software-ID ist.
    ///
    /// Bei Fehlerantworten (`body[1] == 0xFF`) steht das Funktions-/SwID-Byte an Position 3
    /// statt 2, weil sich die ursprüngliche Feature-Adresse dazwischenschiebt.
    private static func matches(body: [UInt8], swID: UInt8) -> Bool {
        guard body.count >= 4 else { return false }
        let funcSw = body[1] == 0xFF ? body[3] : body[2]
        return (funcSw & 0x0F) == swID
    }

    /// Sendet einen HID++ Request und wartet auf die zugehörige Antwort.
    ///
    /// Notifications des Geräts (Software-ID 0) werden dabei übergangen; sie treffen bei
    /// SET-Aufrufen regelmäßig kurz nach der eigentlichen Antwort ein.
    public func request(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        swID: UInt8,
        params: [UInt8] = [],
        timeout: TimeInterval = 2.0
    ) throws -> HIDPPResponse {
        guard let device = device, let outputElement = outputElement else {
            throw HIDPPError.notConnected
        }

        let effectiveSwID = (swID & 0x0F) == 0 ? 1 : (swID & 0x0F)
        receivedBodies.removeAll()

        var body = [UInt8](repeating: 0, count: HIDPPTransport.reportBodyLength)
        body[0] = deviceIndex
        body[1] = featureIndex
        body[2] = (function << 4) | effectiveSwID
        for (i, p) in params.prefix(HIDPPTransport.reportBodyLength - 3).enumerated() {
            body[3 + i] = p
        }

        let sendResult = body.withUnsafeMutableBufferPointer { buf -> IOReturn in
            guard let value = IOHIDValueCreateWithBytes(kCFAllocatorDefault, outputElement, 0, buf.baseAddress!, buf.count) else {
                return kIOReturnError
            }
            return IOHIDDeviceSetValue(device, outputElement, value)
        }
        guard sendResult == kIOReturnSuccess else {
            throw HIDPPError.sendFailed(sendResult)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
            if let match = receivedBodies.first(where: { HIDPPTransport.matches(body: $0, swID: effectiveSwID) }) {
                return try HIDPPResponse(body: match)
            }
        }
        throw HIDPPError.timeout
    }

    /// Lauscht auf Notifications des Geräts (Software-ID 0) — etwa Tastendrücke einer
    /// per `divert` umgeleiteten Taste. Blockiert bis `duration` abgelaufen ist oder
    /// `shouldStop` true liefert.
    public func listen(duration: TimeInterval, shouldStop: () -> Bool = { false }, onNotification: ([UInt8]) -> Void) {
        receivedBodies.removeAll()
        var delivered = 0
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline, !shouldStop() {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            while delivered < receivedBodies.count {
                let body = receivedBodies[delivered]
                delivered += 1
                if body.count >= 3, (body[2] & 0x0F) == 0 {
                    onNotification(body)
                }
            }
        }
    }
}

/// Geparste Antwort auf einen HID++-Request.
public struct HIDPPResponse {
    public let featureIndex: UInt8
    public let function: UInt8
    public let params: [UInt8]

    /// HID++ 2.0 Fehlerantwort: [deviceIndex, 0xFF, originalFeatureIndex, originalFuncSw, errorCode, ...]
    init(body: [UInt8]) throws {
        guard body.count >= 3 else { throw HIDPPError.malformedResponse }
        if body[1] == 0xFF {
            guard body.count >= 5 else { throw HIDPPError.malformedResponse }
            throw HIDPPError.protocolError(featureIndex: body[2], function: body[3] >> 4, errorCode: body[4])
        }
        self.featureIndex = body[1]
        self.function = body[2] >> 4
        self.params = Array(body[3...])
    }
}
