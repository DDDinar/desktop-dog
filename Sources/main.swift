import AppKit
import CoreGraphics
import ServiceManagement

final class DesktopDog: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = UserDefaults.standard
    private var window: DogWindow!
    private var view: DogView!
    private var status: NSStatusItem!
    private var timer: Timer?
    private var dog: Dog!
    private var bed = BedLife(now: ProcessInfo.processInfo.systemUptime)
    private var rawFolders: [CGPoint] = []
    private var folders: [CGPoint] = []
    private var folderRequest = false
    private var folderRefreshInProgress = false
    private var nextFolderRefresh = 0.0
    private var screenID: NSNumber?
    private var screenFrame: CGRect = .zero
    private var bounds: CGRect = .zero
    private var lastTick = 0.0
    private var lastIdleSample = 0.0
    private var nextBedIdleCheck = -Double.infinity
    private var displayedBedFrame: Int?
    private var pointerMotionAt = -Double.infinity
    private var pointer: CGPoint = .zero
    private var idle = 0.0
    private var activeUntil = 0.0
    private var hidden = false
    private let allInput = CGEventType(rawValue: UInt32.max) ?? .mouseMoved

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var scale: CGFloat {
        let value = prefs.double(forKey: "size")
        return [0.75, 1, 1.30].contains(value) ? CGFloat(value) : 1
    }
    private var allowChase: Bool { prefs.object(forKey: "allowChase") as? Bool ?? true }
    private var inBed: Bool { !prefs.bool(forKey: "roaming") }

    func applicationDidFinishLaunching(_ note: Notification) {
        window = DogWindow()
        view = DogView(frame: CGRect(origin: .zero, size: DogWindow.size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "pawprint.fill",
                                   accessibilityDescription: "Собака на столе")
            button.image?.isTemplate = true
            button.toolTip = "Собака на столе"
        }
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        pointer = NSEvent.mouseLocation
        let t = now
        activeUntil = t + 25
        selectScreen(underPointer: true, relocate: true)
        updateWindow()
        window.orderFrontRegardless()
        nextFolderRefresh = t + 1
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        startUpdates()
    }

    private func startUpdates() {
        timer?.invalidate()
        timer = nil
        guard !hidden else { return }
        if inBed {
            nextBedIdleCheck = -.infinity
            scheduleBedUpdate(at: now + 1.0 / 60.0)
            return
        }
        view.prepareRoaming()
        lastTick = now
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tickRoaming),
                          userInfo: nil, repeats: true)
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func applicationWillTerminate(_ note: Notification) {
        timer?.invalidate()
    }

    private func id(of screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func selectScreen(underPointer: Bool, relocate: Bool) {
        let screens = NSScreen.screens
        let point = NSEvent.mouseLocation
        let current = screens.first { id(of: $0) == screenID }
        let preferred = underPointer ? screens.first { $0.frame.contains(point) } : current
        guard let screen = preferred ?? current ?? screens.first else { return }
        let movedScreen = id(of: screen) != screenID
        screenID = id(of: screen)
        screenFrame = screen.frame
        let visible = screen.visibleFrame
        let horizontalInset = min(80 * scale, max(0, visible.width / 2 - 2))
        let topInset = min(132 * scale, max(0, visible.height / 2 - 2))
        bounds = CGRect(x: visible.minX + horizontalInset, y: visible.minY + 9,
                        width: max(1, visible.width - 2 * horizontalInset),
                        height: max(1, visible.height - 9 - topInset))
        if dog == nil || (movedScreen && relocate) {
            let spawn = CGPoint(x: bounds.maxX - bounds.width * 0.12,
                                y: bounds.minY + bounds.height * 0.15)
            dog = Dog(position: bounds.clamp(spawn), now: now)
        }
        dog.position = bounds.clamp(dog.position)
        updateFolderCoordinates()
    }

    private func updateFolderCoordinates() {
        let top = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        folders = DesktopFolders.onScreen(rawFolders, frame: screenFrame, primaryTop: top)
    }

    @objc private func screensChanged() {
        selectScreen(underPointer: false, relocate: true)
        updateWindow()
    }

    @objc private func occlusionChanged() {
        if inBed && !hidden && window.occlusionState.contains(.visible) {
            displayBed()
        }
    }

    private func refreshFolders() {
        guard !folderRefreshInProgress else { return }
        folderRefreshInProgress = true
        nextFolderRefresh = now + 30
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let positions = DesktopFolders.savedPositions()
            DispatchQueue.main.async {
                guard let self else { return }
                self.rawFolders = positions
                self.updateFolderCoordinates()
                self.folderRefreshInProgress = false
                if self.folderRequest {
                    self.folderRequest = false
                    if !self.dog.visitFolder(self.folders, in: self.bounds, scale: self.scale) {
                        self.explainMissingFolders()
                    }
                }
            }
        }
    }

    private func explainMissingFolders() {
        let alert = NSAlert()
        alert.messageText = "Собака не нашла папку поблизости"
        alert.informativeText = "Оставьте видимую папку на рабочем столе. Если macOS запрашивает доступ к рабочему столу, разрешите его в разделе «Конфиденциальность и безопасность» → «Файлы и папки». Собака ориентируется по сохранённым позициям значков Finder."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func updateBed() {
        timer?.invalidate()
        timer = nil
        guard !hidden else { return }
        let t = now
        if !bed.tracksIdle {
            nextBedIdleCheck = .infinity
        } else if t < activeUntil {
            idle = 0
            nextBedIdleCheck = activeUntil
        } else if t >= nextBedIdleCheck {
            idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: allInput)
            // New input can only push the sleep deadline later. Check for
            // input every half second once the dog has fallen asleep.
            nextBedIdleCheck = t + (idle >= Dog.restThreshold ? 0.5 : Dog.restThreshold - idle)
        }
        bed.step(now: t, idle: idle)
        displayBed()

        scheduleBedUpdate(at: min(bed.nextUpdate, nextBedIdleCheck))
    }

    private func scheduleBedUpdate(at deadline: TimeInterval) {
        guard deadline.isFinite else { return }
        let delay = max(0.001, deadline - now)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.updateBed()
        }
        timer.tolerance = min(delay * 0.1, 0.008)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func displayBed() {
        guard displayedBedFrame != bed.frame,
              !window.isVisible || window.occlusionState.contains(.visible) else { return }
        displayedBedFrame = bed.frame
        view.display(dog, dt: 0, bedFrame: bed.frame)
    }

    @objc private func tickRoaming() {
        let t = now
        let dt = min(t - lastTick, 0.08)
        lastTick = t
        guard !hidden, dog != nil else { return }
        let p = NSEvent.mouseLocation
        if hypot(pointer.x - p.x, pointer.y - p.y) > 0.75 {
            pointerMotionAt = t
        }
        pointer = p
        if t - lastIdleSample >= 0.5 {
            idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: allInput)
            lastIdleSample = t
        }
        if t >= nextFolderRefresh { refreshFolders() }
        let sizeScale = scale
        dog.step(now: t, dt: dt, idle: t < activeUntil ? 0 : idle, pointer: p,
                 pointerOnScreen: screenFrame.contains(p), pointerMoving: t - pointerMotionAt < 0.45,
                 allowChase: allowChase, bounds: bounds, folders: folders, scale: sizeScale)
        updateWindow(dt: dt, scale: sizeScale)
    }

    private func updateWindow(dt: TimeInterval = 1.0 / 60.0, scale sizeScale: CGFloat? = nil) {
        guard let dog else { return }
        let s = sizeScale ?? scale
        let size = CGSize(width: DogWindow.size.width * s, height: DogWindow.size.height * s)
        if window.frame.size != size { window.setContentSize(size) }
        let origin = DogWindow.origin(at: dog.position, scale: s)
        let previous = window.frame.origin
        if hypot(previous.x - origin.x, previous.y - origin.y) >= 0.2 {
            window.setFrameOrigin(origin)
        }
        if inBed {
            displayBed()
        } else if !window.isVisible || window.occlusionState.contains(.visible) {
            view.display(dog, dt: dt)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Собака на столе", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(item(hidden ? "Показать собаку" : "Спрятать собаку", #selector(toggleVisible)))
        menu.addItem(item("Погладить", #selector(pet)))
        if inBed {
            menu.addItem(item("Понюхать лежанку", #selector(sniff)))
            menu.addItem(bed.sleeping ? item("Разбудить", #selector(wakeDog)) :
                                        item("Уложить спать", #selector(restDog)))
        } else {
            menu.addItem(item("Погулять", #selector(walk)))
            menu.addItem(item("Обнюхать папку", #selector(sniff)))
            menu.addItem(item("Догонять курсор", #selector(callDog)))
            switch dog?.activity {
            case .lie?, .sleep?: menu.addItem(item("Разбудить", #selector(wakeDog)))
            default: menu.addItem(item("Уложить спать", #selector(restDog)))
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Режим лежанки", #selector(toggleBed), checked: inBed))
        if !inBed {
            menu.addItem(item("Иногда бегать за курсором", #selector(toggleChase), checked: allowChase))
        }
        let sizes = NSMenu(title: "Размер")
        for (label, value) in [("Маленькая", 75), ("Обычная", 100), ("Большая", 130)] {
            let option = item(label, #selector(changeSize), checked: Int((scale * 100).rounded()) == value)
            option.tag = value
            sizes.addItem(option)
        }
        let sizeMenu = NSMenuItem(title: "Размер", action: nil, keyEquivalent: "")
        sizeMenu.submenu = sizes
        menu.addItem(sizeMenu)
        menu.addItem(.separator())
        let loginStatus = SMAppService.mainApp.status
        let loginTitle = loginStatus == .requiresApproval
            ? "Разрешить автозапуск в настройках…" : "Запускать при входе"
        menu.addItem(item(loginTitle, #selector(toggleLogin), checked: loginStatus == .enabled))
        menu.addItem(item("Выход", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false,
                      key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    private func reveal() {
        let wasHidden = hidden
        hidden = false
        status.button?.alphaValue = 1
        window.orderFrontRegardless()
        if wasHidden { startUpdates() }
    }

    @objc private func toggleVisible() {
        if hidden {
            reveal()
        } else {
            hidden = true
            timer?.invalidate()
            timer = nil
            window.orderOut(nil)
            status.button?.alphaValue = 0.55
        }
    }

    @objc private func walk() {
        reveal()
        activeUntil = now + 45
        dog.stroll(in: bounds)
    }

    @objc private func pet() {
        reveal()
        let t = now
        activeUntil = t + 20
        if inBed {
            bed.perform(.wag, now: t)
            updateBed()
        } else {
            dog.pet(now: t)
        }
    }

    @objc private func sniff() {
        reveal()
        activeUntil = now + 45
        if inBed {
            bed.perform(.sniff, now: now)
            updateBed()
            return
        }
        folderRequest = true
        refreshFolders()
    }

    @objc private func callDog() {
        selectScreen(underPointer: true, relocate: true)
        reveal()
        activeUntil = now + 20
        dog.chase(now: now, forced: true)
    }

    @objc private func restDog() {
        reveal()
        if inBed {
            bed.perform(.sleep, now: now)
            updateBed()
        } else {
            dog.rest(now: now)
        }
    }

    @objc private func wakeDog() {
        reveal()
        activeUntil = now + 20
        if inBed {
            bed.perform(.wake, now: now)
            updateBed()
        } else {
            dog.wake(now: now)
        }
    }

    @objc private func toggleBed() {
        let t = now
        prefs.set(inBed, forKey: "roaming")
        dog = Dog(position: dog.position, now: t)
        bed = BedLife(now: t)
        displayedBedFrame = nil
        folderRequest = false
        activeUntil = t + 25
        reveal()
        updateWindow()
        startUpdates()
    }

    @objc private func toggleChase() {
        prefs.set(!allowChase, forKey: "allowChase")
    }

    @objc private func changeSize(_ item: NSMenuItem) {
        prefs.set(Double(item.tag) / 100, forKey: "size")
        selectScreen(underPointer: false, relocate: false)
        updateWindow()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Не удалось изменить автозапуск"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// Use the same bundle and API when configuring the installed copy from a shell.
if CommandLine.arguments.contains("--enable-login-item") ||
   CommandLine.arguments.contains("--login-item-status") {
    let service = SMAppService.mainApp
    do {
        if CommandLine.arguments.contains("--enable-login-item"),
           service.status != .enabled, service.status != .requiresApproval {
            try service.register()
        }
        print(service.status == .enabled ? "enabled" : "status=\(service.status.rawValue)")
        exit(service.status == .enabled ? 0 : 1)
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DesktopDog()
app.delegate = delegate
app.run()
