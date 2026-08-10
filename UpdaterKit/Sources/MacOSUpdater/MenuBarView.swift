import SwiftUI
import UpdaterKit

struct MenuBarView: View {
    @Bindable var model: UpdaterModel
    let onOpenWindow: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let report = model.report {
                if report.outdated.isEmpty {
                    Label("Everything is up to date", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(report.outdated) { candidate in
                                MenuRow(candidate: candidate, model: model)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            } else {
                Text(model.isScanning ? "Checking…" : "No results yet")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("MacOS Updater").font(.headline)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check now")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if let report = model.report, !report.outdated.isEmpty {
                Button("Update All") { Task { await model.updateAll() } }
                    .disabled(!model.inProgress.isEmpty)
            }
            HStack {
                Button("Open Window", action: onOpenWindow)
                Spacer()
                Button("Settings…", action: onOpenSettings)
                Button("Quit", action: onQuit)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
    }
}

private struct MenuRow: View {
    let candidate: UpdateCandidate
    @Bindable var model: UpdaterModel

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(candidate: candidate, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.displayName).lineLimit(1)
                Text("\(candidate.installedVersion ?? "—") → \(candidate.latestVersion ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.inProgress.contains(candidate.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Update") { Task { await model.update(candidate) } }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// The real app icon where there is one, so rows are scannable at a glance.
struct AppIcon: View {
    let candidate: UpdateCandidate
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let url = candidate.app?.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: candidate.source == .system ? "apple.logo" : "shippingbox")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
