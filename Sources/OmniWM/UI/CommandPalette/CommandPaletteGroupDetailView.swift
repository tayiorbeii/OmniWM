// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct CommandPaletteGroupDetailView: View {
    let item: CommandPaletteGroupItem?
    let resolution: CommandPaletteGroupResolution?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    definition(item)
                    Divider()
                    resolutionSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } else {
            Text("Select a group to inspect it")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func definition(_ item: CommandPaletteGroupItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.group.name)
                .font(.system(size: 14, weight: .semibold))
            Text(CommandPalettePresentation.groupScopeDescription(item.group.scope))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            clauses(String(localized: "Include"), item.group.include, kind: .include)
            if !item.group.exclude.isEmpty {
                clauses(String(localized: "Exclude"), item.group.exclude, kind: .exclude)
            }
            ForEach(Array(item.issues.enumerated()), id: \.offset) { _, issue in
                Label(
                    CommandPalettePresentation.groupIssueDescription(issue),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
        }
    }

    private func clauses(
        _ title: String,
        _ matchers: [SavedWindowGroupMatcher],
        kind: SavedWindowGroupClauseRef.Kind
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(Array(matchers.enumerated()), id: \.offset) { index, matcher in
                Text(
                    "\(CommandPalettePresentation.groupClauseLabel(.init(kind: kind, index: index)))  \(CommandPalettePresentation.groupMatcherDescription(matcher))"
                )
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var resolutionSection: some View {
        if let resolution {
            VStack(alignment: .leading, spacing: 6) {
                Text(CommandPalettePresentation.groupResolutionSummary(resolution.outcome))
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityIdentifier("command-palette-group-resolution")
                ForEach(resolution.members) { window in
                    windowRow(window)
                }
                if !resolution.unresolved.isEmpty {
                    Text("Unresolved")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(resolution.unresolved) { window in
                        windowRow(window)
                    }
                }
            }
        } else {
            Text("Press Return to resolve this group now. Resolving never changes a window.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func windowRow(_ window: CommandPaletteGroupWindow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(window.appName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if window.isAppHidden {
                    Text("Hidden")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Text([window.title, window.workspaceName].compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if !window.unresolvedClauses.isEmpty {
                Text(CommandPalettePresentation.groupMissingFactsDescription(window.unresolvedClauses))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }
}
