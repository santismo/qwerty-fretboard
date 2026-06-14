import AppKit
import ApplicationServices
import Carbon
import CoreMIDI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let firstLaunchKey = "didShowInitialSettings"
    private let engine = FretboardEngine()
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController?
    private var overlayWindow: FretboardOverlayWindow?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine.onStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshMenuBar()
                self?.overlayWindow?.refresh()
            }
        }
        engine.onActiveNotesChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.overlayWindow?.refresh()
            }
        }
        setupStatusItem()
        installEventTap()
        refreshMenuBar()
        if !UserDefaults.standard.bool(forKey: firstLaunchKey) {
            UserDefaults.standard.set(true, forKey: firstLaunchKey)
            toggleSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.panic()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    @MainActor private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 58)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleSettings)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = "Qwerty Fretboard"
    }

    @MainActor private func refreshMenuBar() {
        statusItem.button?.title = "QF"
        statusItem.button?.image = KeyboardIcon.make(active: engine.isMidiModeActive)
        statusItem.button?.imagePosition = .imageLeft
        if engine.showOverlay && engine.isMidiModeActive {
            showOverlay()
        } else {
            overlayWindow?.orderOut(nil)
        }
        settingsWindow?.refresh()
    }

    @MainActor @objc private func toggleSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(engine: engine)
        }
        settingsWindow?.toggle(relativeTo: statusItem.button)
    }

    @MainActor private func showOverlay() {
        if overlayWindow == nil {
            overlayWindow = FretboardOverlayWindow(engine: engine)
        }
        overlayWindow?.show()
    }

    private func installEventTap() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            engine.permissionStatus = "Input Monitoring or Accessibility permission is needed for global keyboard MIDI mode."
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            return delegate.handle(proxy: proxy, type: type, event: event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            engine.permissionStatus = "Could not install keyboard event tap. Recheck Input Monitoring permission."
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        engine.permissionStatus = "Keyboard capture ready."
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isDown = type == .keyDown || type == .flagsChanged
        let isUp = type == .keyUp || type == .flagsChanged

        if type == .keyDown, keyCode == Key.space.rawValue,
           flags.contains(.maskControl),
           flags.contains(.maskAlternate),
           flags.contains(.maskCommand) {
            engine.toggleMidiMode()
            return nil
        }

        guard engine.isMidiModeActive else {
            return Unmanaged.passUnretained(event)
        }

        let handled: Bool
        if type == .flagsChanged {
            handled = engine.handleFlagsChanged(keyCode: keyCode, flags: flags)
        } else if isDown {
            handled = engine.handleKeyDown(keyCode: keyCode, repeatEvent: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        } else if isUp {
            handled = engine.handleKeyUp(keyCode: keyCode)
        } else {
            handled = false
        }

        return handled ? nil : Unmanaged.passUnretained(event)
    }
}

enum Key: CGKeyCode {
    case a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9
    case b = 11, q = 12, w = 13, e = 14, r = 15, y = 16, t = 17
    case one = 18, two = 19, three = 20, four = 21, six = 22, five = 23, equal = 24, nine = 25, seven = 26, minus = 27, eight = 28, zero = 29
    case rightBracket = 30, o = 31, u = 32, leftBracket = 33, i = 34, p = 35
    case l = 37, j = 38, quote = 39, k = 40, semicolon = 41
    case comma = 43, slash = 44, n = 45, m = 46, period = 47, grave = 50
    case delete = 51, enter = 36, tab = 48, space = 49
    case leftArrow = 123, rightArrow = 124, downArrow = 125, upArrow = 126
    case leftShift = 56, rightShift = 60, leftControl = 59, rightControl = 62, leftOption = 58, rightOption = 61, capsLock = 57
}

struct FretKey: Hashable {
    let keyCode: CGKeyCode
    let label: String
    let fret: Int
    let row: Int
}

final class FretboardEngine: @unchecked Sendable {
    var onStateChanged: (() -> Void)?
    var onActiveNotesChanged: (() -> Void)?
    var isMidiModeActive = false
    var showOverlay: Bool {
        didSet { UserDefaults.standard.set(showOverlay, forKey: "showOverlay"); onStateChanged?() }
    }
    var velocity: Int {
        didSet { velocity = min(127, max(1, velocity)); UserDefaults.standard.set(velocity, forKey: "velocity"); onStateChanged?() }
    }
    var semitoneTranspose: Int {
        didSet { semitoneTranspose = min(12, max(-12, semitoneTranspose)); UserDefaults.standard.set(semitoneTranspose, forKey: "transpose"); onStateChanged?() }
    }
    var bendRange: Int {
        didSet { bendRange = min(12, max(1, bendRange)); UserDefaults.standard.set(bendRange, forKey: "bendRange"); sendBendSensitivity(); onStateChanged?() }
    }
    var permissionStatus = "Keyboard capture not ready." { didSet { onStateChanged?() } }

