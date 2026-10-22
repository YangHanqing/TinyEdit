import Foundation

/// One per file-backed buffer. Callbacks run on the presenter queue; the owner hops to the main actor.
final class ExternalFileMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    var onChange: (@Sendable () -> Void)?
    var onMove: (@Sendable (URL) -> Void)?
    var onDelete: (@Sendable () -> Void)?

    var presentedItemURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _url
    }

    init(url: URL) {
        _url = url
        super.init()
    }

    func register() { NSFileCoordinator.addFilePresenter(self) }
    func unregister() { NSFileCoordinator.removeFilePresenter(self) }

    func update(url: URL) {
        lock.lock(); _url = url; lock.unlock()
    }

    func presentedItemDidChange() { onChange?() }

    func presentedItemDidMove(to newURL: URL) {
        update(url: newURL)
        onMove?(newURL)
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        onDelete?()
        completionHandler(nil)
    }
}
