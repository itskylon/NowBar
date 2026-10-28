// Appended to the app delegate source by scripts/test-panel.sh so this exercises
// the actual private status-button action and dismissal observers, without test hooks.
extension MeterAppDelegate {
    func verifyWhenStatusItemIsReady(deadline: Date, launchedAt: TimeInterval) {
        if let button = statusItem.button, let window = button.window, window.frame.height > 0,
           !button.bounds.isEmpty,
           NSScreen.screens.contains(where: {
               let bounds = window.convertToScreen(button.convert(button.bounds, to: nil))
               return $0.frame.contains(NSPoint(x: bounds.midX, y: bounds.midY))
           }) {
            print(String(format: "Cold launch to native status readiness: %.1f ms",
                         (ProcessInfo.processInfo.systemUptime - launchedAt) * 1000))
            verifyPanelInteraction()
        } else {
            precondition(Date() < deadline, "The native status item must register on a screen")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [self] in
                verifyWhenStatusItemIsReady(deadline: deadline, launchedAt: launchedAt)
            }
        }
    }

    func verifyPanelInteraction() {
        precondition(localMouseMonitor != nil && globalMouseMonitor != nil && resignObserver != nil,
                     "All dismissal observers must be installed")
        precondition(!panel.isVisible, "Startup leaves the panel hidden")
        let firstClickStarted = ProcessInfo.processInfo.systemUptime
        // Opening must work before any provider has returned data.
        store.snapshots = []
        store.refreshing = true
        // A startup focus transition precedes the first click, in the same run-loop turn.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        statusItem.button?.performClick(nil)
        precondition(panel.isVisible, "First status-button click opens the panel immediately")
        print(String(format: "First native button action to visible panel: %.1f ms (no provider data)",
                     (ProcessInfo.processInfo.systemUptime - firstClickStarted) * 1000))
        // A delayed application activation callback is not panel focus loss.
        // Nonactivating panels must survive this even during startup activation churn.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        precondition(panel.isVisible, "A late application deactivation must not undo the first left click")
        let button = statusItem.button!
        let buttonRect = button.window!.convertToScreen(button.convert(button.bounds, to: nil))
        func menuPoint() -> NSPoint {
            // MenuBarAgent relocates its backing window during registration.
            // Each simulated new click needs that click's current coordinates.
            let bounds = button.window!.convertToScreen(button.convert(button.bounds, to: nil))
            return NSPoint(x: bounds.midX, y: bounds.midY)
        }
        func globalClick(at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        // MenuBarAgent can deliver the same click to both global and local handlers.
        // These recorded events also work while the real pointer is elsewhere.
        dismissPanelForGlobalMouseDown(globalClick(at: menuPoint()))
        precondition(panel.isVisible, "A forwarded status click must not dismiss the panel it just opened")
        DispatchQueue.main.async { [self] in
            precondition(panel.isVisible, "A previous focus event must not dismiss the newly opened panel")
            dismissPanelForGlobalMouseDown(globalClick(at: menuPoint()))
            statusItem.button?.performClick(nil)
            precondition(!panel.isVisible, "Second click closes the panel")
            statusItem.button?.performClick(nil)
            precondition(panel.isVisible, "Next click reopens the panel")
            precondition(panel.isKeyWindow, "The panel accepts keyboard focus without app activation")
            let otherPanel = MeterPanel(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            otherPanel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [self, otherPanel] in
                precondition(!panel.isVisible, "Losing panel keyboard focus dismisses the current panel")
                otherPanel.orderOut(nil)
                statusItem.button?.performClick(nil)
                precondition(panel.isVisible, "Panel reopens after deactivation")
                dismissPanelForGlobalMouseDown(globalClick(at: NSPoint(x: buttonRect.midX, y: buttonRect.minY - 100)))
                precondition(!panel.isVisible, "A real outside click dismisses the panel")
                statusItem.button?.performClick(nil)
                panel.cancelOperation(nil)
                precondition(!panel.isVisible, "Escape closes the panel")
                verifyPanelFocusFamily()
            }
        }
    }

    func verifyPanelFocusFamily() {
        statusItem.button?.performClick(nil)
        let child = MeterPanel(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.addChildWindow(child, ordered: .above)
        child.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [self, child] in
            precondition(child.isKeyWindow && panel.isVisible,
                         "An attached popover may take focus without dismissing its parent")
            let unrelated = MeterPanel(contentRect: NSRect(x: 250, y: 100, width: 100, height: 100),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            unrelated.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [self, child, unrelated] in
                precondition(!panel.isVisible, "Focus leaving an attached popover dismisses the parent")
                panel.removeChildWindow(child)
                child.orderOut(nil)
                unrelated.orderOut(nil)
                statusItem.button?.performClick(nil)
                // Queue an old resignation, then close and reopen in the same turn.
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
                statusItem.button?.performClick(nil)
                statusItem.button?.performClick(nil)
                DispatchQueue.main.async { [self] in
                    precondition(panel.isVisible, "A queued old resignation cannot dismiss a new presentation")
                    panel.cancelOperation(nil)
                    verifyStatusClickRecovery()
                }
            }
        }
    }

    func verifyStatusClickRecovery() {
        let button = statusItem.button!
        let bounds = button.window!.convertToScreen(button.convert(button.bounds, to: nil))
        let anchor = StatusItemScreenRegions.rectangles(button: bounds, screens: NSScreen.screens.map(\.frame)).last!
        let point = NSPoint(x: anchor.midX, y: anchor.midY)
        let base = ProcessInfo.processInfo.systemUptime + 1
        func deliver(_ event: NSEvent, count: UInt32 = 100) {
            handleGlobalMouseEvent(event, mouseDownCount: count)
        }
        func accept(_ event: NSEvent?, count: UInt32 = 100) -> Bool {
            acceptStatusAction(event, mouseDownCount: count)
        }
        func mouse(_ type: NSEvent.EventType, _ time: TimeInterval, at location: NSPoint? = nil, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location ?? point, modifierFlags: flags,
                               timestamp: time, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        deliver(mouse(.leftMouseDown, base))
        deliver(mouse(.leftMouseUp, base + 0.05))
        precondition(!panel.isVisible, "Recovery waits for any queued native action")
        DispatchQueue.main.async { [self] in
            precondition(panel.isVisible, "A missing native action must open the panel after mouse-up")
            precondition(panelAnchor == anchor, "Recovery retains the display that was clicked")
            precondition(!accept(mouse(.leftMouseUp, base + 0.01)),
                         "A delayed native action for the recovered gesture must not toggle twice")
            precondition(!accept(mouse(.leftMouseUp, base + 0.08)),
                         "A forwarded action timestamped after physical release must not close the recovered panel")
            completeStatusClick(down: base)
            precondition(panel.isVisible, "Recovery is idempotent")
            deliver(mouse(.leftMouseDown, base + 1))
            precondition(!accept(mouse(.leftMouseUp, base + 0.01)),
                         "A delayed previous gesture remains suppressed after the next mouse-down")
            deliver(mouse(.leftMouseUp, base + 1.05))
            completeStatusClick(down: base + 1)
            precondition(!panel.isVisible, "A second recovered physical click closes the panel")
            precondition(accept(nil), "Accessibility input is not suppressed after recovery")
            statusItem.button?.performClick(nil)
            precondition(panel.isVisible, "Accessibility can reopen after a recovered click")
            panel.orderOut(nil)
            deliver(mouse(.leftMouseDown, base + 2))
            deliver(mouse(.leftMouseUp, base + 2.05, at: NSPoint(x: point.x, y: anchor.minY - 100)))
            completeStatusClick(down: base + 2)
            precondition(!panel.isVisible, "Dragging out cancels recovery")
            deliver(mouse(.leftMouseDown, base + 3, flags: .control))
            deliver(mouse(.leftMouseUp, base + 3.05, flags: .control))
            precondition(statusClick == nil && !panel.isVisible, "Control-click retains native context-menu behavior")
            deliver(mouse(.leftMouseUp, base + 4))
            precondition(!panel.isVisible, "Mouse-up without a matching down cannot open the panel")
            deliver(mouse(.leftMouseDown, base + 5))
            deliver(mouse(.leftMouseUp, base + 5.05))
            deliver(mouse(.leftMouseDown, base + 6, at: NSPoint(x: point.x, y: anchor.minY - 100)))
            completeStatusClick(down: base + 5)
            precondition(!panel.isVisible, "An outside click cancels pending recovery")
            precondition(accept(mouse(.leftMouseUp, base + 7.01)), "Native action is accepted")
            deliver(mouse(.leftMouseDown, base + 7))
            deliver(mouse(.leftMouseUp, base + 7.05))
            completeStatusClick(down: base + 7)
            precondition(!panel.isVisible, "Global delivery after native action cannot handle the click again")
            precondition(accept(mouse(.leftMouseUp, base + 8), count: 101), "A new native-only click remains usable")
            print("Panel interaction acceptance passed: startup without data, activation churn, toggling, outside clicks, focus, child windows, Escape, missing native click recovery and deduplication")
            NSApp.terminate(nil)
        }
    }

}

MainActor.assumeIsolated {
    let screens = [NSRect(x: -3008, y: 0, width: 3008, height: 1692),
                   NSRect(x: 0, y: 0, width: 3008, height: 1692),
                   NSRect(x: 3008, y: 300, width: 1800, height: 1000)]
    let sourceButton = NSRect(x: -675, y: 1662, width: 192, height: 22)
    let regions = StatusItemScreenRegions.rectangles(button: sourceButton, screens: screens)
    precondition(regions.count == 3 && regions[0] == sourceButton, "Retain the native source button")
    precondition(regions[1] == NSRect(x: 2333, y: 1662, width: 192, height: 22), "Match the second display before AppKit moves the native window")
    precondition(regions[2] == NSRect(x: 4133, y: 1270, width: 192, height: 22), "Support different display sizes and vertical origins")
    precondition(!regions.contains { $0.contains(NSPoint(x: 2600, y: 1670)) }, "Another menu item is outside NowBar")
    precondition(!regions.contains { $0.contains(NSPoint(x: 2400, y: 1600)) }, "The desktop below NowBar is outside")
    precondition(StatusItemScreenRegions.rectangles(button: .zero, screens: screens).isEmpty, "Ignore unavailable button geometry")
    precondition(StatusItemScreenRegions.rectangles(button: sourceButton, screens: []).isEmpty, "Handle missing screens")
    print("Status-item screen regions: 7 checks passed")
    let launchedAt = ProcessInfo.processInfo.systemUptime
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MeterAppDelegate()
    app.delegate = delegate
    // Let AppKit launch the delegate once. Calling its callback manually before
    // app.run() creates two status items and leaves duplicate dismissal observers.
    var launchCount = 0
    let launchObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didFinishLaunchingNotification, object: app, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            launchCount += 1
            precondition(launchCount == 1, "The interaction test must use one native launch")
            DispatchQueue.main.async {
                delegate.verifyWhenStatusItemIsReady(deadline: Date().addingTimeInterval(3), launchedAt: launchedAt)
            }
        }
    }
    withExtendedLifetime((delegate, launchObserver)) { app.run() }
}