    private var midiClient = MIDIClientRef()
    private var midiSource = MIDIEndpointRef()
    private var activeNotes: [CGKeyCode: Int] = [:]
    private var sustainedNotes = Set<Int>()
    private var sustainHeld = false
    private var sustainLatched = false
    private var highStrings = false
    private var octaveTranspose = 0
    private var pitchMode = "center"
    private var vibratoTimer: Timer?
    private var vibratoPhase = 0.0
    private var controlHeld = Set<CGKeyCode>()
    private var optionHeld = Set<CGKeyCode>()

    let rows: [[FretKey]] = [
        [
            FretKey(keyCode: Key.one.rawValue, label: "1", fret: 0, row: 0),
            FretKey(keyCode: Key.two.rawValue, label: "2", fret: 1, row: 0),
            FretKey(keyCode: Key.three.rawValue, label: "3", fret: 2, row: 0),
            FretKey(keyCode: Key.four.rawValue, label: "4", fret: 3, row: 0),
            FretKey(keyCode: Key.five.rawValue, label: "5", fret: 4, row: 0),
            FretKey(keyCode: Key.six.rawValue, label: "6", fret: 5, row: 0),
            FretKey(keyCode: Key.seven.rawValue, label: "7", fret: 6, row: 0),
            FretKey(keyCode: Key.eight.rawValue, label: "8", fret: 7, row: 0),
            FretKey(keyCode: Key.nine.rawValue, label: "9", fret: 8, row: 0),
            FretKey(keyCode: Key.zero.rawValue, label: "0", fret: 9, row: 0),
            FretKey(keyCode: Key.minus.rawValue, label: "-", fret: 10, row: 0)
        ],
        [
            FretKey(keyCode: Key.q.rawValue, label: "Q", fret: 0, row: 1),
            FretKey(keyCode: Key.w.rawValue, label: "W", fret: 1, row: 1),
            FretKey(keyCode: Key.e.rawValue, label: "E", fret: 2, row: 1),
            FretKey(keyCode: Key.r.rawValue, label: "R", fret: 3, row: 1),
            FretKey(keyCode: Key.t.rawValue, label: "T", fret: 4, row: 1),
            FretKey(keyCode: Key.y.rawValue, label: "Y", fret: 5, row: 1),
            FretKey(keyCode: Key.u.rawValue, label: "U", fret: 6, row: 1),
            FretKey(keyCode: Key.i.rawValue, label: "I", fret: 7, row: 1),
            FretKey(keyCode: Key.o.rawValue, label: "O", fret: 8, row: 1),
            FretKey(keyCode: Key.p.rawValue, label: "P", fret: 9, row: 1),
            FretKey(keyCode: Key.leftBracket.rawValue, label: "[", fret: 10, row: 1)
        ],
        [
            FretKey(keyCode: Key.a.rawValue, label: "A", fret: 0, row: 2),
            FretKey(keyCode: Key.s.rawValue, label: "S", fret: 1, row: 2),
            FretKey(keyCode: Key.d.rawValue, label: "D", fret: 2, row: 2),
            FretKey(keyCode: Key.f.rawValue, label: "F", fret: 3, row: 2),
            FretKey(keyCode: Key.g.rawValue, label: "G", fret: 4, row: 2),
            FretKey(keyCode: Key.h.rawValue, label: "H", fret: 5, row: 2),
            FretKey(keyCode: Key.j.rawValue, label: "J", fret: 6, row: 2),
            FretKey(keyCode: Key.k.rawValue, label: "K", fret: 7, row: 2),
            FretKey(keyCode: Key.l.rawValue, label: "L", fret: 8, row: 2),
            FretKey(keyCode: Key.semicolon.rawValue, label: ";", fret: 9, row: 2),
            FretKey(keyCode: Key.quote.rawValue, label: "'", fret: 10, row: 2)
        ],
        [
            FretKey(keyCode: Key.z.rawValue, label: "Z", fret: 0, row: 3),
            FretKey(keyCode: Key.x.rawValue, label: "X", fret: 1, row: 3),
            FretKey(keyCode: Key.c.rawValue, label: "C", fret: 2, row: 3),
            FretKey(keyCode: Key.v.rawValue, label: "V", fret: 3, row: 3),
            FretKey(keyCode: Key.b.rawValue, label: "B", fret: 4, row: 3),
            FretKey(keyCode: Key.n.rawValue, label: "N", fret: 5, row: 3),
            FretKey(keyCode: Key.m.rawValue, label: "M", fret: 6, row: 3),
            FretKey(keyCode: Key.comma.rawValue, label: ",", fret: 7, row: 3),
            FretKey(keyCode: Key.period.rawValue, label: ".", fret: 8, row: 3),
            FretKey(keyCode: Key.slash.rawValue, label: "/", fret: 9, row: 3),
            FretKey(keyCode: Key.rightShift.rawValue, label: "Shift", fret: 10, row: 3)
        ]
    ]

