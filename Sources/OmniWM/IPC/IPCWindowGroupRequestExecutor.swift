// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct IPCWindowGroupRequestExecutor {
    private let controller: WMController
    private let sessionToken: String
    private let reader: SavedWindowGroupSnapshotReader

    init(controller: WMController, sessionToken: String, reader: SavedWindowGroupSnapshotReader? = nil) {
        self.controller = controller
        self.sessionToken = sessionToken
        self.reader = reader ?? controller.defaultSavedWindowGroupReader
    }

    func response(for request: IPCWindowGroupRequest, id: String) -> IPCResponse {
        switch request {
        case .list:
            listResponse(id: id)
        case let .inspect(name):
            inspectResponse(name, id: id)
        case let .resolve(name):
            resolveResponse(name, id: id)
        }
    }

    private func listResponse(id: String) -> IPCResponse {
        let groups = controller.savedWindowGroupCatalog.entries.map { entry in
            IPCWindowGroupSummary(
                id: entry.group.id.uuidString,
                name: entry.group.name,
                scope: IPCWindowGroupScope(entry.group.scope),
                inclusionCount: entry.group.include.count,
                exclusionCount: entry.group.exclude.count,
                isValid: entry.issues.isEmpty
            )
        }
        return .success(
            id: id,
            kind: .windowGroup,
            result: IPCResult(windowGroups: IPCWindowGroupsResult(groups: groups))
        )
    }

    private func inspectResponse(_ name: String, id: String) -> IPCResponse {
        switch controller.savedWindowGroupCatalog.lookup(name) {
        case let .valid(compiled):
            .success(id: id, kind: .windowGroup, result: IPCResult(windowGroup: definition(compiled.group, issues: [])))
        case let .invalid(group, issues):
            .success(id: id, kind: .windowGroup, result: IPCResult(windowGroup: definition(group, issues: issues)))
        case .unknown:
            .failure(id: id, kind: .windowGroup, code: .unknownGroup)
        case .invalidName:
            .failure(id: id, kind: .windowGroup, code: .invalidGroupName)
        }
    }

    private func resolveResponse(_ name: String, id: String) -> IPCResponse {
        switch controller.savedWindowGroupCatalog.lookup(name) {
        case let .valid(compiled):
            switch controller.resolveSavedWindowGroup(compiled, reader: reader) {
            case let .success(resolution):
                return .success(
                    id: id,
                    kind: .windowGroup,
                    result: IPCResult(windowGroupResolution: projected(resolution))
                )
            case .failure:
                return .failure(
                    id: id,
                    kind: .windowGroup,
                    code: .groupScopeUnavailable,
                    result: IPCResult(windowGroup: definition(compiled.group, issues: []))
                )
            }
        case let .invalid(group, issues):
            return .failure(
                id: id,
                kind: .windowGroup,
                code: .invalidGroup,
                result: IPCResult(windowGroup: definition(group, issues: issues))
            )
        case .unknown:
            return .failure(id: id, kind: .windowGroup, code: .unknownGroup)
        case .invalidName:
            return .failure(id: id, kind: .windowGroup, code: .invalidGroupName)
        }
    }

    private func definition(
        _ group: SavedWindowGroup,
        issues: [SavedWindowGroupDefinitionIssue]
    ) -> IPCWindowGroupDefinition {
        IPCWindowGroupDefinition(
            id: group.id.uuidString,
            name: group.name,
            scope: IPCWindowGroupScope(group.scope),
            include: group.include.map(IPCWindowGroupMatcher.init),
            exclude: group.exclude.map(IPCWindowGroupMatcher.init),
            issues: issues.map(IPCWindowGroupIssue.init)
        )
    }

    private func projected(_ resolution: SavedWindowGroupResolution) -> IPCWindowGroupResolution {
        let workspace: IPCWorkspaceRef? = switch resolution.scope {
        case .allWorkspaces:
            nil
        case let .activeWorkspace(workspaceId):
            workspaceRef(workspaceId)
        }
        return IPCWindowGroupResolution(
            id: resolution.group.id.uuidString,
            name: resolution.group.name,
            scope: IPCWindowGroupScope(resolution.group.scope),
            workspace: workspace,
            status: IPCWindowGroupResolutionStatus(resolution.status),
            members: resolution.members.map { member in
                window(
                    member.token,
                    workspaceId: member.workspaceId,
                    isAppHidden: member.isAppHidden,
                    matchedClause: member.clauseIndex,
                    unresolvedClauses: member.unresolvedClauses
                )
            },
            unresolved: resolution.unresolved.map { candidate in
                window(
                    candidate.token,
                    workspaceId: candidate.workspaceId,
                    isAppHidden: candidate.isAppHidden,
                    matchedClause: nil,
                    unresolvedClauses: candidate.clauses
                )
            },
            stale: resolution.stale.map { IPCWindowOpaqueID.encode(token: $0, sessionToken: sessionToken) }
        )
    }

    private func window(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        isAppHidden: Bool,
        matchedClause: Int?,
        unresolvedClauses: [SavedWindowGroupUnresolvedClause]
    ) -> IPCWindowGroupWindow {
        let title = AXWindowService.titlePreferFast(windowId: UInt32(token.windowId))
        return IPCWindowGroupWindow(
            id: IPCWindowOpaqueID.encode(token: token, sessionToken: sessionToken),
            workspace: workspaceRef(workspaceId),
            app: IPCAppRef(appInfo: reader.applicationInfo(token.pid)),
            title: title?.isEmpty == false ? title : nil,
            isAppHidden: isAppHidden,
            matchedClause: matchedClause,
            unresolvedClauses: unresolvedClauses.map(IPCWindowGroupUnresolvedClause.init)
        )
    }

    private func workspaceRef(_ workspaceId: WorkspaceDescriptor.ID) -> IPCWorkspaceRef? {
        controller.workspaceManager.descriptor(for: workspaceId).map {
            IPCWorkspaceRef(descriptor: $0, settings: controller.settings)
        }
    }
}

