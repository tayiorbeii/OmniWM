// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum CLIWindowGroupRenderer {
    static func formatted(_ payload: IPCResult.Payload, format: CLIOutputFormat) -> String {
        switch payload {
        case let .windowGroups(groups):
            formattedGroups(groups, format: format)
        case let .windowGroup(definition):
            formattedDefinition(definition, format: format)
        case let .windowGroupResolution(resolution):
            formattedResolution(resolution, format: format)
        default:
            ""
        }
    }

    static func formattedGroups(_ payload: IPCWindowGroupsResult, format: CLIOutputFormat) -> String {
        guard !payload.groups.isEmpty else { return "no saved window groups" }
        let rows = payload.groups.map { group in
            [
                group.name,
                group.scope.rawValue,
                String(group.inclusionCount),
                String(group.exclusionCount),
                group.isValid ? "valid" : "invalid"
            ]
        }
        return CLITableRenderer.formatRows(
            headers: ["GROUP", "SCOPE", "INCLUDE", "EXCLUDE", "DEFINITION"],
            rows: rows,
            format: format
        )
    }

    static func formattedDefinition(_ payload: IPCWindowGroupDefinition, format: CLIOutputFormat) -> String {
        let summary = "group \(payload.name) (\(payload.scope.rawValue)): "
            + (payload.issues.isEmpty ? "valid definition" : "invalid definition")
        let clauses = payload.include.enumerated().map { clauseRow(.include, $0, $1) }
            + payload.exclude.enumerated().map { clauseRow(.exclude, $0, $1) }
        var sections = [
            summary,
            CLITableRenderer.formatRows(
                headers: ["CLAUSE", "BUNDLE ID", "APP NAME", "TITLE", "TITLE REGEX", "ROLE", "SUBROLE"],
                rows: clauses,
                format: format
            )
        ]
        if !payload.issues.isEmpty {
            sections.append(CLITableRenderer.formatRows(
                headers: ["ISSUE", "CLAUSE", "DETAIL"],
                rows: payload.issues.map { issue in
                    [issue.code.rawValue, issue.clause.map(clauseLabel) ?? "-", issue.message ?? "-"]
                },
                format: format
            ))
        }
        return sections.joined(separator: "\n\n")
    }

    static func formattedResolution(_ payload: IPCWindowGroupResolution, format: CLIOutputFormat) -> String {
        let scope = payload.workspace.map { "\(payload.scope.rawValue) \($0.displayName)" } ?? payload.scope.rawValue
        var sections = ["group \(payload.name) (\(scope)): \(statusDescription(payload))"]
        if !payload.members.isEmpty {
            sections.append(CLITableRenderer.formatRows(
                headers: ["ID", "WORKSPACE", "APP", "TITLE", "HIDDEN", "CLAUSE", "UNRESOLVED"],
                rows: payload.members.map { member in
                    windowRow(member) + [
                        member.matchedClause.map { "include[\($0)]" } ?? "-",
                        unresolvedDescription(member.unresolvedClauses)
                    ]
                },
                format: format
            ))
        }
        if !payload.unresolved.isEmpty {
            sections.append(CLITableRenderer.formatRows(
                headers: ["UNRESOLVED ID", "WORKSPACE", "APP", "TITLE", "HIDDEN", "MISSING FACTS"],
                rows: payload.unresolved.map { windowRow($0) + [unresolvedDescription($0.unresolvedClauses)] },
                format: format
            ))
        }
        if !payload.stale.isEmpty {
            sections.append("stale windows skipped: \(payload.stale.count)")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func statusDescription(_ payload: IPCWindowGroupResolution) -> String {
        switch payload.status {
        case .resolved:
            "resolved \(payload.members.count) window(s)"
        case .noMatch:
            "no matching windows"
        case .incomplete:
            "incomplete: \(payload.members.count) window(s) matched, \(payload.unresolved.count) unresolved, "
                + "\(payload.stale.count) stale"
        }
    }

    private static func windowRow(_ window: IPCWindowGroupWindow) -> [String] {
        [
            window.id,
            window.workspace?.displayName ?? "-",
            window.app?.name ?? "-",
            window.title ?? "-",
            window.isAppHidden ? "yes" : "no"
        ]
    }

    private static func unresolvedDescription(_ clauses: [IPCWindowGroupUnresolvedClause]) -> String {
        guard !clauses.isEmpty else { return "-" }
        return clauses.map { clause in
            "\(clauseLabel(clause.clause)): \(clause.facts.map(\.rawValue).joined(separator: ","))"
        }.joined(separator: "; ")
    }

    private static func clauseLabel(_ clause: IPCWindowGroupClauseRef) -> String {
        "\(clause.kind.rawValue)[\(clause.index)]"
    }

    private static func clauseRow(
        _ kind: IPCWindowGroupClauseKind,
        _ index: Int,
        _ matcher: IPCWindowGroupMatcher
    ) -> [String] {
        [
            clauseLabel(IPCWindowGroupClauseRef(kind: kind, index: index)),
            matcher.bundleId.isEmpty ? "-" : matcher.bundleId,
            matcher.appNameSubstring ?? "-",
            matcher.titleSubstring ?? "-",
            matcher.titleRegex ?? "-",
            matcher.axRole ?? "-",
            matcher.axSubrole ?? "-"
        ]
    }
}
