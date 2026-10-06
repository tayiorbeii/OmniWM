// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum SavedWindowGroupScopeFailure: String, Error, Equatable, Sendable {
    case noFocusedMonitor
    case noActiveWorkspace
}

enum SavedWindowGroupQueryFailure: Error, Equatable {
    case invalidName
    case unknownGroup
    case invalidDefinition([SavedWindowGroupDefinitionIssue])
    case scopeUnavailable(SavedWindowGroupScopeFailure)
}

@MainActor
struct SavedWindowGroupSnapshotReader {
    let applicationInfo: (pid_t) -> AppInfoCache.AppInfo?
    let windowFacts: (WindowState, _ includeTitle: Bool) -> AXWindowFacts
}

extension WMController {
    var savedWindowGroupCatalog: SavedWindowGroupCatalog {
        SavedWindowGroupCatalog(groups: settings.savedWindowGroups)
    }

    func resolveSavedWindowGroup(
        named name: String,
        reader: SavedWindowGroupSnapshotReader? = nil
    ) -> Result<SavedWindowGroupResolution, SavedWindowGroupQueryFailure> {
        let group: CompiledSavedWindowGroup
        switch savedWindowGroupCatalog.lookup(name) {
        case let .valid(compiled):
            group = compiled
        case let .invalid(_, issues):
            return .failure(.invalidDefinition(issues))
        case .unknown:
            return .failure(.unknownGroup)
        case .invalidName:
            return .failure(.invalidName)
        }

        switch savedWindowGroupScope(group.group.scope) {
        case let .success(scope):
            let snapshot = savedWindowGroupSnapshot(
                for: group,
                scope: scope,
                reader: reader ?? defaultSavedWindowGroupReader
            )
            return .success(SavedWindowGroupResolver.resolve(group, in: snapshot))
        case let .failure(failure):
            return .failure(.scopeUnavailable(failure))
        }
    }

    private var defaultSavedWindowGroupReader: SavedWindowGroupSnapshotReader {
        SavedWindowGroupSnapshotReader(
            applicationInfo: { [weak self] pid in self?.resolvedAppInfo(for: pid) },
            windowFacts: { entry, includeTitle in
                AXWindowService.collectWindowFacts(entry.axRef, appPolicy: nil, includeTitle: includeTitle)
            }
        )
    }

    private func savedWindowGroupScope(
        _ scope: SavedWindowGroupScope
    ) -> Result<SavedWindowGroupResolvedScope, SavedWindowGroupScopeFailure> {
        switch scope {
        case .allWorkspaces:
            return .success(.allWorkspaces)
        case .activeWorkspace:
            guard let monitorId = savedWindowGroupFocusedMonitorId else { return .failure(.noFocusedMonitor) }
            guard let workspace = workspaceManager.activeWorkspace(on: monitorId) else {
                return .failure(.noActiveWorkspace)
            }
            return .success(.activeWorkspace(workspace.id))
        }
    }

    private var savedWindowGroupFocusedMonitorId: Monitor.ID? {
        if let monitorId = workspaceManager.interactionMonitorId,
           workspaceManager.monitor(byId: monitorId) != nil
        {
            return monitorId
        }
        guard let token = workspaceManager.nativeManagedFocusToken,
              let workspaceId = workspaceManager.workspace(for: token)
        else {
            return nil
        }
        return workspaceManager.monitor(for: workspaceId)?.id
    }

    private func savedWindowGroupSnapshot(
        for group: CompiledSavedWindowGroup,
        scope: SavedWindowGroupResolvedScope,
        reader: SavedWindowGroupSnapshotReader
    ) -> SavedWindowGroupSnapshot {
        let entries = switch scope {
        case .allWorkspaces:
            workspaceManager.allEntries()
        case let .activeWorkspace(workspaceId):
            workspaceManager.entries(in: workspaceId)
        }

        var candidates: [SavedWindowGroupCandidate] = []
        var staleTokens: [WindowToken] = []
        for entry in entries {
            let token = entry.token
            guard !workspaceManager.isScratchpadToken(token),
                  workspaceManager.hiddenState(for: token)?.isScratchpad != true
            else {
                continue
            }
            guard entry.lifecyclePhase != .destroyed else {
                staleTokens.append(token)
                continue
            }
            let application: SavedWindowGroupCandidate.Application = reader.applicationInfo(token.pid)
                .map { .known(bundleId: $0.bundleId, name: $0.name) } ?? .unavailable
            let requirements = group.windowFactRequirements(for: application)
            let window = requirements.needsWindowFacts ? reader.windowFacts(entry, requirements.needsTitle) : nil
            guard let current = workspaceManager.entry(for: token) else {
                staleTokens.append(token)
                continue
            }
            candidates.append(SavedWindowGroupCandidate(
                token: token,
                workspaceId: current.workspaceId,
                isAppHidden: workspaceManager.isAppHidden(pid: token.pid),
                application: application,
                window: window
            ))
        }
        return SavedWindowGroupSnapshot(scope: scope, candidates: candidates, staleTokens: staleTokens)
    }
}
