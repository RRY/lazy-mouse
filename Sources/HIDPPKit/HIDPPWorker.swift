import Foundation

/// Runs every HID++ access on a dedicated thread with its own run loop.
///
/// Necessary because `HIDPPTransport` ties the device to the run loop of the calling thread
/// and pumps it while waiting for answers. In a GUI that would freeze the interface, and all
/// accesses have to happen on the same thread as the run loop registration.
public final class HIDPPWorker {

    public enum State {
        case idle
        case connected(productName: String)
        /// Carries the error itself, so callers can tell a missing permission from a device
        /// that was not found without comparing message texts.
        case failed(Error)
    }

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var device: HIDPPDevice?
    private var transport: HIDPPTransport?
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var _state: State = .idle

    /// Pending jobs. Deliberately an own queue rather than `CFRunLoopPerformBlock`: a job
    /// pumps the run loop again while waiting for the device's answer, and that pump would
    /// execute the next queued block *inside* the running one. The inner call clears the
    /// transport's receive buffer, so the outer call's answer is lost — depending on the
    /// nesting either as a wrong result or as a hang. Jobs are taken from this queue only at
    /// the top level of the thread loop, so calls can never overlap.
    private let jobLock = NSLock()
    private var pendingJobs: [() -> Void] = []

    /// Called on presses of diverted buttons — already delivered on the main queue so callers
    /// can update the interface directly.
    public var onNotification: (([UInt8]) -> Void)?

    /// Reports loss and return of the device, likewise on the main queue. After sleep macOS
    /// creates a new device; anything held in the device — diverted buttons, for instance —
    /// has to be set again afterwards.
    public var onConnectionChange: ((Bool) -> Void)?

    /// Product name of the most recently adopted device.
    public var productName: String {
        if case .connected(let name) = state { return name }
        return "—"
    }

    public private(set) var state: State {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _state }
        set { stateLock.lock(); _state = newValue; stateLock.unlock() }
    }

    public init() {}

    /// Starts the worker and waits until the connection is up or has failed.
    @discardableResult
    public func start(preferredProductID: Int? = HIDPPTransport.productIDMXMaster3S) -> State {
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            self.runLoop = CFRunLoopGetCurrent()

            let transport = HIDPPTransport()
            transport.onNotification = { [weak self] body in
                guard let handler = self?.onNotification else { return }
                DispatchQueue.main.async { handler(body) }
            }
            transport.onConnectionChange = { [weak self] connected in
                guard let self = self else { return }
                self.state = connected
                    ? .connected(productName: transport.productName)
                    : .failed(HIDPPError.deviceNotFound)
                guard let handler = self.onConnectionChange else { return }
                DispatchQueue.main.async { handler(connected) }
            }
            // Transport und Gerät unabhängig vom Ausgang festhalten. Zuvor geschah das nur
            // im Erfolgsfall, und ein fehlgeschlagener Erstversuch — beim Systemstart die
            // Regel, weil die App vor der Bluetooth-Verbindung läuft — ließ `device` für
            // immer nil. Der Transport meldete die auftauchende Maus dann zwar, aber jeder
            // Zugriff scheiterte an notConnected, auch der Wiederholungsversuch: die App
            // erholte sich erst durch einen Neustart.
            self.transport = transport
            self.device = HIDPPDevice(transport: transport)
            do {
                let name = try transport.connect(preferredProductID: preferredProductID)
                self.state = .connected(productName: name)
            } catch {
                self.state = .failed(error)
            }
            self.startupSemaphore.signal()

            // Keep alive so the run loop delivers input reports. Jobs are processed only
            // after returning from the run loop, that is outside any run loop call — only
            // then are they guaranteed not to nest.
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.1, false)
                self.drainJobs()
            }
        }
        thread.name = "com.lazysoftware.lazymouse.hid"
        thread.start()
        self.thread = thread
        startupSemaphore.wait()
        return state
    }

    public func stop() {
        thread?.cancel()
        thread = nil
    }

    private func enqueue(_ job: @escaping () -> Void) {
        jobLock.lock()
        pendingJobs.append(job)
        jobLock.unlock()
        // Wakes the run loop so the job does not wait for the interval to expire.
        if let runLoop = runLoop { CFRunLoopWakeUp(runLoop) }
    }

    private func drainJobs() {
        while true {
            jobLock.lock()
            let job = pendingJobs.isEmpty ? nil : pendingJobs.removeFirst()
            jobLock.unlock()
            guard let job = job else { return }
            job()
        }
    }

    /// Runs `work` on the HID thread and delivers the result on the main queue.
    public func perform<T>(_ work: @escaping (HIDPPDevice) throws -> T,
                           completion: @escaping (Result<T, Error>) -> Void) {
        enqueue { [weak self] in
            guard let device = self?.device else {
                DispatchQueue.main.async { completion(.failure(HIDPPError.notConnected)) }
                return
            }
            let result = Result { try work(device) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Runs `work` on the HID thread and waits for the result.
    ///
    /// Unlike `perform`, the reply does not go through the main queue. That is essential for
    /// calls from the quit path: there the caller blocks the main thread, so a completion
    /// delivered to it would never arrive.
    @discardableResult
    public func performSync<T>(timeout: TimeInterval = 2.0,
                               _ work: @escaping (HIDPPDevice) throws -> T) -> Result<T, Error> {
        guard runLoop != nil else { return .failure(HIDPPError.notConnected) }
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(HIDPPError.notConnected)
        enqueue { [weak self] in
            if let device = self?.device {
                result = Result { try work(device) }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return result
    }
}
