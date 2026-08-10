import SwiftUI
import UpdaterKit

struct SettingsView: View {
    @Bindable var model: UpdaterModel

    // Keys match `Settings`, which reads the same defaults from non-UI code.
    @AppStorage("source.homebrew") private var useHomebrew = true
    @AppStorage("source.macAppStore") private var useMacAppStore = true
    @AppStorage("source.sparkle") private var useSparkle = true
    @AppStorage("source.system") private var useSystem = true
    @AppStorage("refreshIntervalHours") private var refreshIntervalHours = 24.0
    @AppStorage("notifyOnNewUpdates") private var notifyOnNewUpdates = true
    @AppStorage("dryRun") private var dryRun = false
    @AppStorage("unusedThresholdDays") private var unusedThresholdDays = 90
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Sources") {
                Toggle("Homebrew cask catalog", isOn: $useHomebrew)
                Toggle("Mac App Store", isOn: $useMacAppStore)
                Toggle("Sparkle feeds", isOn: $useSparkle)
                Toggle("macOS system updates", isOn: $useSystem)
            }

            Section("Schedule") {
                Picker("Check every", selection: $refreshIntervalHours) {
                    Text("Hour").tag(1.0)
                    Text("6 hours").tag(6.0)
                    Text("Day").tag(24.0)
                    Text("Week").tag(168.0)
                }
                .onChange(of: refreshIntervalHours) { model.rescheduleIfNeeded() }

                Toggle("Notify when new updates appear", isOn: $notifyOnNewUpdates)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { model.settings.launchAtLogin = launchAtLogin }
            }

            Section {
                Picker("Flag apps unused for", selection: $unusedThresholdDays) {
                    Text("Never").tag(0)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                    Text("6 months").tag(180)
                    Text("A year").tag(365)
                }
            } footer: {
                Text("Based on Spotlight's last-opened date. Flagged apps show a "
                     + "Remove button directly on their row. Apps with no usage record, "
                     + "and apps currently running, are never flagged.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Dry run — show commands without running them", isOn: $dryRun)
            } footer: {
                Text("With dry run on, the Update buttons print the exact command to the "
                     + "log instead of executing it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Catalog") {
                LabeledContent("Source") {
                    switch model.catalogOrigin {
                    case .homebrewCache(let url):
                        Text("Homebrew cache").help(url.path)
                    case .downloaded(let url):
                        Text("Downloaded from formulae.brew.sh").help(url.path)
                    case .homebrewInternalCache(let url):
                        // Worth surfacing: this source lacks per-OS version overrides.
                        Label("Homebrew internal index — reduced accuracy",
                              systemImage: "exclamationmark.triangle")
                            .help(url.path)
                    case nil:
                        Text("Not loaded").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Overrides") {
                    Text(OverrideTable.userOverrideURL().path)
                        .font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { launchAtLogin = model.settings.launchAtLogin }
    }
}
