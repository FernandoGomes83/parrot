import AppKit
import ParrotTranslation

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let inputItem: NSMenuItem
    private let modelItem: NSMenuItem
    private let translationItem: NSMenuItem
    private let translation: TranslationCoordinator
    private var model: TranscriptionModel
    private var hotkey: HotkeyMonitor.Hotkey
    private let devices: InputDeviceStore
    private let onHotkeyChanged: (HotkeyMonitor.Hotkey) -> Void
    /// Set by the daemon right after init — the handler needs the controller
    /// itself to report the outcome, so it can't be passed in.
    var onModelChanged: ((TranscriptionModel) -> Void)?
    var onOverlayStyleChanged: ((OverlayStyle) -> Void)?

    init(
        model: TranscriptionModel,
        hotkey: HotkeyMonitor.Hotkey,
        devices: InputDeviceStore,
        translation: TranslationCoordinator,
        onHotkeyChanged: @escaping (HotkeyMonitor.Hotkey) -> Void
    ) {
        self.model = model
        self.hotkey = hotkey
        self.devices = devices
        self.translation = translation
        self.onHotkeyChanged = onHotkeyChanged
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(
            title: "idle · hold \(hotkey.displayName) to dictate",
            action: nil,
            keyEquivalent: ""
        )
        stateLabel.isEnabled = false

        modelLabel = NSMenuItem(title: "model: \(model.id)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false

        inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        let inputMenu = NSMenu()
        inputMenu.autoenablesItems = false
        inputItem.submenu = inputMenu

        modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        modelMenu.autoenablesItems = false
        modelItem.submenu = modelMenu

        translationItem = NSMenuItem(title: "Translation", action: nil, keyEquivalent: "")

        // All stored properties are set; NSObject init must precede the menu
        // items below, which take self as their target.
        super.init()

        for candidate in ModelRegistry.shared {
            let item = NSMenuItem(
                title: candidate.displayName,
                action: #selector(modelClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate.id
            item.state = candidate.id == model.id ? .on : .off
            modelMenu.addItem(item)
        }

        menu.addItem(stateLabel)
        menu.addItem(modelLabel)
        menu.addItem(modelItem)
        menu.addItem(inputItem)
        menu.addItem(translationItem)
        rebuildTranslationMenu()
        translation.onChange = { [weak self] in self?.rebuildTranslationMenu() }

        menu.addItem(.separator())

        let hotkeyMenu = NSMenu()
        for candidate in HotkeyMonitor.Hotkey.allCases {
            let item = NSMenuItem(
                title: candidate.displayName,
                action: #selector(hotkeyClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = candidate == hotkey ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Push-to-talk key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        let indicatorMenu = NSMenu()
        let selectedStyle = OverlayPreferences.selected
        for style in OverlayStyle.allCases {
            let item = NSMenuItem(
                title: style.displayName,
                action: #selector(overlayStyleClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == selectedStyle ? .on : .off
            indicatorMenu.addItem(item)
        }
        let indicatorItem = NSMenuItem(title: "Recording indicator", action: nil, keyEquivalent: "")
        indicatorItem.submenu = indicatorMenu
        menu.addItem(indicatorItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        // Rebuild the device list on open so plugging a mic in is reflected
        // without watching CoreAudio for device changes.
        menu.delegate = self

        statusItem.menu = menu
        configureButton(recording: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let submenu = inputItem.submenu else { return }
        submenu.removeAllItems()

        let selected = devices.selectedUID
        submenu.addItem(inputChoice(title: "Same as System", uid: nil, checked: selected == nil))
        submenu.addItem(.separator())
        for device in devices.available() {
            submenu.addItem(inputChoice(title: device.name, uid: device.uid, checked: device.uid == selected))
        }
    }

    private func inputChoice(title: String, uid: String?, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(inputSelected), keyEquivalent: "")
        item.target = self
        item.representedObject = uid
        item.state = checked ? .on : .off
        return item
    }

    /// Only writes the preference — the next recording resolves it, so there is
    /// nothing to notify.
    @objc private func inputSelected(_ sender: NSMenuItem) {
        devices.selectedUID = sender.representedObject as? String
    }

    func setTranslating(to language: TranslationLanguage) {
        stateLabel.title = "translating → \(language.displayName)…"
    }

    func setTranslationFailed() {
        stateLabel.title = "Translation failed · original in Translation menu"
        statusItem.button?.title = "!"
        statusItem.button?.toolTip = stateLabel.title
    }

    func setRecording(_ recording: Bool) {
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Parrot"
        stateLabel.title = recording
            ? "● recording"
            : "idle · hold \(hotkey.displayName) to dictate"
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func overlayStyleClicked(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let style = OverlayStyle(rawValue: rawValue)
        else { return }

        OverlayPreferences.selected = style
        onOverlayStyleChanged?(style)
        for item in sender.menu?.items ?? [] {
            item.state = item === sender ? .on : .off
        }
    }

    @objc private func hotkeyClicked(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let selected = HotkeyMonitor.Hotkey(rawValue: rawValue)
        else { return }

        hotkey = selected
        HotkeyPreferences.selected = selected
        onHotkeyChanged(selected)
        stateLabel.title = "idle · hold \(selected.displayName) to dictate"

        for item in sender.menu?.items ?? [] {
            item.state = item === sender ? .on : .off
        }
    }

    private func rebuildTranslationMenu() {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let enabled = translation.preferences.enabled
        let toggle = NSMenuItem(title: enabled ? "Disable translation" : "Enable translation",
                                action: #selector(translationToggled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? (translation.state == .ready ? .on : .mixed) : .off
        submenu.addItem(toggle)

        let status: String
        switch translation.state {
        case .off: status = "Local translation · off"
        case .preparing(let percent):
            status = percent == 100 ? "Loading translator…" : "Preparing translator · \(percent)%"
        case .ready: status = "Local translation · ready"
        case .failed: status = "Setup failed · enable to retry"
        }
        let statusRow = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        statusRow.toolTip = translation.setupFailure
        submenu.addItem(statusRow)
        let modelRow = NSMenuItem(title: "TranslateGemma 4B · download ~2.2 GB", action: nil, keyEquivalent: "")
        modelRow.isEnabled = false
        submenu.addItem(modelRow)
        submenu.addItem(.separator())

        for isSource in [true, false] {
            let selected = isSource ? translation.preferences.source : translation.preferences.target
            let title = "\(isSource ? "From" : "To"): \(selected.displayName)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for language in TranslationLanguage.allCases {
                let choice = NSMenuItem(title: language.displayName,
                    action: isSource ? #selector(translationSourceSelected(_:)) : #selector(translationTargetSelected(_:)),
                    keyEquivalent: "")
                choice.target = self
                choice.representedObject = language.rawValue
                choice.state = selected == language ? .on : .off
                choices.addItem(choice)
            }
            item.submenu = choices
            submenu.addItem(item)
        }
        if translation.failedOriginal != nil {
            submenu.addItem(.separator())
            let error = NSMenuItem(title: "Translation failed", action: nil, keyEquivalent: "")
            error.isEnabled = false
            error.toolTip = translation.failureDescription
            submenu.addItem(error)
            let copy = NSMenuItem(title: "Copy original dictation", action: #selector(copyOriginalDictation), keyEquivalent: "")
            copy.target = self
            submenu.addItem(copy)
        }
        translationItem.submenu = submenu
    }

    @objc private func translationToggled() { translation.toggle() }

    @objc private func translationSourceSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = TranslationLanguage(rawValue: raw) else { return }
        translation.setSource(language)
    }

    @objc private func translationTargetSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = TranslationLanguage(rawValue: raw) else { return }
        translation.setTarget(language)
    }

    @objc private func copyOriginalDictation() {
        guard let text = translation.takeOriginal() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setRecording(false)
    }

    /// Loading a model can mean downloading hundreds of megabytes, so the swap
    /// is optimistic in the menu only: the daemon keeps dictating with the old
    /// model until `modelSwitchSucceeded` (or `modelSwitchFailed`) comes back.
    @objc private func modelClicked(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let selected = ModelRegistry.find(id),
            selected.id != model.id
        else { return }

        checkModel(id: selected.id)
        stateLabel.title = "loading \(selected.id)…"
        onModelChanged?(selected)
    }

    func modelSwitchSucceeded(_ newModel: TranscriptionModel) {
        model = newModel
        modelLabel.title = "model: \(newModel.id)"
        checkModel(id: newModel.id)
        setRecording(false)
    }

    func modelSwitchFailed() {
        checkModel(id: model.id)
        setRecording(false)
    }

    private func checkModel(id: String) {
        for item in modelItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
    }
}
