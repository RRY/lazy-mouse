import Foundation
import CoreGraphics
import ApplicationServices

/// Reshapes the scroll events of detented mouse wheels.
///
/// Measured with an MX Master 3S in ratchet mode: macOS turns a slowly turned detent into
/// 0.1 lines — a single point — while two detents that happen to follow within 120 ms already
/// move six or seven. Slow scrolling therefore crawls and feels uneven. On top of that the
/// wheel occasionally reports one detent against the direction of travel: when it stops
/// between two detents, the magnetic ratchet pulls it back. macOS accelerates that stray step
/// like any other, so the window visibly jumps back.
///
/// The filter therefore
/// - drops a single detent against the current direction that arrives within `bounceWindow`
///   of the previous one. A bounce is always one detent; a second one in the new direction,
///   or a fast reversal carrying several lines, counts as real and passes,
/// - gives every detent at least one line and lets the distance grow steadily with speed.
///   Everything above that one line — macOS' own acceleration included — is scaled by
///   `strength`. A swipe across the wheel is a burst of detents less than 50 ms apart, where
///   macOS' value is far larger than any curve of our own; leaving that part to macOS made
///   the setting next to imperceptible (measured: 8 swipes for a page at the low end, 6.5 at
///   the high end),
/// - optionally plays the distance out as small pixel steps at display rate instead of one
///   jump — without that, one line per detent arrives as a visible step.
///
/// Only non-continuous events are touched. Trackpads and the Magic Mouse deliver continuous
/// ones, and so do the events the filter posts itself, which keeps them from being filtered a
/// second time. Horizontal scrolling — the thumb wheel — passes unchanged. Other wheel mice
/// are affected as well: an event does not say which device it came from.
///
/// Changing events requires the Accessibility permission. Without it the tap cannot be
/// created and scrolling stays as macOS makes it.
final class ScrollFilter {

    struct Settings {
        /// 0 (gentle) to `maximumStrength` (strong). At 0 the distance is macOS' own, raised to
        /// at least one line per detent.
        var strength: Double = 3.0
        var smoothing = true
    }

    static let maximumStrength = 6.0
    /// Factor on the distance above one line at maximum strength.
    private static let maximumScale = 2.5
    /// Steepness of our own mid-range curve at maximum strength.
    private static let maximumCurve = 2.0

    /// One line in points, as macOS converts it (measured: 0.1 lines -> 1 point).
    private static let pointsPerLine = 10.0
    private static let minimumLines = 1.0
    private static let bounceWindow: TimeInterval = 0.2
    /// Share of the remaining distance played out per frame: an ease-out over about ten frames.
    private static let easing = 0.2
    private static let frameInterval: TimeInterval = 1.0 / 120

    private let settingsLock = NSLock()
    private var _settings = Settings()
    /// Read on every detent from the filter thread, written from the interface.
    var settings: Settings {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _settings }
        set { settingsLock.lock(); _settings = newValue; settingsLock.unlock() }
    }

    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog that leads to the Accessibility settings.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private(set) var isRunning = false
    private var thread: Thread?
    private var tap: CFMachPort?
    private var tapCreated = false
    private let source = CGEventSource(stateID: .hidSystemState)

    // Touched by the filter thread only.
    private var lastSign = 0
    private var lastTime: TimeInterval = -.infinity
    private var suppressed = false
    private var pending = 0.0
    private var frameTimer: Timer?

    /// Starts the filter on its own thread, so a busy interface can never hold up scrolling.
    /// Returns false when the tap could not be created — as a rule because the Accessibility
    /// permission is missing.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            self.tapCreated = self.installTap()
            ready.signal()
            guard self.tapCreated else { return }
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            self.removeTap()
        }
        thread.name = "com.lazysoftware.lazymouse.scroll"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if tapCreated {
            self.thread = thread
            isRunning = true
        }
        return tapCreated
    }

    func stop() {
        thread?.cancel()
        thread = nil
        isRunning = false
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ScrollFilter>.fromOpaque(info).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeTap() {
        frameTimer?.invalidate()
        frameTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches off a tap that answers too slowly or after certain user input.
        // Without switching it back on, the filter would end silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        guard lines != 0 else { return Unmanaged.passUnretained(event) }

        let now = ProcessInfo.processInfo.systemUptime
        let sign = lines > 0 ? 1 : -1
        let interval = now - lastTime

        if lastSign != 0, sign != lastSign, abs(lines) == 1, interval < Self.bounceWindow, !suppressed {
            suppressed = true
            return nil
        }
        // A real reversal: whatever is left of the old direction would carry on against it.
        if sign != lastSign { pending = 0 }
        suppressed = false
        lastSign = sign
        lastTime = now

        let settings = self.settings
        let strength = min(max(settings.strength / Self.maximumStrength, 0), 1)
        // 0 at 300 ms between detents or more, 1 at 50 ms or less; the power keeps the start
        // of the curve gentle. It fills the range where macOS still delivers less than a line.
        let speed = min(max((0.3 - interval) / 0.25, 0), 1)
        let own = Self.minimumLines * (1 + Self.maximumCurve * strength * pow(speed, 1.5))
        let system = abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        let base = max(own, system)
        // The first line stays as it is — slow scrolling is right at every setting.
        let distance = Self.minimumLines
            + (base - Self.minimumLines) * (1 + (Self.maximumScale - 1) * strength)
        let points = Double(sign) * distance * Self.pointsPerLine

        guard settings.smoothing else {
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: points / Self.pointsPerLine)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points.rounded()))
            return Unmanaged.passUnretained(event)
        }
        pending += points
        startFrames()
        return nil
    }

    /// The frame timer runs only while there is distance left, so an idle wheel costs nothing.
    private func startFrames() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            self?.playFrame()
        }
        RunLoop.current.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func playFrame() {
        guard abs(pending) >= 0.5 else {
            pending = 0
            frameTimer?.invalidate()
            frameTimer = nil
            return
        }
        var step = (pending * Self.easing).rounded()
        if step == 0 { step = pending > 0 ? 1 : -1 }
        pending -= step
        // Pixel events are continuous, so the tap lets them pass instead of filtering them again.
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                wheel1: Int32(step), wheel2: 0, wheel3: 0)?
            .post(tap: .cgSessionEventTap)
    }
}
