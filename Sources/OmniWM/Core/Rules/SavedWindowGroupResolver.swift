// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct SavedWindowGroupClauseRef: Hashable, Sendable {
    enum Kind: String, Sendable {
        case include
        case exclude
    }

    let kind: Kind
    let index: Int
}

enum SavedWindowGroupDefinitionIssue: Equatable, Sendable {
    case invalidName
    case duplicateName
    case duplicateID
    case emptyInclusions
    case missingBundleId(SavedWindowGroupClauseRef)
    case invalidTitleRegex(SavedWindowGroupClauseRef, message: String)
}

enum SavedWindowGroupFact: String, Equatable, Sendable {
    case application
    case title
    case accessibilityRole
}

struct SavedWindowGroupUnresolvedClause: Equatable, Sendable {
    let clause: SavedWindowGroupClauseRef
    let facts: [SavedWindowGroupFact]
}

enum SavedWindowGroupResolvedScope: Equatable, Sendable {
    case activeWorkspace(WorkspaceDescriptor.ID)
    case allWorkspaces
}

struct SavedWindowGroupCandidate: Equatable, Sendable {
    enum Application: Equatable, Sendable {
        case known(bundleId: String?, name: String?)
        case unavailable
    }

    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let isAppHidden: Bool
    let application: Application
    let window: AXWindowFacts?
}

struct SavedWindowGroupSnapshot: Equatable, Sendable {
    let scope: SavedWindowGroupResolvedScope
    let candidates: [SavedWindowGroupCandidate]
    let staleTokens: [WindowToken]
}

struct SavedWindowGroupResolution: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case resolved
        case noMatch
        case incomplete
    }

    struct Member: Equatable, Sendable {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let isAppHidden: Bool
        let clauseIndex: Int
        let unresolvedClauses: [SavedWindowGroupUnresolvedClause]
    }

    struct UnresolvedCandidate: Equatable, Sendable {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let isAppHidden: Bool
        let clauses: [SavedWindowGroupUnresolvedClause]
    }

    let group: SavedWindowGroup
    let scope: SavedWindowGroupResolvedScope
    let members: [Member]
    let unresolved: [UnresolvedCandidate]
    let stale: [WindowToken]

    var status: Status {
        if !unresolved.isEmpty || !stale.isEmpty || members.contains(where: { !$0.unresolvedClauses.isEmpty }) {
            return .incomplete
        }
        return members.isEmpty ? .noMatch : .resolved
    }
}

@MainActor
struct CompiledSavedWindowGroup {
    let group: SavedWindowGroup
    let inclusions: [CompiledWindowRule]
    let exclusions: [CompiledWindowRule]

    func windowFactRequirements(
        for application: SavedWindowGroupCandidate.Application
    ) -> (needsWindowFacts: Bool, needsTitle: Bool) {
        let rules = (inclusions + exclusions).filter { rule in
            guard case let .known(bundleId, name) = application else { return true }
            return rule.matchesApp(bundleId: bundleId, appName: name)
        }
        return (
            rules.contains { $0.requiresTitle || $0.requiresAccessibilityRole },
            rules.contains(where: \.requiresTitle)
        )
    }
}

enum SavedWindowGroupLookup {
    case valid(CompiledSavedWindowGroup)
    case invalid(SavedWindowGroup, [SavedWindowGroupDefinitionIssue])
    case unknown
    case invalidName
}

@MainActor
struct SavedWindowGroupCatalog {
    struct Entry {
        let group: SavedWindowGroup
        let issues: [SavedWindowGroupDefinitionIssue]
        let compiled: CompiledSavedWindowGroup?
    }

    let entries: [Entry]

    init(groups: [SavedWindowGroup]) {
        let names = groups.compactMap { SavedWindowGroup.normalizedName($0.name).map(Self.nameKey) }
        let duplicateNames = Self.duplicates(names)
        let duplicateIDs = Self.duplicates(groups.map(\.id))
        entries = groups.map { group in
            var issues: [SavedWindowGroupDefinitionIssue] = []
            if let name = SavedWindowGroup.normalizedName(group.name) {
                if duplicateNames.contains(Self.nameKey(name)) { issues.append(.duplicateName) }
            } else {
                issues.append(.invalidName)
            }
            if duplicateIDs.contains(group.id) { issues.append(.duplicateID) }
            if group.include.isEmpty { issues.append(.emptyInclusions) }
            let inclusions = Self.compile(group.include, kind: .include, issues: &issues)
            let exclusions = Self.compile(group.exclude, kind: .exclude, issues: &issues)
            let compiled = issues.isEmpty
                ? CompiledSavedWindowGroup(group: group, inclusions: inclusions, exclusions: exclusions)
                : nil
            return Entry(group: group, issues: issues, compiled: compiled)
        }
    }

    func lookup(_ rawName: String) -> SavedWindowGroupLookup {
        guard let name = SavedWindowGroup.normalizedName(rawName) else { return .invalidName }
        let key = Self.nameKey(name)
        guard let entry = entries.first(where: {
            SavedWindowGroup.normalizedName($0.group.name).map(Self.nameKey) == key
        }) else {
            return .unknown
        }
        guard let compiled = entry.compiled else { return .invalid(entry.group, entry.issues) }
        return .valid(compiled)
    }

    private static func nameKey(_ name: String) -> [UInt8] {
        Array(name.utf8)
    }

    private static func duplicates<T: Hashable>(_ values: [T]) -> Set<T> {
        var seen: Set<T> = []
        var duplicates: Set<T> = []
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates
    }

