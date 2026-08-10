import SwiftUI
import UpdaterKit

struct MainWindowView: View {
    @Bindable var model: UpdaterModel
    @State private var showingLog = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let report = model.report {
                if let message = model.statusMessage {
                    Banner(text: message, kind: .warning)
                }
                if !report.tools.hasHomebrew {
                    Banner(
                        text: "Homebrew is not installed, so most third-party apps cannot be "
                            + "checked or updated. Install it from https://brew.sh",
                        kind: .warning
                    )
                }
                if !report.tools.hasMAS && report.candidates.contains(where: { $0.source == .macAppStore }) {
                    Banner(text: "`mas` is not installed — run `brew install mas` to update "
                           + "App Store apps from here.", kind: .info)
                }
                content(report)
            } else {
                ContentUnavailableView(
                    model.isScanning ? "Checking for updates…" : "No results yet",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
        }
        .sheet(isPresented: $showingLog) { LogSheet(model: model) }
        .confirmationDialog(
            "Remove \(model.pendingRemoval?.app.displayName ?? "")?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pending = model.pendingRemoval {
                    Task { await model.remove(app: pending.app, candidate: pending.candidate) }
                }
                model.pendingRemoval = nil
            }
        } message: {
            if let pending = model.pendingRemoval {
                Text(RemovalPlanner.plan(for: pending.app, candidate: pending.candidate).summary)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)

            if let report = model.report, !report.outdated.isEmpty {
                Button {
                    Task { await model.updateAll() }
                } label: {
                    Label("Update All", systemImage: "arrow.down.circle")
                }
                .disabled(!model.inProgress.isEmpty)
            }

            if model.settings.dryRun {
                Text("DRY RUN").font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.yellow.opacity(0.3), in: Capsule())
            }

            Spacer()

            if model.isScanning { ProgressView().controlSize(.small) }
            if let last = model.lastScan {
                Text("Checked \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { showingLog = true } label: {
                Label("Log", systemImage: "text.alignleft")
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func content(_ report: UpdateReport) -> some View {
        List {
            section("Updates Available", report.outdated, emptyText: "Everything is up to date.")

            if !report.undetermined.isEmpty {
                Section {
                    ForEach(report.undetermined) { CandidateRow(candidate: $0, model: model) }
                } header: {
                    Text("Can't Determine")
                } footer: {
                    // Saying so is more useful than a confident wrong answer.
                    Text("Matched a source, but the version numbering could not be "
                         + "reconciled. These are neither confirmed current nor outdated.")
                        .font(.caption)
                }
            }

            if !report.newerThanCatalog.isEmpty {
                Section("Newer Than Catalog") {
                    ForEach(report.newerThanCatalog) { CandidateRow(candidate: $0, model: model) }
                }
            }

            Section("Up to Date (\(report.upToDate.count))") {
                ForEach(report.upToDate.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }) { CandidateRow(candidate: $0, model: model) }
            }

            if !report.unmatched.isEmpty {
                Section {
                    ForEach(report.unmatched) { app in
                        UntrackedRow(app: app, model: model)
                    }
                } header: {
                    Text("Not Tracked (\(report.unmatched.count))")
                } footer: {
                    Text("No update source knows about these apps.")
                        .font(.caption)
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [UpdateCandidate], emptyText: String) -> some View {
        Section(items.isEmpty ? title : "\(title) (\(items.count))") {
            if items.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            } else {
                ForEach(items) { CandidateRow(candidate: $0, model: model) }
            }
        }
    }
}

struct CandidateRow: View {
    let candidate: UpdateCandidate
    @Bindable var model: UpdaterModel

    private var plan: UpdatePlan { UpdatePlanner.plan(for: candidate) }

    /// Updates are keyed by candidate id, removals by app path.
    private var outcome: UpdateOutcome? {
        model.outcomes[candidate.id] ?? candidate.app.flatMap { model.outcomes[$0.id] }
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(candidate: candidate)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.displayName)
                    SourceBadge(candidate: candidate)
                    if candidate.confidence == .heuristic {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .help("Version schemes differ; this comparison is approximate.")
                    }
                }
                if candidate.relation == .updateAvailable {
                    Text("\(candidate.installedVersion ?? "—")  →  \(candidate.latestVersion ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(candidate.installedVersion ?? "—")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let app = candidate.app, let unused = model.unusedMessage(for: app) {
                    Text(unused).font(.caption).foregroundStyle(.orange)
                }
            }

            Spacer()

            // The last outcome stays visible next to the action, so a failed or
            // skipped attempt is never silent — that buried XQuartz and Tunnelblick
            // failures in the log where nobody looks.
            if let outcome { OutcomeBadge(outcome: outcome) }

            let busy = model.inProgress.contains(candidate.id)
                || candidate.app.map { model.isBusy($0) } ?? false

            if busy {
                ProgressView().controlSize(.small)
            } else {
                // A flagged-unused app gets its Remove button in the open — that is
                // the action such a row is most likely to want.
                if let app = candidate.app, model.unusedMessage(for: app) != nil {
                    Button("Remove…", role: .destructive) {
                        model.requestRemoval(app: app, candidate: candidate)
                    }
                }
                if candidate.relation == .updateAvailable {
                    Button(plan.strategy.isAutomatic ? "Update" : "Open…") {
                        Task { await model.update(candidate) }
                    }
                    .help(plan.commandLine.isEmpty ? plan.summary : plan.commandLine)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let app = candidate.app {
                Button(role: .destructive) {
                    model.requestRemoval(app: app, candidate: candidate)
                } label: {
                    Label("Remove \(candidate.displayName)…", systemImage: "trash")
                }
            }
        }
    }
}

/// What happened the last time the user acted on this row.
struct OutcomeBadge: View {
    let outcome: UpdateOutcome

    var body: some View {
        switch outcome {
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let code):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help("Failed (exit \(code)) — details are in the Log.")
        case .skipped(let reason):
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .help(reason)
        case .handedOff(let reason):
            Image(systemName: "arrow.up.forward.square")
                .foregroundStyle(.secondary)
                .help(reason)
        }
    }
}

