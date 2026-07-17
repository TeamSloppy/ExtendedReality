import Foundation
import SwiftData

@Model
final class WorkspaceSnapshot {
    @Attribute(.unique) var key: String
    var data: Data
    var updatedAt: Date

    init(key: String = "primary", data: Data, updatedAt: Date = .now) {
        self.key = key
        self.data = data
        self.updatedAt = updatedAt
    }
}

@MainActor
final class WorkspacePersistence {
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(container: ModelContainer) {
        context = container.mainContext
    }

    func load() -> [WorkspaceWindow] {
        var descriptor = FetchDescriptor<WorkspaceSnapshot>()
        descriptor.fetchLimit = 1
        guard let snapshot = try? context.fetch(descriptor).first else { return [] }
        return (try? decoder.decode([WorkspaceWindow].self, from: snapshot.data)) ?? []
    }

    func save(_ windows: [WorkspaceWindow]) {
        guard let data = try? encoder.encode(windows) else { return }
        var descriptor = FetchDescriptor<WorkspaceSnapshot>()
        descriptor.fetchLimit = 1
        if let snapshot = try? context.fetch(descriptor).first {
            snapshot.data = data
            snapshot.updatedAt = .now
        } else {
            context.insert(WorkspaceSnapshot(data: data))
        }
        try? context.save()
    }
}

