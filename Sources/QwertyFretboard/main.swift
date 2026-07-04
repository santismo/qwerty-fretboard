import AppKit
import ApplicationServices
import Carbon
import CoreMIDI

@main
struct QwertyFretboardMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        AppDelegate.retainedDelegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    fileprivate static var retainedDelegate: AppDelegate?
    private let engine = FretboardEngine()
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController?
    private var overlayWindow: FretboardOverlayWindow?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupApplicationMenu()
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
        engine.onMIDIMonitorChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.settingsWindow?.refreshMIDIMonitor()
            }
        }
        setupStatusItem()
        refreshMenuBar()
        showSettings()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showSettings()
            self?.installEventTap()
        }
    }

    @MainActor func applicationDidBecomeActive(_ notification: Notification) {
        installEventTap()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { [weak self] in
            self?.showSettings()
        }
        return true
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
        statusItem = NSStatusBar.system.statusItem(withLength: 34)
        statusItem.isVisible = true
        statusItem.autosaveName = "QwertyFretboardStatusItem"
        statusItem.button?.toolTip = "Qwerty Fretboard"
        statusItem.button?.font = .systemFont(ofSize: 17, weight: .semibold)
        statusItem.button?.alignment = .center
        statusItem.menu = makeStatusMenu()
    }

    @MainActor private func refreshMenuBar() {
        statusItem.button?.title = engine.isMidiModeActive ? "⌨●" : "⌨"
        statusItem.button?.image = nil
        statusItem.button?.imagePosition = .noImage
        statusItem.menu = makeStatusMenu()
        if engine.showOverlay {
            showOverlay()
        } else {
            overlayWindow?.orderOut(nil)
        }
        settingsWindow?.refresh()
    }

    @MainActor @objc private func toggleSettings() {
        showSettings()
    }

    @MainActor private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(engine: engine)
        }
        settingsWindow?.show()
    }

    @MainActor @objc private func toggleMidiModeFromMenu() {
        engine.toggleMidiMode()
    }

    @MainActor @objc private func toggleOverlayFromMenu() {
        engine.showOverlay.toggle()
    }

    @MainActor @objc private func panicFromMenu() {
        engine.panic()
    }

    @MainActor private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: engine.isMidiModeActive ? "Qwerty Fretboard: MIDI On" : "Qwerty Fretboard: MIDI Off", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(toggleSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let midi = NSMenuItem(title: engine.isMidiModeActive ? "Turn MIDI Mode Off" : "Turn MIDI Mode On", action: #selector(toggleMidiModeFromMenu), keyEquivalent: "")
        midi.target = self
        menu.addItem(midi)

        let ccInput = NSMenuItem(title: engine.ccInputEnabled ? "MIDI CC Input On" : "MIDI CC Input Off", action: nil, keyEquivalent: "")
        ccInput.isEnabled = false
        menu.addItem(ccInput)

        let overlay = NSMenuItem(title: "Show Mini Fretboard", action: #selector(toggleOverlayFromMenu), keyEquivalent: "")
        overlay.target = self
        overlay.state = engine.showOverlay ? .on : .off
        menu.addItem(overlay)

        let panic = NSMenuItem(title: "Panic / All Notes Off", action: #selector(panicFromMenu), keyEquivalent: "")
        panic.target = self
        menu.addItem(panic)

        menu.addItem(NSMenuItem.separator())

        let help = NSMenuItem(title: "Hotkey: Control Option Command Space", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Qwerty Fretboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @MainActor private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings...", action: #selector(toggleSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Qwerty Fretboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @MainActor private func showOverlay() {
        if overlayWindow == nil {
            overlayWindow = FretboardOverlayWindow(engine: engine)
        }
        overlayWindow?.show()
    }

    fileprivate func installEventTap() {
        if let eventTap, CFMachPortIsValid(eventTap) {
            engine.permissionStatus = "Keyboard capture ready."
            return
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        guard AXIsProcessTrusted() else {
            engine.permissionStatus = "Accessibility access is off for global computer-keyboard capture. MIDI CC input can still trigger Qwerty commands."
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
            engine.permissionStatus = "Could not install keyboard event tap. Recheck Input Monitoring and Accessibility permissions."
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        engine.permissionStatus = "Keyboard capture ready."
    }

    fileprivate func requestAccessibilityPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            installEventTap()
        } else {
            engine.permissionStatus = "Accessibility access is still off for this app copy. Remove old Qwerty Fretboard entries, add /Applications/Qwerty Fretboard.app, then click Check Keyboard Access. MIDI CC input still works internally."
        }
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

struct MIDIControlMapping: Codable, Hashable, Identifiable {
    var id: UUID
    var enabled: Bool
    var cc: Int
    var channel: Int
    var keyCode: CGKeyCode

    init(id: UUID = UUID(), enabled: Bool = true, cc: Int, channel: Int = 0, keyCode: CGKeyCode) {
        self.id = id
        self.enabled = enabled
        self.cc = cc
        self.channel = channel
        self.keyCode = keyCode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case cc
        case channel
        case keyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cc = try container.decodeIfPresent(Int.self, forKey: .cc) ?? 80
        channel = try container.decodeIfPresent(Int.self, forKey: .channel) ?? 0
        keyCode = try container.decodeIfPresent(CGKeyCode.self, forKey: .keyCode) ?? Key.leftArrow.rawValue
        self = normalized
    }

    var normalized: MIDIControlMapping {
        var copy = self
        copy.cc = min(127, max(0, copy.cc))
        copy.channel = min(16, max(0, copy.channel))
        return copy
    }

    func matches(controller: Int, incomingChannel: Int) -> Bool {
        enabled && cc == controller && (channel == 0 || channel == incomingChannel)
    }
}

struct KeyCommandOption {
    let keyCode: CGKeyCode
    let title: String
}

struct MIDIMonitorEvent {
    let date: Date
    let source: String
    let message: String
}

enum MiniFretboardViewMode: String, CaseIterable {
    case fretboard
    case noteNames
    case slantedKeyboard

    var title: String {
        switch self {
        case .fretboard:
            "Fretboard"
        case .noteNames:
            "Note Names"
        case .slantedKeyboard:
            "Slanted Keyboard"
        }
    }
}

final class FretboardEngine: @unchecked Sendable {
    private static let ccInputEnabledKey = "ccInputEnabled"
    private static let ccMappingsKey = "ccMappings"

    var onStateChanged: (() -> Void)?
    var onActiveNotesChanged: (() -> Void)?
    var onMIDIMonitorChanged: (() -> Void)?
    var isMidiModeActive = false
    var showOverlay: Bool {
        didSet { UserDefaults.standard.set(showOverlay, forKey: "showOverlay"); onStateChanged?() }
    }
    var miniViewMode: MiniFretboardViewMode {
        didSet { UserDefaults.standard.set(miniViewMode.rawValue, forKey: "miniViewMode"); onStateChanged?() }
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
    var ccInputEnabled: Bool {
        didSet {
            UserDefaults.standard.set(ccInputEnabled, forKey: Self.ccInputEnabledKey)
            if !ccInputEnabled {
                releaseMappedCCKeys()
            }
            onStateChanged?()
        }
    }
    var ccMappings: [MIDIControlMapping] {
        didSet {
            persistCCMappings()
            onStateChanged?()
        }
    }
    var permissionStatus = "Keyboard capture not ready." { didSet { onStateChanged?() } }
    private(set) var midiMonitorEvents: [MIDIMonitorEvent] = []

    private var midiClient = MIDIClientRef()
    private var midiSource = MIDIEndpointRef()
    private var midiInputPort = MIDIPortRef()
    private var midiControlDestination = MIDIEndpointRef()
    private var connectedInputSources: [MIDIEndpointRef] = []
    private var connectedInputNames: [String] = []
    private var connectedInputRefCons: [UnsafeMutableRawPointer] = []
    private var activeNotes: [CGKeyCode: Int] = [:]
    private var activeMappedCCs: [UUID: CGKeyCode] = [:]
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
        let storedMiniViewMode = UserDefaults.standard.string(forKey: "miniViewMode").flatMap(MiniFretboardViewMode.init(rawValue:))
        miniViewMode = storedMiniViewMode ?? .fretboard
        velocity = UserDefaults.standard.object(forKey: "velocity") as? Int ?? 100
        semitoneTranspose = UserDefaults.standard.object(forKey: "transpose") as? Int ?? 0
        bendRange = UserDefaults.standard.object(forKey: "bendRange") as? Int ?? 2
        ccInputEnabled = UserDefaults.standard.object(forKey: Self.ccInputEnabledKey) as? Bool ?? true
        ccMappings = Self.loadCCMappings()
        setupMIDI()
    }

    deinit {
        releaseConnectedInputRefCons()
    }

    var activeKeyCodes: Set<CGKeyCode> {
        Set(activeNotes.keys)
    }

    var commandOptions: [KeyCommandOption] {
        var options: [KeyCommandOption] = [
            KeyCommandOption(keyCode: Key.leftArrow.rawValue, title: "Left Arrow"),
            KeyCommandOption(keyCode: Key.rightArrow.rawValue, title: "Right Arrow"),
            KeyCommandOption(keyCode: Key.downArrow.rawValue, title: "Down Arrow"),
            KeyCommandOption(keyCode: Key.upArrow.rawValue, title: "Up Arrow"),
            KeyCommandOption(keyCode: Key.i.rawValue, title: "I"),
            KeyCommandOption(keyCode: Key.space.rawValue, title: "Space / Sustain"),
            KeyCommandOption(keyCode: Key.enter.rawValue, title: "Enter / Vibrato"),
            KeyCommandOption(keyCode: Key.capsLock.rawValue, title: "Caps Lock / Hi-Lo"),
            KeyCommandOption(keyCode: Key.tab.rawValue, title: "Tab / Velocity Down"),
            KeyCommandOption(keyCode: Key.grave.rawValue, title: "` / Velocity Up")
        ]
        let existing = Set(options.map(\.keyCode))
        let rowOptions = rows
            .flatMap { $0 }
            .filter { !existing.contains($0.keyCode) }
            .map { KeyCommandOption(keyCode: $0.keyCode, title: $0.label) }
        options.append(contentsOf: rowOptions)
        return options
    }

    var modeLabel: String {
        isMidiModeActive ? "MIDI mode active" : "Keyboard pass-through"
    }

    var ccInputLabel: String {
        ccInputEnabled ? "MIDI CC input active" : "MIDI CC input off"
    }

    var midiInputSummary: String {
        guard !connectedInputNames.isEmpty else {
            return "MIDI CC sources: none connected"
        }
        return "MIDI CC sources: " + connectedInputNames.joined(separator: ", ")
    }

    var midiMonitorText: String {
        guard !midiMonitorEvents.isEmpty else {
            return "No MIDI received yet. Press a Midivana keypad button, then check here for CC messages."
        }
        return midiMonitorEvents
            .suffix(24)
            .map { event in
                let time = Self.monitorTimeFormatter.string(from: event.date)
                return "\(time)  \(event.source)  \(event.message)"
            }
            .joined(separator: "\n")
    }

    private static let monitorTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func commandTitle(for keyCode: CGKeyCode) -> String {
        commandOptions.first(where: { $0.keyCode == keyCode })?.title ?? "Key \(keyCode)"
    }

    func addCCMapping() {
        ccMappings.append(MIDIControlMapping(cc: nextAvailableMappingCC(), keyCode: Key.i.rawValue).normalized)
    }

    func resetCCMappings() {
        releaseMappedCCKeys()
        ccMappings = Self.defaultCCMappings
    }

    func refreshMIDIInputs() {
        reconnectMIDIInputs()
        onStateChanged?()
    }

    func clearMIDIMonitor() {
        midiMonitorEvents.removeAll()
        onMIDIMonitorChanged?()
    }

    func deleteCCMapping(at index: Int) {
        guard ccMappings.indices.contains(index) else { return }
        let mapping = ccMappings[index]
        if let keyCode = activeMappedCCs.removeValue(forKey: mapping.id) {
            triggerMappedKey(keyCode: keyCode, down: false)
        }
        ccMappings.remove(at: index)
    }

    func updateCCMapping(at index: Int, update: (inout MIDIControlMapping) -> Void) {
        guard ccMappings.indices.contains(index) else { return }
        var next = ccMappings[index]
        if let keyCode = activeMappedCCs.removeValue(forKey: next.id) {
            triggerMappedKey(keyCode: keyCode, down: false)
        }
        update(&next)
        ccMappings[index] = next.normalized
    }

    func noteName(for midiNote: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[midiNote % 12])\(midiNote / 12 - 1)"
    }

    func noteLetterName(for midiNote: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[midiNote % 12]
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
        if keyCode == Key.capsLock.rawValue {
            let nextState = flags.contains(.maskAlphaShift)
            if highStrings != nextState {
                highStrings = nextState
                onStateChanged?()
            }
            return true
        }
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
        activeMappedCCs.values.forEach { triggerMappedKey(keyCode: $0, down: false) }
        activeNotes.removeAll()
        activeMappedCCs.removeAll()
        sustainedNotes.removeAll()
        sustainHeld = false
        stopVibrato()
        send([0xB0, 123, 0])
        onActiveNotesChanged?()
    }

    private var tuning: [(name: String, base: Int)] {
        highStrings ? [("e", 64), ("B", 59), ("G", 55), ("D", 50)] : [("G", 55), ("D", 50), ("A", 45), ("E", 40)]
    }

    private static var defaultCCMappings: [MIDIControlMapping] {
        [
            MIDIControlMapping(cc: 80, keyCode: Key.leftArrow.rawValue),
            MIDIControlMapping(cc: 81, keyCode: Key.rightArrow.rawValue),
            MIDIControlMapping(cc: 83, keyCode: Key.downArrow.rawValue),
            MIDIControlMapping(cc: 82, keyCode: Key.upArrow.rawValue),
            MIDIControlMapping(cc: 84, keyCode: Key.i.rawValue)
        ]
    }

    private static func loadCCMappings() -> [MIDIControlMapping] {
        guard
            let data = UserDefaults.standard.data(forKey: ccMappingsKey),
            let mappings = try? JSONDecoder().decode([MIDIControlMapping].self, from: data),
            !mappings.isEmpty
        else {
            return defaultCCMappings
        }
        return mappings.map(\.normalized)
    }

    private func persistCCMappings() {
        guard let data = try? JSONEncoder().encode(ccMappings.map(\.normalized)) else { return }
        UserDefaults.standard.set(data, forKey: Self.ccMappingsKey)
    }

    private func nextAvailableMappingCC() -> Int {
        let used = Set(ccMappings.map(\.cc))
        for cc in 80...127 where !used.contains(cc) {
            return cc
        }
        for cc in 0...127 where !used.contains(cc) {
            return cc
        }
        return 80
    }

    private func releaseMappedCCKeys() {
        let active = activeMappedCCs
        activeMappedCCs.removeAll()
        for keyCode in active.values {
            triggerMappedKey(keyCode: keyCode, down: false)
        }
    }

    private func setupMIDI() {
        MIDIClientCreateWithBlock("qwerty-fretboard" as CFString, &midiClient) { [weak self] _ in
            self?.refreshMIDIInputs()
        }
        MIDISourceCreate(midiClient, "qwerty-fretboard" as CFString, &midiSource)
        MIDIInputPortCreateWithBlock(midiClient, "qwerty-fretboard CC Input" as CFString, &midiInputPort) { [weak self] packetList, sourceRefCon in
            let sourceName = sourceRefCon.map {
                Unmanaged<NSString>.fromOpaque($0).takeUnretainedValue() as String
            } ?? "MIDI input"
            self?.handleIncomingPackets(packetList, sourceName: sourceName)
        }
        MIDIDestinationCreateWithBlock(midiClient, "qwerty-fretboard control" as CFString, &midiControlDestination) { [weak self] packetList, _ in
            self?.handleIncomingPackets(packetList, sourceName: "qwerty-fretboard control")
        }
        reconnectMIDIInputs()
        sendBendSensitivity()
    }

    private func reconnectMIDIInputs() {
        guard midiInputPort != 0 else { return }
        for source in connectedInputSources {
            MIDIPortDisconnectSource(midiInputPort, source)
        }
        connectedInputSources.removeAll()
        connectedInputNames.removeAll()
        releaseConnectedInputRefCons()

        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            let name = endpointName(source, fallback: "Input \(index + 1)")
            guard source != midiSource && name != "qwerty-fretboard" else { continue }
            let refCon = Unmanaged.passRetained(name as NSString).toOpaque()
            MIDIPortConnectSource(midiInputPort, source, refCon)
            connectedInputSources.append(source)
            connectedInputNames.append(name)
            connectedInputRefCons.append(refCon)
        }
        appendMIDIMonitorEvent(
            source: "System",
            message: connectedInputNames.isEmpty ? "No MIDI input sources connected" : "Connected sources: \(connectedInputNames.joined(separator: ", "))"
        )
    }

    private func releaseConnectedInputRefCons() {
        for refCon in connectedInputRefCons {
            Unmanaged<NSString>.fromOpaque(refCon).release()
        }
        connectedInputRefCons.removeAll()
    }

    private func endpointName(_ endpoint: MIDIEndpointRef, fallback: String) -> String {
        var nameRef: Unmanaged<CFString>?
        _ = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &nameRef)
        return (nameRef?.takeRetainedValue() as String?) ?? fallback
    }

    private func handleIncomingPackets(_ packetList: UnsafePointer<MIDIPacketList>, sourceName: String) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let length = Int(packet.length)
            if length > 0 {
                let bytes = withUnsafeBytes(of: packet.data) { buffer in
                    Array(buffer.prefix(length))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    for message in Self.midiMessages(from: bytes) {
                        self.applyIncomingMIDI(message, sourceName: sourceName)
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private static func midiMessages(from bytes: [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        var index = 0
        var runningStatus: UInt8?

        while index < bytes.count {
            let byte = bytes[index]
            let status: UInt8
            if byte >= 0x80 {
                status = byte
                runningStatus = status
                index += 1
            } else if let runningStatus {
                status = runningStatus
            } else {
                index += 1
                continue
            }

            let high = status & 0xF0
            let dataCount: Int
            switch high {
            case 0xC0, 0xD0:
                dataCount = 1
            case 0x80, 0x90, 0xA0, 0xB0, 0xE0:
                dataCount = 2
            default:
                dataCount = 0
            }
            guard dataCount > 0, index + dataCount <= bytes.count else { break }
            var message = [status]
            message.append(contentsOf: bytes[index..<(index + dataCount)])
            messages.append(message)
            index += dataCount
        }

        return messages
    }

    private func applyIncomingMIDI(_ bytes: [UInt8], sourceName: String) {
        guard bytes.count >= 3, bytes[0] & 0xF0 == 0xB0 else {
            appendMIDIMonitorEvent(source: sourceName, message: "MIDI \(Self.hexString(bytes))")
            return
        }
        let channel = Int(bytes[0] & 0x0F) + 1
        let controller = Int(bytes[1])
        let value = Int(bytes[2])
        let matches = ccInputEnabled ? ccMappings.filter { $0.matches(controller: controller, incomingChannel: channel) } : []
        let matchText: String
        if !ccInputEnabled {
            matchText = "ignored, CC input off"
        } else if matches.isEmpty {
            matchText = "no mapping"
        } else {
            matchText = "maps to " + matches.map { commandTitle(for: $0.keyCode) }.joined(separator: ", ")
        }
        appendMIDIMonitorEvent(source: sourceName, message: "CC ch \(channel) #\(controller) value \(value) - \(matchText)")
        handleIncomingControlChange(controller: controller, value: value, channel: channel)
    }

    private func handleIncomingControlChange(controller: Int, value: Int, channel: Int) {
        guard ccInputEnabled else { return }
        let matches = ccMappings.filter { $0.matches(controller: controller, incomingChannel: channel) }
        guard !matches.isEmpty else { return }

        for mapping in matches {
            if value > 0 {
                guard activeMappedCCs[mapping.id] == nil else { continue }
                activeMappedCCs[mapping.id] = mapping.keyCode
                triggerMappedKey(keyCode: mapping.keyCode, down: true)
            } else if let keyCode = activeMappedCCs.removeValue(forKey: mapping.id) {
                triggerMappedKey(keyCode: keyCode, down: false)
            }
        }
    }

    private func triggerMappedKey(keyCode: CGKeyCode, down: Bool) {
        let direction = down ? "down" : "up"
        appendMIDIMonitorEvent(source: "Qwerty", message: "CC mapped \(direction) for \(commandTitle(for: keyCode)); posting keystroke")
        postKeystroke(keyCode: keyCode, down: down)
    }

    private func postKeystroke(keyCode: CGKeyCode, down: Bool) {
        guard AXIsProcessTrusted() else {
            permissionStatus = "Accessibility access is off, so MIDI CC was received but keystroke posting was blocked."
            appendMIDIMonitorEvent(source: "Keyboard", message: "Blocked \(down ? "down" : "up") for \(commandTitle(for: keyCode)); Accessibility off")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            permissionStatus = "Could not create keyboard event for MIDI CC mapping."
            appendMIDIMonitorEvent(source: "Keyboard", message: "Could not create \(down ? "down" : "up") for \(commandTitle(for: keyCode))")
            return
        }
        event.post(tap: .cghidEventTap)
        appendMIDIMonitorEvent(source: "Keyboard", message: "Posted \(down ? "down" : "up") for \(commandTitle(for: keyCode))")
    }

    private func appendMIDIMonitorEvent(source: String, message: String) {
        midiMonitorEvents.append(MIDIMonitorEvent(date: Date(), source: source, message: message))
        if midiMonitorEvents.count > 80 {
            midiMonitorEvents.removeFirst(midiMonitorEvents.count - 80)
        }
        onMIDIMonitorChanged?()
    }

    private static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
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
        var storage = [UInt8](repeating: 0, count: 1024)
        storage.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let packetListPointer = baseAddress.assumingMemoryBound(to: MIDIPacketList.self)
            var packet = MIDIPacketListInit(packetListPointer)
            packet = MIDIPacketListAdd(packetListPointer, rawBuffer.count, packet, 0, bytes.count, bytes)
            MIDIReceived(midiSource, packetListPointer)
        }
    }
}

final class SettingsWindowController: NSWindowController {
    private let engine: FretboardEngine
    private let statusLabel = NSTextField(labelWithString: "")
    private let modeButton = NSButton(title: "", target: nil, action: nil)
    private let overlayCheck = NSButton(checkboxWithTitle: "Show movable mini fretboard window", target: nil, action: nil)
    private let velocitySlider = NSSlider(value: 100, minValue: 1, maxValue: 127, target: nil, action: nil)
    private let transposeSlider = NSSlider(value: 0, minValue: -12, maxValue: 12, target: nil, action: nil)
    private let bendSlider = NSSlider(value: 2, minValue: 1, maxValue: 12, target: nil, action: nil)
    private let ccInputCheck = NSButton(checkboxWithTitle: "Receive MIDI CC from Midivana", target: nil, action: nil)
    private let ccMappingRows = NSStackView()
    private let midiMonitorView = NSTextView()
    private let valuesLabel = NSTextField(labelWithString: "")
    private let fretboardPreview: FretboardView

    init(engine: FretboardEngine) {
        self.engine = engine
        self.fretboardPreview = FretboardView(engine: engine)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let initialFrame = NSRect(
            x: screen.minX + 80,
            y: max(screen.minY + 40, screen.maxY - 800),
            width: min(760, screen.width - 120),
            height: min(760, screen.height - 80)
        )
        let window = KeyboardCaptureWindow(
            engine: engine,
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Qwerty Fretboard Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace, .managed]
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        super.init(window: window)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = NSRect(
            x: screen.minX + 80,
            y: max(screen.minY + 40, screen.maxY - window.frame.height - 60),
            width: min(window.frame.width, screen.width - 120),
            height: min(window.frame.height, screen.height - 80)
        )
        window.setFrame(frame, display: true)
        window.deminiaturize(nil)
        window.setIsVisible(true)
        window.makeMain()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.unhide(nil)
        NSApp.arrangeInFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        modeButton.title = engine.isMidiModeActive ? "Turn MIDI Mode Off" : "Turn MIDI Mode On"
        overlayCheck.state = engine.showOverlay ? .on : .off
        velocitySlider.integerValue = engine.velocity
        transposeSlider.integerValue = engine.semitoneTranspose
        bendSlider.integerValue = engine.bendRange
        ccInputCheck.state = engine.ccInputEnabled ? .on : .off
        statusLabel.stringValue = "\(engine.modeLabel)\nMIDI source: qwerty-fretboard\nMIDI CC destination: qwerty-fretboard control\n\(engine.ccInputLabel) (MIDI mode not required)\n\(engine.midiInputSummary)\n\(engine.permissionStatus)\nHotkey: Control + Option + Command + Space"
        valuesLabel.stringValue = "Velocity \(engine.velocity)   Transpose \(engine.semitoneTranspose) st   Bend \(engine.bendRange) st"
        rebuildCCMappingRows()
        refreshMIDIMonitor()
        fretboardPreview.needsDisplay = true
    }

    func refreshMIDIMonitor() {
        midiMonitorView.textColor = .systemGreen
        midiMonitorView.backgroundColor = .black
        midiMonitorView.string = engine.midiMonitorText
        midiMonitorView.scrollToEndOfDocument(nil)
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let title = NSTextField(labelWithString: "Qwerty Fretboard")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(statusLabel)

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(tabView)

        let playStack = makeSettingsStack()
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        modeButton.bezelStyle = .rounded
        playStack.addArrangedSubview(modeButton)

        overlayCheck.target = self
        overlayCheck.action = #selector(toggleOverlay)
        playStack.addArrangedSubview(overlayCheck)

        addSlider(playStack, title: "Velocity", slider: velocitySlider, action: #selector(changeVelocity))
        addSlider(playStack, title: "Transpose", slider: transposeSlider, action: #selector(changeTranspose))
        addSlider(playStack, title: "Pitch bend range", slider: bendSlider, action: #selector(changeBend))
        playStack.addArrangedSubview(valuesLabel)

        let accessActions = NSStackView()
        accessActions.orientation = .horizontal
        accessActions.spacing = 8
        let checkAccess = NSButton(title: "Check Keyboard Access", target: self, action: #selector(checkKeyboardAccess))
        checkAccess.bezelStyle = .rounded
        let requestAccess = NSButton(title: "Request Access Prompt", target: self, action: #selector(requestKeyboardAccessPrompt))
        requestAccess.bezelStyle = .rounded
        let openAccess = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))
        openAccess.bezelStyle = .rounded
        accessActions.addArrangedSubview(checkAccess)
        accessActions.addArrangedSubview(requestAccess)
        accessActions.addArrangedSubview(openAccess)
        playStack.addArrangedSubview(accessActions)

        fretboardPreview.translatesAutoresizingMaskIntoConstraints = false
        playStack.addArrangedSubview(fretboardPreview)
        fretboardPreview.heightAnchor.constraint(equalToConstant: 230).isActive = true

        let panic = NSButton(title: "Panic / All Notes Off", target: self, action: #selector(panic))
        panic.bezelStyle = .rounded
        playStack.addArrangedSubview(panic)
        addTab(to: tabView, title: "Play", view: playStack)

        let midiStack = makeSettingsStack()
        ccInputCheck.target = self
        ccInputCheck.action = #selector(toggleCCInput)
        midiStack.addArrangedSubview(ccInputCheck)

        let mappingActions = NSStackView()
        mappingActions.orientation = .horizontal
        mappingActions.spacing = 8
        let addMapping = NSButton(title: "Add CC Mapping", target: self, action: #selector(addCCMapping))
        addMapping.bezelStyle = .rounded
        let resetMappings = NSButton(title: "Reset Midivana Defaults", target: self, action: #selector(resetCCMappings))
        resetMappings.bezelStyle = .rounded
        let refreshInputs = NSButton(title: "Refresh MIDI Inputs", target: self, action: #selector(refreshMIDIInputs))
        refreshInputs.bezelStyle = .rounded
        let clearMonitor = NSButton(title: "Clear Monitor", target: self, action: #selector(clearMIDIMonitor))
        clearMonitor.bezelStyle = .rounded
        mappingActions.addArrangedSubview(addMapping)
        mappingActions.addArrangedSubview(resetMappings)
        mappingActions.addArrangedSubview(refreshInputs)
        mappingActions.addArrangedSubview(clearMonitor)
        midiStack.addArrangedSubview(mappingActions)

        ccMappingRows.orientation = .vertical
        ccMappingRows.alignment = .width
        ccMappingRows.spacing = 6
        midiStack.addArrangedSubview(ccMappingRows)

        let monitorLabel = NSTextField(labelWithString: "MIDI Monitor")
        monitorLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        midiStack.addArrangedSubview(monitorLabel)

        midiMonitorView.isEditable = false
        midiMonitorView.isSelectable = true
        midiMonitorView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        midiMonitorView.textColor = .systemGreen
        midiMonitorView.backgroundColor = .black
        midiMonitorView.textContainerInset = NSSize(width: 8, height: 6)

        let monitorScroll = NSScrollView()
        monitorScroll.hasVerticalScroller = true
        monitorScroll.borderType = .bezelBorder
        monitorScroll.documentView = midiMonitorView
        monitorScroll.translatesAutoresizingMaskIntoConstraints = false
        midiStack.addArrangedSubview(monitorScroll)
        monitorScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        addTab(to: tabView, title: "MIDI CC", view: midiStack)

        let helpStack = makeSettingsStack()
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
        helpStack.addArrangedSubview(help)

        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        helpStack.addArrangedSubview(quit)
        addTab(to: tabView, title: "Help", view: helpStack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            tabView.heightAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])
    }

    private func makeSettingsStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func addTab(to tabView: NSTabView, title: String, view: NSView) {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        tabView.addTabViewItem(item)
    }

    private func addSlider(_ stack: NSStackView, title: String, slider: NSSlider, action: Selector) {
        let label = NSTextField(labelWithString: title)
        slider.target = self
        slider.action = action
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(slider)
    }

    private func rebuildCCMappingRows() {
        for view in ccMappingRows.arrangedSubviews {
            ccMappingRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, mapping) in engine.ccMappings.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 7

            let enabled = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCCMapping(_:)))
            enabled.tag = index
            enabled.state = mapping.enabled ? .on : .off
            enabled.toolTip = "Enable mapping"
            row.addArrangedSubview(enabled)

            let ccLabel = NSTextField(labelWithString: "CC \(mapping.cc)")
            ccLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            ccLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
            row.addArrangedSubview(ccLabel)

            let ccStepper = NSStepper()
            ccStepper.minValue = 0
            ccStepper.maxValue = 127
            ccStepper.integerValue = mapping.cc
            ccStepper.target = self
            ccStepper.action = #selector(changeCCMappingController(_:))
            ccStepper.tag = index
            row.addArrangedSubview(ccStepper)

            let channelLabel = NSTextField(labelWithString: mapping.channel == 0 ? "Any" : "Ch \(mapping.channel)")
            channelLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            channelLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
            row.addArrangedSubview(channelLabel)

            let channelStepper = NSStepper()
            channelStepper.minValue = 0
            channelStepper.maxValue = 16
            channelStepper.integerValue = mapping.channel
            channelStepper.target = self
            channelStepper.action = #selector(changeCCMappingChannel(_:))
            channelStepper.tag = index
            row.addArrangedSubview(channelStepper)

            let commandPopup = NSPopUpButton()
            commandPopup.target = self
            commandPopup.action = #selector(changeCCMappingCommand(_:))
            commandPopup.tag = index
            for option in engine.commandOptions {
                commandPopup.addItem(withTitle: option.title)
                commandPopup.lastItem?.representedObject = Int(option.keyCode)
            }
            if let selectedIndex = engine.commandOptions.firstIndex(where: { $0.keyCode == mapping.keyCode }) {
                commandPopup.selectItem(at: selectedIndex)
            }
            commandPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            row.addArrangedSubview(commandPopup)

            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteCCMapping(_:)))
            delete.bezelStyle = .rounded
            delete.tag = index
            row.addArrangedSubview(delete)

            ccMappingRows.addArrangedSubview(row)
        }
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

    @objc private func checkKeyboardAccess() {
        (NSApp.delegate as? AppDelegate)?.installEventTap()
    }

    @objc private func requestKeyboardAccessPrompt() {
        (NSApp.delegate as? AppDelegate)?.requestAccessibilityPrompt()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleCCInput() {
        engine.ccInputEnabled = ccInputCheck.state == .on
    }

    @objc private func addCCMapping() {
        engine.addCCMapping()
    }

    @objc private func resetCCMappings() {
        engine.resetCCMappings()
    }

    @objc private func refreshMIDIInputs() {
        engine.refreshMIDIInputs()
    }

    @objc private func clearMIDIMonitor() {
        engine.clearMIDIMonitor()
    }

    @objc private func toggleCCMapping(_ sender: NSButton) {
        engine.updateCCMapping(at: sender.tag) { mapping in
            mapping.enabled = sender.state == .on
        }
    }

    @objc private func changeCCMappingController(_ sender: NSStepper) {
        engine.updateCCMapping(at: sender.tag) { mapping in
            mapping.cc = sender.integerValue
        }
    }

    @objc private func changeCCMappingChannel(_ sender: NSStepper) {
        engine.updateCCMapping(at: sender.tag) { mapping in
            mapping.channel = sender.integerValue
        }
    }

    @objc private func changeCCMappingCommand(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? Int else { return }
        engine.updateCCMapping(at: sender.tag) { mapping in
            mapping.keyCode = CGKeyCode(rawValue)
        }
    }

    @objc private func deleteCCMapping(_ sender: NSButton) {
        engine.deleteCCMapping(at: sender.tag)
    }

    @objc private func panic() {
        engine.panic()
    }
}

final class KeyboardCaptureWindow: NSWindow {
    private let engine: FretboardEngine

    init(engine: FretboardEngine, contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        self.engine = engine
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    override func sendEvent(_ event: NSEvent) {
        guard engine.isMidiModeActive else {
            super.sendEvent(event)
            return
        }

        let handled: Bool
        switch event.type {
        case .keyDown:
            handled = engine.handleKeyDown(keyCode: CGKeyCode(event.keyCode), repeatEvent: event.isARepeat)
        case .keyUp:
            handled = engine.handleKeyUp(keyCode: CGKeyCode(event.keyCode))
        case .flagsChanged:
            handled = engine.handleFlagsChanged(keyCode: CGKeyCode(event.keyCode), flags: event.modifierFlags.cgEventFlags)
        default:
            handled = false
        }

        if !handled {
            super.sendEvent(event)
        }
    }
}

private extension NSEvent.ModifierFlags {
    var cgEventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.capsLock) { flags.insert(.maskAlphaShift) }
        return flags
    }
}

final class FretboardOverlayWindow: NSWindow {
    private let overlayView: FretboardOverlayContentView

    init(engine: FretboardEngine) {
        overlayView = FretboardOverlayContentView(engine: engine)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        super.init(
            contentRect: NSRect(x: screenFrame.midX - 320, y: screenFrame.minY + 70, width: 640, height: 240),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Qwerty Fretboard Mini"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 320, height: 136)
        contentMinSize = minSize
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrameAutosaveName("QwertyFretboardMiniWindow")
        contentView = overlayView
    }

    override func sendEvent(_ event: NSEvent) {
        if !overlayView.handleWindowEvent(event) {
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    func show() {
        refresh()
        makeKeyAndOrderFront(nil)
    }

    func refresh() {
        overlayView.refresh()
    }
}

final class FretboardOverlayContentView: NSView {
    private let engine: FretboardEngine
    private let listenButton = NSButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "Mini Fretboard")
    private let statusLabel = NSTextField(labelWithString: "")
    private let settingsButton = NSButton(title: "", target: nil, action: nil)
    private let hideButton = NSButton(title: "", target: nil, action: nil)
    private let fretboardView: FretboardView

    init(engine: FretboardEngine) {
        self.engine = engine
        self.fretboardView = FretboardView(engine: engine, showsFooter: false)
        super.init(frame: .zero)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        let color = engine.isMidiModeActive ? NSColor.systemRed : NSColor.white
        listenButton.image = NSImage(systemSymbolName: engine.isMidiModeActive ? "record.circle.fill" : "record.circle", accessibilityDescription: "Toggle MIDI mode")
        listenButton.title = ""
        listenButton.contentTintColor = color
        titleLabel.stringValue = engine.miniViewMode.title
        statusLabel.stringValue = engine.isMidiModeActive ? "MIDI On" : "Pass-through"
        statusLabel.textColor = engine.isMidiModeActive ? .systemRed : NSColor.white.withAlphaComponent(0.72)
        fretboardView.needsDisplay = true
        needsDisplay = true
    }

    func handleWindowEvent(_ event: NSEvent) -> Bool {
        guard engine.isMidiModeActive else { return false }
        switch event.type {
        case .keyDown:
            return engine.handleKeyDown(keyCode: CGKeyCode(event.keyCode), repeatEvent: event.isARepeat)
        case .keyUp:
            return engine.handleKeyUp(keyCode: CGKeyCode(event.keyCode))
        case .flagsChanged:
            return engine.handleFlagsChanged(keyCode: CGKeyCode(event.keyCode), flags: event.modifierFlags.cgEventFlags)
        default:
            return false
        }
    }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        stack.addArrangedSubview(header)

        listenButton.target = self
        listenButton.action = #selector(toggleListening)
        listenButton.bezelStyle = .texturedRounded
        listenButton.controlSize = .small
        listenButton.toolTip = "Toggle MIDI mode"
        header.addArrangedSubview(listenButton)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(titleLabel)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        header.addArrangedSubview(statusLabel)

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Mini view options")
        settingsButton.target = self
        settingsButton.action = #selector(showMiniSettingsMenu(_:))
        settingsButton.bezelStyle = .texturedRounded
        settingsButton.controlSize = .small
        settingsButton.toolTip = "Mini view options"
        header.addArrangedSubview(settingsButton)

        hideButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide mini fretboard")
        hideButton.target = self
        hideButton.action = #selector(hideOverlay)
        hideButton.bezelStyle = .texturedRounded
        hideButton.controlSize = .small
        hideButton.toolTip = "Hide mini fretboard"
        header.addArrangedSubview(hideButton)

        fretboardView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(fretboardView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            listenButton.widthAnchor.constraint(equalToConstant: 34),
            listenButton.heightAnchor.constraint(equalToConstant: 26),
            settingsButton.widthAnchor.constraint(equalToConstant: 28),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),
            hideButton.widthAnchor.constraint(equalToConstant: 28),
            hideButton.heightAnchor.constraint(equalToConstant: 26),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
            fretboardView.heightAnchor.constraint(greaterThanOrEqualToConstant: 82)
        ])
    }

    @objc private func toggleListening() {
        engine.toggleMidiMode()
        refresh()
        window?.makeKey()
    }

    @objc private func showMiniSettingsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for mode in MiniFretboardViewMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(changeMiniViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = engine.miniViewMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide Mini Window", action: #selector(hideOverlay), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 2), in: sender)
    }

    @objc private func changeMiniViewMode(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let mode = MiniFretboardViewMode(rawValue: rawValue)
        else { return }

        engine.miniViewMode = mode
        refresh()
    }

    @objc private func hideOverlay() {
        engine.showOverlay = false
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        let chromeRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let chromePath = NSBezierPath(roundedRect: chromeRect, xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.055, alpha: 0.97).setFill()
        chromePath.fill()

        NSColor.white.withAlphaComponent(0.22).setStroke()
        chromePath.lineWidth = 1
        chromePath.stroke()

        NSColor.white.withAlphaComponent(0.10).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 10, y: bounds.maxY - 44))
        separator.line(to: NSPoint(x: bounds.maxX - 10, y: bounds.maxY - 44))
        separator.lineWidth = 1
        separator.stroke()

        drawResizeGrip()
    }

    private func drawResizeGrip() {
        let color = NSColor.white.withAlphaComponent(0.22)
        color.setStroke()
        for offset in [0, 5, 10] as [CGFloat] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.maxX - 18 + offset, y: bounds.minY + 7))
            path.line(to: NSPoint(x: bounds.maxX - 7, y: bounds.minY + 18 - offset))
            path.lineWidth = 1
            path.stroke()
        }
    }
}

final class FretboardView: NSView {
    private let engine: FretboardEngine
    private let showsFooter: Bool

    init(engine: FretboardEngine, showsFooter: Bool = true) {
        self.engine = engine
        self.showsFooter = showsFooter
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.04, alpha: 0.86).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: showsFooter ? 14 : 9, yRadius: showsFooter ? 14 : 9).fill()

        let miniMode = showsFooter ? MiniFretboardViewMode.fretboard : engine.miniViewMode
        let compact = !showsFooter || bounds.width < 540 || bounds.height < 210
        let tiny = bounds.width < 430 || bounds.height < 155
        if miniMode == .slantedKeyboard {
            drawSlantedKeyboard(compact: compact, tiny: tiny)
            return
        }

        let noteNamesPrimary = miniMode == .noteNames
        let margin: CGFloat = tiny ? 7 : (compact ? 10 : 18)
        let labelWidth: CGFloat = tiny || noteNamesPrimary ? 0 : (compact ? 34 : 52)
        let bottomBarHeight: CGFloat = showsFooter ? (compact ? 28 : 34) : 0
        let gap: CGFloat = tiny ? 3 : (compact ? 4 : 8)
        let availableHeight = max(tiny ? 44 : 80, bounds.height - margin * 2 - bottomBarHeight - (showsFooter ? 0 : 2))
        let rowHeight: CGFloat = min(compact ? 30 : 38, max(tiny ? 13 : 20, (availableHeight - 3 * gap) / 4))
        let fretCount = 11
        let cellWidth = max(8, (bounds.width - margin * 2 - labelWidth - CGFloat(fretCount - 1) * gap) / CGFloat(fretCount))
        let startY = bounds.height - margin - rowHeight
        let showRowLabels = !noteNamesPrimary && labelWidth >= 20
        let showNoteNames = rowHeight >= 24 && cellWidth >= 24
        let keyFontSize: CGFloat = tiny ? 9 : (compact ? 10.5 : 12)
        let noteFontSize: CGFloat = compact ? 8.5 : 10
        let cornerRadius = min(compact ? 6 : 7, max(3, min(cellWidth, rowHeight) * 0.24))

        let active = engine.activeKeyCodes
        for (rowIndex, row) in engine.rows.enumerated() {
            let y = startY - CGFloat(rowIndex) * (rowHeight + gap)
            if showRowLabels {
                drawText(
                    engine.rowName(rowIndex),
                    in: NSRect(x: margin, y: y + max(0, (rowHeight - 15) / 2), width: max(1, labelWidth - 7), height: 15),
                    color: .white,
                    size: compact ? 10.5 : 13,
                    alignment: .right,
                    minSize: 7.5
                )
            }
            for key in row {
                let x = margin + labelWidth + CGFloat(key.fret) * (cellWidth + gap)
                let rect = NSRect(x: x, y: y, width: cellWidth, height: rowHeight)
                let isActive = active.contains(key.keyCode)
                let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
                (isActive ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)).setFill()
                path.fill()
                NSColor(calibratedWhite: isActive ? 1 : 0.22, alpha: 1).setStroke()
                path.lineWidth = 1
                path.stroke()

                if noteNamesPrimary {
                    let note = engine.noteLetterName(for: engine.midiNote(for: key))
                    drawText(
                        note,
                        in: NSRect(x: rect.minX + 2, y: rect.minY + max(0, (rowHeight - 19) / 2), width: rect.width - 4, height: 19),
                        color: isActive ? .black : .white,
                        size: tiny ? 10 : (compact ? 13 : 16),
                        alignment: .center,
                        minSize: 7
                    )
                    if showNoteNames {
                        drawText(
                            key.label,
                            in: NSRect(x: rect.minX + 2, y: rect.minY + 3, width: rect.width - 4, height: 10),
                            color: isActive ? .darkGray : NSColor.white.withAlphaComponent(0.48),
                            size: compact ? 7.5 : 8.5,
                            alignment: .center,
                            minSize: 6
                        )
                    }
                } else if showNoteNames {
                    let note = engine.noteName(for: engine.midiNote(for: key))
                    drawText(
                        key.label,
                        in: NSRect(x: rect.minX + 2, y: rect.minY + rowHeight - 17, width: rect.width - 4, height: 14),
                        color: isActive ? .black : .white,
                        size: keyFontSize,
                        alignment: .center,
                        minSize: 7
                    )
                    drawText(
                        note,
                        in: NSRect(x: rect.minX + 2, y: rect.minY + 5, width: rect.width - 4, height: 12),
                        color: isActive ? .darkGray : .lightGray,
                        size: noteFontSize,
                        alignment: .center,
                        minSize: 6.5
                    )
                } else {
                    drawText(
                        key.label,
                        in: NSRect(x: rect.minX + 1, y: rect.minY + max(0, (rowHeight - 13) / 2), width: rect.width - 2, height: 13),
                        color: isActive ? .black : .white,
                        size: keyFontSize,
                        alignment: .center,
                        minSize: 6.5
                    )
                }
            }
        }

        if showsFooter {
            let barRect = NSRect(x: margin, y: margin, width: bounds.width - margin * 2, height: bottomBarHeight)
            NSColor(calibratedWhite: 0.10, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 8, yRadius: 8).fill()
            KeyboardIcon.draw(in: NSRect(x: barRect.minX + 10, y: barRect.minY + 8, width: 24, height: 18), active: true, template: false)
            drawText(
                engine.isMidiModeActive ? "qwerty-fretboard MIDI  •  listening" : "qwerty-fretboard MIDI  •  press Listen to capture keys",
                in: NSRect(x: barRect.minX + 42, y: barRect.minY + max(5, (barRect.height - 18) / 2), width: barRect.width - 52, height: 18),
                color: .white,
                size: compact ? 10 : 11,
                alignment: .left,
                minSize: 8
            )
        }
    }

    private func drawSlantedKeyboard(compact: Bool, tiny: Bool) {
        let margin: CGFloat = tiny ? 8 : (compact ? 10 : 14)
        let gap: CGFloat = tiny ? 3 : (compact ? 4 : 6)
        let rowOffsets: [CGFloat] = [0, 0.45, 0.78, 1.18]
        let fretCount = 11
        let availableWidth = max(1, bounds.width - margin * 2)
        let availableHeight = max(1, bounds.height - margin * 2)
        let rowHeight = min(compact ? 31 : 38, max(tiny ? 14 : 20, (availableHeight - 3 * gap) / 4))
        let maxOffset = rowOffsets.max() ?? 0
        let cellWidth = max(8, (availableWidth - CGFloat(fretCount - 1) * gap) / (CGFloat(fretCount) + maxOffset))
        let totalHeight = rowHeight * 4 + gap * 3
        let startY = bounds.midY + totalHeight / 2 - rowHeight
        let active = engine.activeKeyCodes
        let showNoteNames = rowHeight >= 24 && cellWidth >= 24

        for (rowIndex, row) in engine.rows.enumerated() {
            let y = startY - CGFloat(rowIndex) * (rowHeight + gap)
            let rowOffset = rowOffsets[min(rowIndex, rowOffsets.count - 1)] * cellWidth
            for key in row {
                let x = margin + rowOffset + CGFloat(key.fret) * (cellWidth + gap)
                let rect = NSRect(x: x, y: y, width: cellWidth, height: rowHeight)
                let isActive = active.contains(key.keyCode)
                let path = NSBezierPath(roundedRect: rect, xRadius: min(7, rowHeight * 0.24), yRadius: min(7, rowHeight * 0.24))
                (isActive ? NSColor.white : NSColor(calibratedWhite: 0.13, alpha: 1)).setFill()
                path.fill()
                NSColor(calibratedWhite: isActive ? 1 : 0.25, alpha: 1).setStroke()
                path.lineWidth = 1
                path.stroke()

                if showNoteNames {
                    let note = engine.noteLetterName(for: engine.midiNote(for: key))
                    drawText(
                        key.label,
                        in: NSRect(x: rect.minX + 2, y: rect.minY + rowHeight - 17, width: rect.width - 4, height: 14),
                        color: isActive ? .black : .white,
                        size: tiny ? 8.5 : 10.5,
                        alignment: .center,
                        minSize: 6.5
                    )
                    drawText(
                        note,
                        in: NSRect(x: rect.minX + 2, y: rect.minY + 5, width: rect.width - 4, height: 12),
                        color: isActive ? .darkGray : NSColor.white.withAlphaComponent(0.55),
                        size: tiny ? 7 : 8.5,
                        alignment: .center,
                        minSize: 6
                    )
                } else {
                    drawText(
                        key.label,
                        in: NSRect(x: rect.minX + 1, y: rect.minY + max(0, (rowHeight - 13) / 2), width: rect.width - 2, height: 13),
                        color: isActive ? .black : .white,
                        size: tiny ? 8.5 : 10,
                        alignment: .center,
                        minSize: 6.5
                    )
                }
            }
        }
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, size: CGFloat, alignment: NSTextAlignment, minSize: CGFloat = 8) {
        guard rect.width > 1, rect.height > 1 else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let nsText = text as NSString
        var fontSize = size
        while fontSize > minSize {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let measuredWidth = nsText.size(withAttributes: [.font: font]).width
            if measuredWidth <= rect.width + 0.5 { break }
            fontSize -= 0.5
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: max(minSize, fontSize), weight: .medium),
            .paragraphStyle: style
        ]
        nsText.draw(in: rect, withAttributes: attrs)
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
