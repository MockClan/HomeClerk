import Foundation
import os

/// Watches the inbox for PDFs. Each new one is reported right away, given a few seconds in case
/// more files are arriving, then — once the scanner has finished writing it — handed to
/// `enqueue`. A file stays tracked until `finished` is called, so it's handed over only once.
public actor InboxWatcher {
    let inbox: URL
    let debounce: Duration
    let maxWriteWait: Duration
    let events: PipelineEventHandler
    let enqueue: @Sendable (URL) -> Void

    private var tracked: Set<String> = []
    /// Processed but still in the inbox (it couldn't be moved): not handed over again until the next
    /// launch, so a stuck file can't be analyzed — and billed — over and over
    private var stuck: Set<String> = []
    private var source: (any DispatchSourceFileSystemObject)?
    private var rescanTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.mockclan.homeclerk", category: "inbox")

    public init(inbox: URL, debounceSeconds: Int, maxWriteWait: Duration = .seconds(300),
                events: @escaping PipelineEventHandler, enqueue: @escaping @Sendable (URL) -> Void) {
        self.inbox = inbox
        debounce = .seconds(debounceSeconds)
        self.maxWriteWait = maxWriteWait
        self.events = events
        self.enqueue = enqueue
    }

    public func start() throws {
        try FileOrganizer.requireInside(inbox, inbox)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let descriptor = open(inbox.path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: inbox.path]) }

        // Any change to the folder's entries — a file added, renamed, or removed — triggers a scan
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .link],
                                                               queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.scan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source

        // A safety net: rescan now and then in case a change notification was missed
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.scan()
            }
        }
        scan()   // PDFs already waiting in the inbox
    }

    public func stop() {
        source?.cancel()
        source = nil
        rescanTask?.cancel()
        rescanTask = nil
    }

    /// Called once a handed-over file has been dealt with.
    public func finished(_ file: URL) {
        let key = file.standardizedFileURL.path
        if FileManager.default.fileExists(atPath: file.path) {
            log.warning("A scan is still in the inbox after processing; it will be retried next launch")
            stuck.insert(key)
        } else {
            tracked.remove(key)
        }
    }

    func scan() {
        // A stuck file that's been moved or deleted frees its name for a new scan
        for key in stuck where !FileManager.default.fileExists(atPath: key) {
            stuck.remove(key)
            tracked.remove(key)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension.lowercased() == "pdf" && FileOrganizer.isInside(file, inbox) {
            let key = file.standardizedFileURL.path
            guard !tracked.contains(key) else { continue }
            tracked.insert(key)
            events(.detected(source: file))
            Task { await self.settle(file) }
        }
    }

    private func settle(_ file: URL) async {
        try? await Task.sleep(for: debounce)
        guard FileManager.default.fileExists(atPath: file.path) else {
            events(.skipped(source: file))
            finished(file)
            return
        }
        if !PDFTools.endsWithEOFMarker(file) { events(.stage(source: file, stage: .waiting, engine: nil)) }
        if !(await PDFTools.waitUntilComplete(file, maxWait: maxWriteWait)) {
            guard FileManager.default.fileExists(atPath: file.path) else {
                events(.skipped(source: file))
                finished(file)
                return
            }
            log.warning("A scan still looks incomplete after waiting — processing it anyway")
        }
        guard FileOrganizer.isInside(file, inbox) else {
            events(.problem("Skipped a scan containing a symbolic link"))
            finished(file)
            return
        }
        enqueue(file)
    }
}
