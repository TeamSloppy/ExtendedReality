import Foundation
import SwiftData

struct WorkspacePersistenceState: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var windows: [WorkspaceWindow]
    var layoutMode: WorkspaceLayoutMode
    var stackOrder: [UUID]
    var stackTransform: WorkspaceStackTransform

    init(
        version: Int = Self.currentVersion,
        windows: [WorkspaceWindow] = [],
        layoutMode: WorkspaceLayoutMode = .freeSpace,
        stackOrder: [UUID] = [],
        stackTransform: WorkspaceStackTransform = .centered
    ) {
        self.version = version
        self.windows = windows
        self.layoutMode = layoutMode
        self.stackOrder = stackOrder
        self.stackTransform = stackTransform
    }
}

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
    private let container: ModelContainer
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(container: ModelContainer) {
        self.container = container
        context = container.mainContext
    }

    func load() -> WorkspacePersistenceState {
        var descriptor = FetchDescriptor<WorkspaceSnapshot>()
        descriptor.fetchLimit = 1
        guard let snapshot = try? context.fetch(descriptor).first else { return .init() }
        if let state = try? decoder.decode(WorkspacePersistenceState.self, from: snapshot.data) {
            return state
        }
        if let legacyWindows = try? decoder.decode([WorkspaceWindow].self, from: snapshot.data) {
            return WorkspacePersistenceState(
                windows: legacyWindows,
                stackOrder: legacyWindows.map(\.id)
            )
        }
        return .init()
    }

    func save(_ state: WorkspacePersistenceState) {
        guard let data = try? encoder.encode(state) else { return }
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
