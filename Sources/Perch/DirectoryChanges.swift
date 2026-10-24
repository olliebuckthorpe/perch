import Foundation
import CoreServices

/// Recursive filesystem notifications, delivered on the main queue. No directory polling
/// while files are unchanged. File-events mode also handles atomic replacements and new days.
final class DirectoryChanges {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void

    init(changed: @escaping () -> Void) { self.changed = changed }

    @discardableResult
    func start(paths: [String]) -> Bool {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryChanges>.fromOpaque(info).takeUnretainedValue().changed()
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35,
        FSEventStreamCreateFlags(flags)) else { return false }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); return false }
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
