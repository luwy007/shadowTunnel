import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct FrontmostWindowProbe {
        let shouldHideOnDeactivate: Bool
        let details: String
    }

    let viewModel = OverlayViewModel()
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    private var panelController: FloatingPanelController?
    private var historyWindowController: HistoryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = FloatingPanelController(viewModel: viewModel)
        historyWindowController = HistoryWindowController(store: viewModel.historyStore)
        hotKeyManager = HotKeyManager()
        hotKeyManager?.onTrigger = { [weak self] in
            self?.handleHotKey()
        }
        viewModel.panelController = panelController
        viewModel.hotKeyManager = hotKeyManager
        viewModel.historyWindowController = historyWindowController

        setupStatusItem()
        requestAccessibilityIfNeeded()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "ST"
            button.toolTip = "shadowTunnel"
            if let image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "shadowTunnel") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            }
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Show Settings", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func showSettings() {
        panelController?.centerOnScreen(hidesOnDeactivate: false)
        viewModel.isSettingsPresented = true
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleHotKey() {
        let probe = probeFrontmostWindowForAutoHide()
        panelController?.showModeHideOnDeactivate = probe.shouldHideOnDeactivate
        viewModel.loadSelectionAndShow(panelController: panelController)
    }

    private func probeFrontmostWindowForAutoHide() -> FrontmostWindowProbe {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return FrontmostWindowProbe(
                shouldHideOnDeactivate: false,
                details: "frontmostApp=nil, shouldHideOnDeactivate=false"
            )
        }
        guard frontmostApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return FrontmostWindowProbe(
                shouldHideOnDeactivate: false,
                details: "frontmostApp=\(frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier) is shadowTunnel itself, shouldHideOnDeactivate=false"
            )
        }
        if let accessibilityProbe = probeAccessibilityFullscreen(for: frontmostApp) {
            return accessibilityProbe
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return FrontmostWindowProbe(
                shouldHideOnDeactivate: false,
                details: "frontmostApp=\(frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier), windowInfoList=nil, shouldHideOnDeactivate=false"
            )
        }

        var inspectedWindows: [String] = []
        for windowInfo in windowInfoList {
            guard
                let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == frontmostApp.processIdentifier,
                let layer = windowInfo[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }

            let screen = NSScreen.screens.first(where: { screenContains(windowBounds: bounds, screenFrame: $0.frame) })
            let screenFrameDescription = screen.map { stringify(rect: $0.frame) } ?? "nil"
            let isFullscreen = screen.map { windowEffectivelyFillsScreen(bounds: bounds, screenFrame: $0.frame) } ?? false
            let title = (windowInfo[kCGWindowName as String] as? String) ?? "<untitled>"
            inspectedWindows.append(
                "title=\(title), bounds=\(stringify(rect: bounds)), screen=\(screenFrameDescription), fullscreen=\(isFullscreen)"
            )

            if isFullscreen {
                return FrontmostWindowProbe(
                    shouldHideOnDeactivate: true,
                    details: "frontmostApp=\(frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier), matchedWindow={\(inspectedWindows.last ?? "")}, shouldHideOnDeactivate=true"
                )
            }
        }

        let details: String
        if inspectedWindows.isEmpty {
            details = "frontmostApp=\(frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier), matchedWindows=0, shouldHideOnDeactivate=false"
        } else {
            details = "frontmostApp=\(frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier), inspectedWindows=[\(inspectedWindows.joined(separator: " | "))], shouldHideOnDeactivate=false"
        }
        return FrontmostWindowProbe(shouldHideOnDeactivate: false, details: details)
    }

    private func screenContains(windowBounds: CGRect, screenFrame: CGRect) -> Bool {
        let insetTolerance: CGFloat = 12
        return screenFrame.insetBy(dx: -insetTolerance, dy: -insetTolerance).intersects(windowBounds)
    }

    private func windowEffectivelyFillsScreen(bounds: CGRect, screenFrame: CGRect) -> Bool {
        let sizeTolerance: CGFloat = 24
        let originTolerance: CGFloat = 12
        let widthMatches = abs(bounds.width - screenFrame.width) <= sizeTolerance
        let heightMatches = abs(bounds.height - screenFrame.height) <= sizeTolerance
        let minXMatches = abs(bounds.minX - screenFrame.minX) <= originTolerance
        let minYMatches = abs(bounds.minY - screenFrame.minY) <= originTolerance
        return widthMatches && heightMatches && minXMatches && minYMatches
    }

    private func stringify(rect: CGRect) -> String {
        "x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) w=\(Int(rect.size.width)) h=\(Int(rect.size.height))"
    }

    private func probeAccessibilityFullscreen(for app: NSRunningApplication) -> FrontmostWindowProbe? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let focusedWindow = copyAXElementAttribute(appElement, attribute: kAXFocusedWindowAttribute as CFString)
            ?? copyAXElementAttribute(appElement, attribute: kAXMainWindowAttribute as CFString) {
            if let fullscreenValue = copyAXBoolAttribute(focusedWindow, attribute: "AXFullScreen" as CFString) {
                return FrontmostWindowProbe(
                    shouldHideOnDeactivate: fullscreenValue,
                    details: "frontmostApp=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier), axFullscreen=\(fullscreenValue), source=accessibility, shouldHideOnDeactivate=\(fullscreenValue)"
                )
            }

            return FrontmostWindowProbe(
                shouldHideOnDeactivate: false,
                details: "frontmostApp=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier), axFocusedWindowFound=true, axFullscreen=nil, source=accessibility-fallback"
            )
        }

        return nil
    }

    private func copyAXElementAttribute(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func copyAXBoolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options)
        }
    }
}