    private static func compile(
        _ matchers: [SavedWindowGroupMatcher],
        kind: SavedWindowGroupClauseRef.Kind,
        issues: inout [SavedWindowGroupDefinitionIssue]
    ) -> [CompiledWindowRule] {
        matchers.enumerated().compactMap { index, matcher in
            let clause = SavedWindowGroupClauseRef(kind: kind, index: index)
            let rule = matcher.appRule
            if !rule.hasBundleId {
                issues.append(.missingBundleId(clause))
            }
            var regexErrors: [UUID: String] = [:]
            let compiled = CompiledWindowRule.compile(
                rule: rule,
                source: .user,
                order: index,
                invalidRegexMessagesByRuleId: &regexErrors
            )
            if let message = regexErrors[rule.id] {
                issues.append(.invalidTitleRegex(clause, message: message))
            }
            return compiled
        }
    }
}

@MainActor
enum SavedWindowGroupResolver {
    private enum ClauseOutcome {
        case matched
        case notMatched
        case unresolved([SavedWindowGroupFact])
    }

    static func resolve(
        _ group: CompiledSavedWindowGroup,
        in snapshot: SavedWindowGroupSnapshot
    ) -> SavedWindowGroupResolution {
        var members: [SavedWindowGroupResolution.Member] = []
        var unresolved: [SavedWindowGroupResolution.UnresolvedCandidate] = []
        var seen: Set<WindowToken> = []

        for candidate in snapshot.candidates where isInScope(candidate, snapshot.scope) {
            guard seen.insert(candidate.token).inserted else { continue }
            let inclusions = outcomes(of: group.inclusions, kind: .include, for: candidate)
            guard let clauseIndex = inclusions.firstMatch else {
                if !inclusions.unresolved.isEmpty {
                    unresolved.append(unresolvedCandidate(candidate, clauses: inclusions.unresolved))
                }
                continue
            }
            let exclusions = outcomes(of: group.exclusions, kind: .exclude, for: candidate)
            if exclusions.firstMatch != nil { continue }
            if !exclusions.unresolved.isEmpty {
                unresolved.append(unresolvedCandidate(candidate, clauses: exclusions.unresolved))
                continue
            }
            members.append(.init(
                token: candidate.token,
                workspaceId: candidate.workspaceId,
                isAppHidden: candidate.isAppHidden,
                clauseIndex: clauseIndex,
                unresolvedClauses: inclusions.unresolved
            ))
        }

        return SavedWindowGroupResolution(
            group: group.group,
            scope: snapshot.scope,
            members: members.sorted {
                ($0.clauseIndex, $0.token.pid, $0.token.windowId) < ($1.clauseIndex, $1.token.pid, $1.token.windowId)
            },
            unresolved: unresolved.sorted { tokenOrder($0.token, $1.token) },
            stale: Set(snapshot.staleTokens).subtracting(seen).sorted(by: tokenOrder)
        )
    }

    private static func unresolvedCandidate(
        _ candidate: SavedWindowGroupCandidate,
        clauses: [SavedWindowGroupUnresolvedClause]
    ) -> SavedWindowGroupResolution.UnresolvedCandidate {
        SavedWindowGroupResolution.UnresolvedCandidate(
            token: candidate.token,
            workspaceId: candidate.workspaceId,
            isAppHidden: candidate.isAppHidden,
            clauses: clauses
        )
    }

    private static func isInScope(
        _ candidate: SavedWindowGroupCandidate,
        _ scope: SavedWindowGroupResolvedScope
    ) -> Bool {
        switch scope {
        case .allWorkspaces:
            true
        case let .activeWorkspace(workspaceId):
            candidate.workspaceId == workspaceId
        }
    }

    private static func tokenOrder(_ lhs: WindowToken, _ rhs: WindowToken) -> Bool {
        (lhs.pid, lhs.windowId) < (rhs.pid, rhs.windowId)
    }

    private static func outcomes(
        of rules: [CompiledWindowRule],
        kind: SavedWindowGroupClauseRef.Kind,
        for candidate: SavedWindowGroupCandidate
    ) -> (firstMatch: Int?, unresolved: [SavedWindowGroupUnresolvedClause]) {
        var firstMatch: Int?
        var unresolved: [SavedWindowGroupUnresolvedClause] = []
        for (index, rule) in rules.enumerated() {
            switch outcome(of: rule, for: candidate) {
            case .matched:
                firstMatch = firstMatch ?? index
            case .notMatched:
                continue
            case let .unresolved(facts):
                unresolved.append(.init(clause: .init(kind: kind, index: index), facts: facts))
            }
        }
        return (firstMatch, unresolved)
    }

    private static func outcome(
        of rule: CompiledWindowRule,
        for candidate: SavedWindowGroupCandidate
    ) -> ClauseOutcome {
        var unavailable: [SavedWindowGroupFact] = []
        switch candidate.application {
        case let .known(bundleId, name):
            guard rule.matchesApp(bundleId: bundleId, appName: name) else { return .notMatched }
        case .unavailable:
            unavailable.append(.application)
        }

        let window = candidate.window.flatMap { $0.attributeFetchSucceeded ? $0 : nil }
        if rule.requiresTitle {
            if let title = window?.title {
                guard rule.matchesTitle(title) else { return .notMatched }
            } else {
                unavailable.append(.title)
            }
        }
        if rule.requiresAccessibilityRole {
            if let window {
                guard rule.matchesAccessibilityRole(role: window.role, subrole: window.subrole) else {
                    return .notMatched
                }
            } else {
                unavailable.append(.accessibilityRole)
            }
        }
        return unavailable.isEmpty ? .matched : .unresolved(unavailable)
    }
}
