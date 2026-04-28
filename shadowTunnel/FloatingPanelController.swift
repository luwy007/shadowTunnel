import Cocoa
import SwiftUI

final class FloatingPanelController {
    private let panel: NSPanel
    private var escKeyMonitor: Any?
    private var appDeactivationObserver: Any?
    private var panelResignKeyObserver: Any?
    private var panelResignMainObserver: Any?
    private var hidesOnNextDeactivate = false
    var showModeHideOnDeactivate = false

    init(viewModel: OverlayViewModel) {
        let contentView = ContentView(viewModel: viewModel)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.title = "shadowTunnel"
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.contentView = NSHostingView(rootView: contentView)
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 420, height: 300)
        panel.showsResizeIndicator = true
        panel.standardWindowButton(.closeButton)?.isHidden = false

        setupEscKeyMonitor()
        setupAppDeactivationObserver()
        setupPanelFocusObservers()
    }
    
    deinit {
        if let escKeyMonitor { NSEvent.removeMonitor(escKeyMonitor) }
        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
        }
        if let panelResignKeyObserver {
            NotificationCenter.default.removeObserver(panelResignKeyObserver)
        }
        if let panelResignMainObserver {
            NotificationCenter.default.removeObserver(panelResignMainObserver)
        }
    }

    func show(at point: NSPoint, hidesOnDeactivate: Bool? = nil) {
        hidesOnNextDeactivate = hidesOnDeactivate ?? showModeHideOnDeactivate
        panel.setFrameOrigin(point)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func centerOnScreen(hidesOnDeactivate: Bool? = nil) {
        hidesOnNextDeactivate = hidesOnDeactivate ?? showModeHideOnDeactivate
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        hidesOnNextDeactivate = false
        showModeHideOnDeactivate = false
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }

    private func setupEscKeyMonitor() {
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            guard self.panel.isVisible else { return event }
            guard event.keyCode == 53 else { return event } // Escape
            guard NSApp.keyWindow == self.panel else { return event }
            self.close()
            return nil
        }
    }

    private func setupAppDeactivationObserver() {
        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            DispatchQueue.main.async {
                guard self.panel.isVisible else { return }
                guard self.hidesOnNextDeactivate else { return }
                self.close()
            }
        }
    }

    private func setupPanelFocusObservers() {
        panelResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.hideIfNeeded(reason: "panel didResignKey")
        }

        panelResignMainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignMainNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.hideIfNeeded(reason: "panel didResignMain")
        }
    }

    private func hideIfNeeded(reason: String) {
        guard panel.isVisible else { return }
        guard hidesOnNextDeactivate else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            guard self.hidesOnNextDeactivate else { return }
            self.close()
        }
    }
}
