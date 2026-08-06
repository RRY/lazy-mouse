import Foundation

/// Führt alle HID++-Zugriffe auf einem eigenen Thread mit eigener RunLoop aus.
///
/// Nötig, weil `HIDPPTransport` das Gerät an die RunLoop des aufrufenden Threads bindet und
/// beim Warten auf Antworten blockierend pumpt. In einer GUI würde das die Oberfläche
/// einfrieren; außerdem müssen alle Zugriffe auf demselben Thread laufen wie die
/// RunLoop-Registrierung.
public final class HIDPPWorker {

    public enum State {
        case idle
        case connected(productName: String)
        /// Trägt den Fehler selbst, damit Aufrufer etwa eine fehlende Berechtigung von
        /// einem nicht gefundenen Gerät unterscheiden können, ohne Texte zu vergleichen.
        case failed(Error)
    }

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var device: HIDPPDevice?
    private var transport: HIDPPTransport?
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var _state: State = .idle

    /// Wartende Aufträge. Bewusst eine eigene Warteschlange statt `CFRunLoopPerformBlock`:
    /// Ein Auftrag pumpt beim Warten auf die Geräteantwort die RunLoop erneut, und die
    /// führte dabei den nächsten eingereihten Block *innerhalb* des laufenden aus. Der
    /// innere Aufruf leert den Empfangspuffer des Transports, wodurch die Antwort des
    /// äußeren verloren geht — je nach Verschachtelung mit falschem Ergebnis oder Hänger.
    /// Aus dieser Warteschlange werden Aufträge nur auf oberster Ebene der Thread-Schleife
    /// entnommen, sodass sich Aufrufe nie überlappen können.
    private let jobLock = NSLock()
    private var pendingJobs: [() -> Void] = []

    /// Wird bei Tastendrücken umgeleiteter Tasten aufgerufen — bereits auf die Hauptqueue
    /// zugestellt, damit Aufrufer direkt die Oberfläche aktualisieren können.
    public var onNotification: (([UInt8]) -> Void)?

    public private(set) var state: State {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _state }
        set { stateLock.lock(); _state = newValue; stateLock.unlock() }
    }

    public init() {}

    /// Startet den Worker und wartet, bis die Verbindung steht oder fehlgeschlagen ist.
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
            do {
                let name = try transport.connect(preferredProductID: preferredProductID)
                self.transport = transport
                self.device = HIDPPDevice(transport: transport)
                self.state = .connected(productName: name)
            } catch {
                self.state = .failed(error)
            }
            self.startupSemaphore.signal()

            // Am Leben halten, damit die RunLoop Input-Reports zustellt. Aufträge werden
            // erst nach der Rückkehr aus der RunLoop abgearbeitet, also außerhalb jedes
            // RunLoop-Aufrufs — nur so bleiben sie garantiert unverschachtelt.
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.1, false)
                self.drainJobs()
            }
        }
        thread.name = "de.ryback.lazymouse.hid"
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
        // Weckt die RunLoop, damit der Auftrag nicht bis zum Ablauf des Intervalls wartet.
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

    /// Führt `work` auf dem HID-Thread aus und liefert das Ergebnis auf der Hauptqueue.
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

    /// Führt `work` auf dem HID-Thread aus und wartet auf das Ergebnis.
    ///
    /// Anders als `perform` läuft die Rückmeldung nicht über die Hauptqueue. Das ist
    /// entscheidend für Aufrufe aus dem Beenden-Pfad: dort blockiert der Aufrufer den
    /// Main-Thread, sodass eine dorthin zugestellte Completion nie ankäme.
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