    init() {
        showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        velocity = UserDefaults.standard.object(forKey: "velocity") as? Int ?? 100
        semitoneTranspose = UserDefaults.standard.object(forKey: "transpose") as? Int ?? 0
        bendRange = UserDefaults.standard.object(forKey: "bendRange") as? Int ?? 2
        setupMIDI()
    }

    var activeKeyCodes: Set<CGKeyCode> {
        Set(activeNotes.keys)
    }

    var modeLabel: String {
        isMidiModeActive ? "MIDI mode active" : "Keyboard pass-through"
    }

    func noteName(for midiNote: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[midiNote % 12])\(midiNote / 12 - 1)"
    }

    func midiNote(for key: FretKey) -> Int {
        tuning[key.row].base + key.fret + octaveTranspose * 12 + semitoneTranspose
    }

    func rowName(_ row: Int) -> String {
        let name = tuning[row].name
        let octave = octaveTranspose == 0 ? "" : " \(octaveTranspose >= 0 ? "+" : "")\(octaveTranspose)"
        let transpose = semitoneTranspose == 0 ? "" : " \(semitoneTranspose > 0 ? "+" : "")\(semitoneTranspose)st"
        return name + octave + transpose
    }

    func toggleMidiMode() {
        isMidiModeActive.toggle()
        if !isMidiModeActive {
            panic()
        }
        onStateChanged?()
    }

    func setMidiMode(_ enabled: Bool) {
        guard isMidiModeActive != enabled else { return }
        toggleMidiMode()
    }

    func handleKeyDown(keyCode: CGKeyCode, repeatEvent: Bool) -> Bool {
        switch keyCode {
        case Key.capsLock.rawValue:
            highStrings.toggle()
            onStateChanged?()
            return true
        case Key.leftArrow.rawValue:
            guard pitchMode != "left" else { return true }
            pitchMode = "left"
            stopVibrato()
            sendPitchBend(0)
            return true
        case Key.rightArrow.rawValue:
            guard pitchMode != "right" else { return true }
            pitchMode = "right"
            stopVibrato()
            sendPitchBend(16383)
            return true
        case Key.upArrow.rawValue:
            if !repeatEvent { octaveTranspose += 1; onStateChanged?() }
            return true
        case Key.downArrow.rawValue:
            if !repeatEvent { octaveTranspose -= 1; onStateChanged?() }
            return true
        case Key.enter.rawValue:
            startVibrato()
            return true
        case Key.space.rawValue:
            if !repeatEvent { sustainHeld = true }
            return true
        case Key.grave.rawValue:
            if !repeatEvent { velocity = min(127, velocity + 5) }
            return true
        case Key.tab.rawValue:
            if !repeatEvent { velocity = max(1, velocity - 5) }
            return true
        case Key.delete.rawValue:
            return true
        default:
            break
        }

        guard let fretKey = rows.flatMap({ $0 }).first(where: { $0.keyCode == keyCode }) else {
            return false
        }
        guard !repeatEvent, activeNotes[keyCode] == nil else {
            return true
        }
        let note = midiNote(for: fretKey)
        activeNotes[keyCode] = note
        send([0x90, UInt8(note), UInt8(velocity)])
        onActiveNotesChanged?()
        return true
    }

    func handleKeyUp(keyCode: CGKeyCode) -> Bool {
        switch keyCode {
        case Key.leftArrow.rawValue where pitchMode == "left":
            pitchMode = "center"
            stopVibrato()
            sendPitchBend(8192)
            return true
        case Key.rightArrow.rawValue where pitchMode == "right":
            pitchMode = "center"
            stopVibrato()
            sendPitchBend(8192)
            return true
        case Key.enter.rawValue:
            stopVibrato()
            return true
        case Key.space.rawValue:
            sustainHeld = false
            if !sustainLatched { releaseSustainedNotes() }
            return true
        default:
            break
        }

        guard let note = activeNotes.removeValue(forKey: keyCode) else {
            return rows.flatMap({ $0 }).contains(where: { $0.keyCode == keyCode })
        }
        if sustainHeld || sustainLatched {
            sustainedNotes.insert(note)
        } else {
            send([0x80, UInt8(note), 0])
        }
        onActiveNotesChanged?()
        return true
    }

    func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        if keyCode == Key.leftControl.rawValue || keyCode == Key.rightControl.rawValue {
            return handleModifier(keyCode: keyCode, active: flags.contains(.maskControl), store: &controlHeld, transpose: -2)
        }
        if keyCode == Key.leftOption.rawValue || keyCode == Key.rightOption.rawValue {
            return handleModifier(keyCode: keyCode, active: flags.contains(.maskAlternate), store: &optionHeld, transpose: 2)
        }
        if keyCode == Key.leftShift.rawValue || keyCode == Key.rightShift.rawValue {
            if flags.contains(.maskShift) {
                return handleKeyDown(keyCode: keyCode, repeatEvent: activeNotes[keyCode] != nil)
            } else {
                return handleKeyUp(keyCode: keyCode)
            }
        }
        return false
    }

    func panic() {
        activeNotes.values.forEach { send([0x80, UInt8($0), 0]) }
        sustainedNotes.forEach { send([0x80, UInt8($0), 0]) }
        activeNotes.removeAll()
        sustainedNotes.removeAll()
        sustainHeld = false
        stopVibrato()
        send([0xB0, 123, 0])
        onActiveNotesChanged?()
    }

    private var tuning: [(name: String, base: Int)] {
        highStrings ? [("e", 64), ("B", 59), ("G", 55), ("D", 50)] : [("G", 55), ("D", 50), ("A", 45), ("E", 40)]
    }

    private func setupMIDI() {
        MIDIClientCreate("qwerty-fretboard" as CFString, nil, nil, &midiClient)
        MIDISourceCreate(midiClient, "qwerty-fretboard" as CFString, &midiSource)
        sendBendSensitivity()
    }

    private func handleModifier(keyCode: CGKeyCode, active: Bool, store: inout Set<CGKeyCode>, transpose: Int) -> Bool {
        if active, !store.contains(keyCode) {
            store.insert(keyCode)
            semitoneTranspose += transpose
        } else if !active, store.contains(keyCode) {
            store.remove(keyCode)
            semitoneTranspose -= transpose
        }
        return true
    }

    private func releaseSustainedNotes() {
        for note in sustainedNotes where !activeNotes.values.contains(note) {
            send([0x80, UInt8(note), 0])
        }
        sustainedNotes.removeAll()
        onActiveNotesChanged?()
    }

    private func startVibrato() {
        guard vibratoTimer == nil else { return }
        vibratoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.pitchMode == "center" else { return }
            self.vibratoPhase += 6.0 / 60.0 * Double.pi * 2
            let depth = Int(Double(2200) * (2.0 / Double(max(1, self.bendRange))))
            self.sendPitchBend(8192 + Int(sin(self.vibratoPhase) * Double(depth)))
        }
    }

    private func stopVibrato() {
        vibratoTimer?.invalidate()
        vibratoTimer = nil
        vibratoPhase = 0
    }

    private func sendBendSensitivity() {
        send([0xB0, 101, 0])
        send([0xB0, 100, 0])
        send([0xB0, 6, UInt8(bendRange)])
        send([0xB0, 38, 0])
        send([0xB0, 101, 127])
        send([0xB0, 100, 127])
    }

    private func sendPitchBend(_ value: Int) {
        let clamped = min(16383, max(0, value))
        send([0xE0, UInt8(clamped & 0x7F), UInt8((clamped >> 7) & 0x7F)])
    }

    private func send(_ bytes: [UInt8]) {
        var packetList = MIDIPacketList()
        withUnsafeMutablePointer(to: &packetList) { packetListPointer in
            var packet = MIDIPacketListInit(packetListPointer)
            packet = MIDIPacketListAdd(packetListPointer, 1024, packet, 0, bytes.count, bytes)
            MIDIReceived(midiSource, packetListPointer)
        }
    }
}