extension IPCWindowGroupScope {
    init(_ scope: SavedWindowGroupScope) {
        switch scope {
        case .activeWorkspace:
            self = .activeWorkspace
        case .allWorkspaces:
            self = .allWorkspaces
        }
    }
}

extension IPCWindowGroupResolutionStatus {
    init(_ status: SavedWindowGroupResolution.Status) {
        switch status {
        case .resolved:
            self = .resolved
        case .noMatch:
            self = .noMatch
        case .incomplete:
            self = .incomplete
        }
    }
}

extension IPCWindowGroupMatcher {
    init(_ matcher: SavedWindowGroupMatcher) {
        self.init(
            bundleId: matcher.bundleId,
            appNameSubstring: matcher.appNameSubstring,
            titleSubstring: matcher.titleSubstring,
            titleRegex: matcher.titleRegex,
            axRole: matcher.axRole,
            axSubrole: matcher.axSubrole
        )
    }
}

extension IPCWindowGroupClauseRef {
    init(_ clause: SavedWindowGroupClauseRef) {
        self.init(kind: clause.kind == .include ? .include : .exclude, index: clause.index)
    }
}

extension IPCWindowGroupUnresolvedClause {
    init(_ unresolved: SavedWindowGroupUnresolvedClause) {
        self.init(
            clause: IPCWindowGroupClauseRef(unresolved.clause),
            facts: unresolved.facts.map { fact in
                switch fact {
                case .application:
                    .application
                case .title:
                    .title
                case .accessibilityRole:
                    .accessibilityRole
                }
            }
        )
    }
}

extension IPCWindowGroupIssue {
    init(_ issue: SavedWindowGroupDefinitionIssue) {
        switch issue {
        case .invalidName:
            self.init(code: .invalidName)
        case .duplicateName:
            self.init(code: .duplicateName)
        case .duplicateID:
            self.init(code: .duplicateId)
        case .emptyInclusions:
            self.init(code: .emptyInclusions)
        case let .missingBundleId(clause):
            self.init(code: .missingBundleId, clause: IPCWindowGroupClauseRef(clause))
        case let .invalidTitleRegex(clause, message):
            self.init(code: .invalidTitleRegex, clause: IPCWindowGroupClauseRef(clause), message: message)
        }
    }
}
