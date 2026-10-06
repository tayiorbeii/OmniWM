// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation

@MainActor
@Observable
final class CommandPaletteGroupBrowser {
    private(set) var items: [CommandPaletteGroupItem] = []
    private(set) var resolution: CommandPaletteGroupResolution?

    func load(_ catalog: SavedWindowGroupCatalog) {
        items = catalog.entries.enumerated().map { index, entry in
            CommandPaletteGroupItem(id: index, group: entry.group, issues: entry.issues)
        }
        resolution = nil
    }

    func record(_ resolution: CommandPaletteGroupResolution) {
        self.resolution = resolution
    }

    func clear() {
        items = []
        resolution = nil
    }
}

@MainActor
extension CommandPaletteController {
    var filteredGroupItems: [CommandPaletteGroupItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groupBrowser.items }
        return groupBrowser.items.filter { $0.group.name.localizedCaseInsensitiveContains(query) }
    }

    var selectedGroupItem: CommandPaletteGroupItem? {
        guard case let .group(id)? = selectedItemID else { return nil }
        return groupBrowser.items.first { $0.id == id }
    }

    var selectedGroupResolution: CommandPaletteGroupResolution? {
        guard let resolution = groupBrowser.resolution,
              selectedItemID == .group(resolution.itemID)
        else {
            return nil
        }
        return resolution
    }

    func refreshGroupItems() {
        if let wmController {
            groupBrowser.load(wmController.savedWindowGroupCatalog)
        } else {
            groupBrowser.clear()
        }
        updateSelectionAfterFilterChange()
    }

    func resolveSelectedGroup() {
        guard let wmController, let item = selectedGroupItem else { return }
        let reader = environment.savedWindowGroupReader(wmController)
        let outcome = resolveGroup(item.group, controller: wmController, reader: reader)
        let resolution = try? outcome.get()
        func window(
            _ token: WindowToken,
            _ workspaceId: WorkspaceDescriptor.ID,
            _ isAppHidden: Bool,
            _ unresolvedClauses: [SavedWindowGroupUnresolvedClause]
        ) -> CommandPaletteGroupWindow {
            let title = AXWindowService.titlePreferFast(windowId: UInt32(token.windowId))
            let workspaceName = wmController.workspaceManager.descriptor(for: workspaceId).map {
                wmController.settings.workspaces.displayName(for: $0.name)
            }
            return CommandPaletteGroupWindow(
                id: token,
                appName: reader.applicationInfo(token.pid)?.name ?? String(localized: "PID \(token.pid)"),
                title: title?.isEmpty == false ? title : nil,
                workspaceName: workspaceName ?? "",
                isAppHidden: isAppHidden,
                unresolvedClauses: unresolvedClauses
            )
        }
        groupBrowser.record(CommandPaletteGroupResolution(
            itemID: item.id,
            outcome: outcome,
            members: resolution?.members.map {
                window($0.token, $0.workspaceId, $0.isAppHidden, $0.unresolvedClauses)
            } ?? [],
            unresolved: resolution?.unresolved.map {
                window($0.token, $0.workspaceId, $0.isAppHidden, $0.clauses)
            } ?? []
        ))
    }

    private func resolveGroup(
        _ group: SavedWindowGroup,
        controller: WMController,
        reader: SavedWindowGroupSnapshotReader
    ) -> Result<SavedWindowGroupResolution, SavedWindowGroupQueryFailure> {
        guard let entry = controller.savedWindowGroupCatalog.entries.first(where: {
            $0.group.id == group.id && $0.group.name == group.name
        }) else {
            return .failure(.unknownGroup)
        }
        guard let compiled = entry.compiled else { return .failure(.invalidDefinition(entry.issues)) }
        return controller.resolveSavedWindowGroup(compiled, reader: reader).mapError { .scopeUnavailable($0) }
    }
}