final class SettingsWindowController: NSWindowController {
    private let engine: FretboardEngine
    private let statusLabel = NSTextField(labelWithString: "")
    private let modeButton = NSButton(title: "", target: nil, action: nil)
    private let overlayCheck = NSButton(checkboxWithTitle: "Show mini fretboard when MIDI mode is active", target: nil, action: nil)
    private let velocitySlider = NSSlider(value: 100, minValue: 1, maxValue: 127, target: nil, action: nil)
    private let transposeSlider = NSSlider(value: 0, minValue: -12, maxValue: 12, target: nil, action: nil)
    private let bendSlider = NSSlider(value: 2, minValue: 1, maxValue: 12, target: nil, action: nil)
    private let valuesLabel = NSTextField(labelWithString: "")

    init(engine: FretboardEngine) {
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Qwerty Fretboard"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle(relativeTo button: NSStatusBarButton?) {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            if let buttonWindow = button?.window {
                let buttonFrame = buttonWindow.convertToScreen(button?.frame ?? .zero)
                window.setFrameTopLeftPoint(NSPoint(x: buttonFrame.minX - 300, y: buttonFrame.minY - 8))
            } else {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func refresh() {
        modeButton.title = engine.isMidiModeActive ? "Turn MIDI Mode Off" : "Turn MIDI Mode On"
        overlayCheck.state = engine.showOverlay ? .on : .off
        velocitySlider.integerValue = engine.velocity
        transposeSlider.integerValue = engine.semitoneTranspose
        bendSlider.integerValue = engine.bendRange
        statusLabel.stringValue = "\(engine.modeLabel)\nMIDI source: qwerty-fretboard\n\(engine.permissionStatus)\nHotkey: Control + Option + Command + Space"
        valuesLabel.stringValue = "Velocity \(engine.velocity)   Transpose \(engine.semitoneTranspose) st   Bend \(engine.bendRange) st"
    }

    private func buildUI() {
        guard let window else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack

        let title = NSTextField(labelWithString: "Qwerty Fretboard")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(statusLabel)

        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        modeButton.bezelStyle = .rounded
        stack.addArrangedSubview(modeButton)

        overlayCheck.target = self
        overlayCheck.action = #selector(toggleOverlay)
        stack.addArrangedSubview(overlayCheck)

        addSlider(stack, title: "Velocity", slider: velocitySlider, action: #selector(changeVelocity))
        addSlider(stack, title: "Transpose", slider: transposeSlider, action: #selector(changeTranspose))
        addSlider(stack, title: "Pitch bend range", slider: bendSlider, action: #selector(changeBend))
        stack.addArrangedSubview(valuesLabel)

        let panic = NSButton(title: "Panic / All Notes Off", target: self, action: #selector(panic))
        panic.bezelStyle = .rounded
        stack.addArrangedSubview(panic)

        let help = NSTextField(labelWithString: """
        Note rows:
        1 row: 1 2 3 4 5 6 7 8 9 0 -
        Q row: Q W E R T Y U I O P [
        A row: A S D F G H J K L ; '
        Z row: Z X C V B N M , . / Right Shift

        Controls:
        Caps Lock: high strings
        Enter: vibrato
        Space: sustain
        Arrows: bend / octave
        ` / Tab: velocity up / down
        Control: -2 st while held
        Option: +2 st while held
        """)
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 0
        stack.addArrangedSubview(help)

        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        stack.addArrangedSubview(quit)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
    }

    private func addSlider(_ stack: NSStackView, title: String, slider: NSSlider, action: Selector) {
        let label = NSTextField(labelWithString: title)
        slider.target = self
        slider.action = action
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(slider)
    }

    @objc private func toggleMode() {
        engine.toggleMidiMode()
    }

    @objc private func toggleOverlay() {
        engine.showOverlay = overlayCheck.state == .on
    }

    @objc private func changeVelocity() {
        engine.velocity = velocitySlider.integerValue
    }

    @objc private func changeTranspose() {
        engine.semitoneTranspose = transposeSlider.integerValue
    }

    @objc private func changeBend() {
        engine.bendRange = bendSlider.integerValue
    }

    @objc private func panic() {
        engine.panic()
    }
}

final class FretboardOverlayWindow: NSWindow {
    private let view: FretboardView

    init(engine: FretboardEngine) {
        view = FretboardView(engine: engine)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        super.init(
            contentRect: NSRect(x: screenFrame.midX - 360, y: screenFrame.minY + 60, width: 720, height: 230),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = view
    }

    func show() {
        refresh()
        orderFrontRegardless()
    }

    func refresh() {
        view.needsDisplay = true
    }
}

final class FretboardView: NSView {
    private let engine: FretboardEngine

    init(engine: FretboardEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.04, alpha: 0.86).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        let margin: CGFloat = 18
        let labelWidth: CGFloat = 52
        let bottomBarHeight: CGFloat = 34
        let rowHeight: CGFloat = 38
        let gap: CGFloat = 8
        let fretCount = 11
        let cellWidth = (bounds.width - margin * 2 - labelWidth - CGFloat(fretCount - 1) * gap) / CGFloat(fretCount)
        let startY = bounds.height - margin - rowHeight

        let active = engine.activeKeyCodes
        for (rowIndex, row) in engine.rows.enumerated() {
            let y = startY - CGFloat(rowIndex) * (rowHeight + gap)
            drawText(engine.rowName(rowIndex), in: NSRect(x: margin, y: y + 11, width: labelWidth - 8, height: 20), color: .white, size: 13, alignment: .right)
            for key in row {
                let x = margin + labelWidth + CGFloat(key.fret) * (cellWidth + gap)
                let rect = NSRect(x: x, y: y, width: cellWidth, height: rowHeight)
                let isActive = active.contains(key.keyCode)
                let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                (isActive ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)).setFill()
                path.fill()
                NSColor(calibratedWhite: isActive ? 1 : 0.22, alpha: 1).setStroke()
                path.lineWidth = 1
                path.stroke()

                let note = engine.noteName(for: engine.midiNote(for: key))
                drawText(key.label, in: NSRect(x: rect.minX, y: rect.minY + 21, width: rect.width, height: 16), color: isActive ? .black : .white, size: 12, alignment: .center)
                drawText(note, in: NSRect(x: rect.minX, y: rect.minY + 6, width: rect.width, height: 14), color: isActive ? .darkGray : .lightGray, size: 10, alignment: .center)
            }
        }

        let barRect = NSRect(x: margin, y: margin, width: bounds.width - margin * 2, height: bottomBarHeight)
        NSColor(calibratedWhite: 0.10, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 8, yRadius: 8).fill()
        KeyboardIcon.draw(in: NSRect(x: barRect.minX + 10, y: barRect.minY + 8, width: 24, height: 18), active: true, template: false)
        drawText(
            "qwerty-fretboard MIDI  •  Control Option Command Space toggles keyboard capture",
            in: NSRect(x: barRect.minX + 42, y: barRect.minY + 8, width: barRect.width - 52, height: 18),
            color: .white,
            size: 11,
            alignment: .left
        )
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, size: CGFloat, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .paragraphStyle: style
        ]
        text.draw(in: rect, withAttributes: attrs)
    }
}

enum KeyboardIcon {
    static func make(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        draw(in: NSRect(x: 1, y: 2, width: 20, height: 14), active: active, template: true)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    static func draw(in rect: NSRect, active: Bool, template: Bool) {
        let color: NSColor = template ? .black : (active ? .systemGreen : .white)
        color.setStroke()
        color.withAlphaComponent(template ? 1 : 0.18).setFill()
        let body = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        body.lineWidth = 1.6
        body.fill()
        body.stroke()

        let keyWidth = rect.width / 6.5
        let keyHeight = rect.height / 4.8
        for row in 0..<2 {
            for col in 0..<5 {
                let x = rect.minX + 3 + CGFloat(col) * (keyWidth + 1.4) + CGFloat(row) * 1.4
                let y = rect.maxY - 4.5 - CGFloat(row) * (keyHeight + 1.7)
                let key = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: keyWidth, height: keyHeight), xRadius: 1, yRadius: 1)
                color.withAlphaComponent(template ? 1 : 0.75).setFill()
                key.fill()
            }
        }
        let space = NSBezierPath(roundedRect: NSRect(x: rect.midX - rect.width * 0.21, y: rect.minY + 3, width: rect.width * 0.42, height: keyHeight), xRadius: 1, yRadius: 1)
        color.withAlphaComponent(template ? 1 : 0.75).setFill()
        space.fill()
    }
}
