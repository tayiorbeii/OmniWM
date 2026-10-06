// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension CommandPalettePresentation {
    static let groupsStatusText = String(localized: "Enter resolves the selected group without changing any window.")

    static func groupResolutionSummary(
        _ outcome: Result<SavedWindowGroupResolution, SavedWindowGroupQueryFailure>
    ) -> String {
        switch outcome {
        case let .success(resolution):
            switch resolution.status {
            case .resolved:
                String(localized: "Resolved: \(resolution.members.count) matched")
            case .noMatch:
                String(localized: "No matching windows")
            case .incomplete:
                String(
                    localized: "Incomplete: \(resolution.members.count) matched, \(resolution.unresolved.count) unresolved, \(resolution.stale.count) stale"
                )
            }
        case .failure(.invalidName):
            String(localized: "Invalid group name")
        case .failure(.unknownGroup):
            String(localized: "This group is no longer in settings")
        case .failure(.invalidDefinition):
            String(localized: "Invalid definition: fix it in settings.toml")
        case .failure(.scopeUnavailable(.noFocusedMonitor)):
            String(localized: "No focused monitor: the active workspace is unavailable")
        case .failure(.scopeUnavailable(.noActiveWorkspace)):
            String(localized: "The focused monitor has no active workspace")
        }
    }

    static func groupScopeDescription(_ scope: SavedWindowGroupScope) -> String {
        switch scope {
        case .activeWorkspace:
            String(localized: "Active workspace on the focused monitor")
        case .allWorkspaces:
            String(localized: "All workspaces")
        }
    }

    static func groupClauseLabel(_ clause: SavedWindowGroupClauseRef) -> String {
        "\(clause.kind.rawValue)[\(clause.index)]"
    }

    static func groupMatcherDescription(_ matcher: SavedWindowGroupMatcher) -> String {
        var parts = [matcher.bundleId.isEmpty ? String(localized: "No bundle ID") : matcher.bundleId]
        if let appName = matcher.appNameSubstring, !appName.isEmpty {
            parts.append(String(localized: "app contains \"\(appName)\""))
        }
        if let title = matcher.titleSubstring, !title.isEmpty {
            parts.append(String(localized: "title contains \"\(title)\""))
        }
        if let regex = matcher.titleRegex, !regex.isEmpty {
            parts.append(String(localized: "title matches /\(regex)/"))
        }
        if let role = matcher.axRole, !role.isEmpty {
            parts.append(String(localized: "role \(role)"))
        }
        if let subrole = matcher.axSubrole, !subrole.isEmpty {
            parts.append(String(localized: "subrole \(subrole)"))
        }
        return parts.joined(separator: " · ")
    }

    static func groupIssueDescription(_ issue: SavedWindowGroupDefinitionIssue) -> String {
        switch issue {
        case .invalidName:
            String(localized: "The name is empty or contains control characters.")
        case .duplicateName:
            String(localized: "Another group uses the same name.")
        case .duplicateID:
            String(localized: "Another group uses the same ID.")
        case .emptyInclusions:
            String(localized: "The group has no inclusion clauses.")
        case let .missingBundleId(clause):
            String(localized: "\(groupClauseLabel(clause)) has no bundle ID.")
        case let .invalidTitleRegex(clause, message):
            String(localized: "\(groupClauseLabel(clause)) has an invalid title regex: \(message)")
        }
    }

    static func groupMissingFactsDescription(_ clauses: [SavedWindowGroupUnresolvedClause]) -> String {
        clauses.map { unresolved in
            let facts = unresolved.facts.map { fact in
                switch fact {
                case .application:
                    String(localized: "app identity")
                case .title:
                    String(localized: "title")
                case .accessibilityRole:
                    String(localized: "accessibility role")
                }
            }
            return String(
                localized: "\(groupClauseLabel(unresolved.clause)) needs \(facts.joined(separator: ", "))"
            )
        }
        .joined(separator: "; ")
    }
}
