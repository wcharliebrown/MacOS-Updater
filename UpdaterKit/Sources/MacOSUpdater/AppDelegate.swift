import AppKit
import Observation
import SwiftUI
import UpdaterKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UpdaterModel()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        installStatusItem()
        observeModel()
        model.startScheduler()

        // Opens the main window straight away, for verifying the UI without having to
        // click the status item: MACOS_UPDATER_SHOW_WINDOW=1 open -a "MacOS Updater"
        if ProcessInfo.processInfo.environment["MACOS_UPDATER_SHOW_WINDOW"] == "1" {
            showMainWindow()
        }

        Task { await model.refresh() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                model: model,
                onOpenWindow: { [weak self] in self?.showMainWindow() },
                onOpenSettings: { [weak self] in self?.showSettings() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )
        self.popover = popover

        updateStatusItem()
    }

    /// Re-registers after every change, which is how `withObservationTracking` is meant
    /// to be used for a continuously observed value.
    private func observeModel() {
        withObservationTracking {
            _ = model.outdatedCount
            _ = model.isScanning
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
                self?.observeModel()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let count = model.outdatedCount
        let symbol = count > 0 ? "arrow.down.circle.fill" : "checkmark.circle"
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: count > 0 ? "\(count) updates available" : "Up to date"
        )
        button.image?.isTemplate = true
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = count > 0
            ? "\(count) app\(count == 1 ? "" : "s") out of date"
            : "All apps are up to date"
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Windows

    func showMainWindow() {
        popover?.performClose(nil)

        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacOS Updater"
            window.contentView = NSHostingView(rootView: MainWindowView(model: model))
            window.setFrameAutosaveName("MacOSUpdaterMain")
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }

        // An accessory app must be activated explicitly or its window opens behind.
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        popover?.performClose(nil)

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