struct SourceBadge: View {
    let candidate: UpdateCandidate

    // "Homebrew" is reserved for apps brew actually manages. An app installed by hand
    // from the vendor's site is labelled by how it got here, not by which catalog we
    // used to check its version — calling Tunnelblick "Homebrew" misdescribes it.
    private var label: String {
        switch candidate.source {
        case .homebrew: candidate.managedByHomebrew ? "Homebrew" : "Direct download"
        case .macAppStore: "App Store"
        case .sparkle: "Sparkle"
        case .system: "System"
        }
    }

    private var explanation: String {
        switch candidate.source {
        case .homebrew where !candidate.managedByHomebrew:
            return "Installed outside Homebrew. Its version is checked against the "
                + "Homebrew catalog, and updating from here brings the app under "
                + "Homebrew's management."
        case .homebrew:
            return "Installed and updated by Homebrew."
        case .macAppStore:
            return "Installed from the Mac App Store; updated with mas."
        case .sparkle:
            return "Checked against the app's own Sparkle update feed."
        case .system:
            return "A macOS system update, installed with softwareupdate."
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .help(explanation)
    }
}

struct Banner: View {
    enum Kind { case info, warning }
    let text: String
    let kind: Kind

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(kind == .warning ? .orange : .secondary)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(kind == .warning ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.08))
    }
}

struct LogSheet: View {
    @Bindable var model: UpdaterModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Clear") { model.clearLog() }
                Button("Done") { dismiss() }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 680, height: 420)
    }
}


/// A row for apps no update source knows about. They can still be removed.
struct UntrackedRow: View {
    let app: InstalledApp
    @Bindable var model: UpdaterModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                if let unused = model.unusedMessage(for: app) {
                    Text(unused).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let outcome = model.outcomes[app.id] { OutcomeBadge(outcome: outcome) }
            if model.isBusy(app) {
                ProgressView().controlSize(.small)
            } else if model.unusedMessage(for: app) != nil {
                Button("Remove…", role: .destructive) {
                    model.requestRemoval(app: app, candidate: nil)
                }
            }
            Text(app.displayVersion).foregroundStyle(.secondary).font(.callout)
        }
        .contextMenu {
            Button(role: .destructive) {
                model.requestRemoval(app: app, candidate: nil)
            } label: {
                Label("Remove \(app.displayName)…", systemImage: "trash")
            }
        }
    }
}
