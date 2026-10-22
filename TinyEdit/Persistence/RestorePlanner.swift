import Foundation

struct RestoreEntry: Sendable {
    var id: UUID
    /// nil means "adopt as Recovered N" (orphan snapshot, or metadata with unknown values).
    var metadata: BufferMetadata?
    var text: String
}

struct RestorePlan: Sendable {
    var entries: [RestoreEntry] = []
    var selectedID: UUID?
    var closedTabs: [ClosedTabRecord] = []
    var tombstones: [UUID] = []
    /// Tombstoned snapshots whose session write already completed; safe to delete after the gate opens.
    var tombstonedFilesToDelete: [UUID] = []
    var quarantinedManifest = false
}

/// Pure launch-restore decisions. Never writes `session.json` and never deletes a snapshot.
enum RestorePlanner {
    static func plan(sessions: SessionStore, recovery: RecoveryStore) -> RestorePlan {
        var plan = RestorePlan()
        var manifest: SessionFile?
        switch sessions.load() {
        case .noSession: break
        case .unreadable:
            if (try? sessions.quarantineCorruptManifest()) != nil { plan.quarantinedManifest = true }
            Log.session.error("manifest quarantined; adopting snapshots")
        case .loaded(let f): manifest = f
        }

        var handled = Set<UUID>()
        let tombstones = Set(manifest?.tombstones ?? [])
        if let manifest {
            plan.closedTabs = manifest.closedTabs
            plan.tombstones = manifest.tombstones
            let byID = Dictionary(manifest.buffers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in manifest.tabOrder {
                guard let meta = byID[id] else { continue }
                handled.insert(id)
                let name = SessionStore.validateRecoveryFileName(meta.recoveryFile) ? meta.recoveryFile : "\(id.uuidString).snapshot"
                guard let text = try? recovery.readSnapshot(recoveryFile: name) else {
                    Log.session.error("snapshot missing or unreadable for a buffer; skipped")
                    continue
                }
                // Unknown metadata values: keep the text, adopt as Recovered.
                plan.entries.append(RestoreEntry(id: id, metadata: meta.makeBuffer() == nil ? nil : meta, text: text))
            }
            plan.selectedID = manifest.selectedBufferID
        }

        for id in recovery.snapshotIDs() where !handled.contains(id) {
            if tombstones.contains(id) { plan.tombstonedFilesToDelete.append(id); continue }
            guard let text = try? recovery.readSnapshot(recoveryFile: "\(id.uuidString).snapshot") else { continue }
            plan.entries.append(RestoreEntry(id: id, metadata: nil, text: text))
        }
        return plan
    }
}
