import SwiftUI
import UniformTypeIdentifiers
import RegexBuilder
import Sparkle
import AVFoundation
import Combine
import QuartzCore
import HUDKit

// Sound Manager class to handle all sound effects
class SoundManager {
    static let shared = SoundManager()
    
    private var portalOpenPlayer: AVAudioPlayer?
    private var portalClosePlayer: AVAudioPlayer?
    private var portalAmbientPlayer: AVAudioPlayer?
    private var hoverPlayer: AVAudioPlayer?
    private var hoverOutPlayer: AVAudioPlayer?
    private var sendPlayer: AVAudioPlayer?
    private var receivePlayer: AVAudioPlayer?
    
    private let queue = DispatchQueue(label: "com.wormhole.audio")
    private var lastHoverTime: TimeInterval = 0
    private let hoverThreshold: TimeInterval = 0.1
    
    private init() {
        loadSoundEffects()
    }
    
    private func loadSoundEffects() {
        queue.sync {
            loadSound(named: "send", into: &portalOpenPlayer)
            loadSound(named: "send-reverse", into: &portalClosePlayer)
            loadSound(named: "portal_ambient", into: &portalAmbientPlayer)
            loadSound(named: "hover-in", into: &hoverPlayer)
            loadSound(named: "hover-out", into: &hoverOutPlayer)
            
            loadSound(named: "send-reverse", into: &sendPlayer)
            loadSound(named: "receive", into: &receivePlayer)
            
            // Configure the ambient sound for looping
            portalAmbientPlayer?.numberOfLoops = -1 // -1 means infinite looping
            portalAmbientPlayer?.volume = 0.3 // Lower volume for ambient sound
            
            // Pre-prepare all players to avoid first-play issues
            [portalOpenPlayer, portalClosePlayer, hoverPlayer, hoverOutPlayer, sendPlayer, receivePlayer].forEach { player in
                player?.prepareToPlay()
                player?.volume = 0.7
            }
        }
    }
    
    private func loadSound(named name: String, into player: inout AVAudioPlayer?) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            print("Could not find sound file: \(name)")
            return
        }
        
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            print("Could not create audio player for \(name): \(error)")
        }
    }
    
    private func safePlay(_ player: AVAudioPlayer?) {
        queue.async {
            guard let player = player else { return }
            if player.isPlaying {
                player.stop()
            }
            player.currentTime = 0
            player.play()
        }
    }
    
    func playPortalOpen() {
        queue.async {
            self.portalOpenPlayer?.currentTime = 0
            self.portalOpenPlayer?.play()
            
            // Start the ambient loop with a slight delay after the opening sound
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.playAmbientSound()
            }
        }
    }
    
    func playPortalClose() {
        queue.async {
            self.stopAmbientSound()
            self.portalClosePlayer?.currentTime = 0
            self.portalClosePlayer?.play()
        }
    }
    
    func playAmbientSound() {
        // Ambient sound disabled - uncomment to enable looping portal sound
        // queue.async {
        //     guard let player = self.portalAmbientPlayer, !player.isPlaying else { return }
        //     player.currentTime = 0
        //     player.play()
        // }
    }
    
    func stopAmbientSound() {
        queue.async {
            self.portalAmbientPlayer?.stop()
            self.portalAmbientPlayer?.currentTime = 0
        }
    }
    
    func stopPortalSounds() {
        queue.async {
            [self.portalOpenPlayer, self.portalClosePlayer, self.portalAmbientPlayer].forEach { player in
                player?.stop()
                player?.currentTime = 0
            }
        }
    }
    
    func playHover(pitchUp: Bool = false) {
        // Throttle hover sounds to prevent overload
        let now = Date().timeIntervalSince1970
        guard now - lastHoverTime >= hoverThreshold else { return }
        lastHoverTime = now
        
        queue.async {
            if pitchUp {
                self.safePlay(self.hoverPlayer)
            } else {
                self.safePlay(self.hoverOutPlayer)
            }
        }
    }
    
    func playSend() {
        queue.async {
            self.stopPortalSounds()
            self.safePlay(self.sendPlayer)
        }
    }
    
    func playReceive() {
        safePlay(receivePlayer)
    }
}

private let portalWindowSize = NSSize(width: 320, height: 240)

@main
struct WormholeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // EmptyView is 0×0; on some macOS versions NSHostingView then computes
        // a NaN frame and aborts in `_nsis_frameInEngine`. Give the required
        // Settings scene a real size and never restore it.
        Settings {
            Color.clear.frame(width: 1, height: 1)
        }
        .environmentObject(appDelegate)
    }
}

// MARK: - Portal model
//
// Portals are data, not hardcoded modes. The built-in Wormhole portal is always
// present; everything else is a "command portal" — a shell command with the
// dropped file path substituted in — defined in portals.json, via the in-app
// settings editor, or with the `portal` CLI.

extension PortalDefinition {
    var tint: Color { Color(hex: tintHex) ?? .purple }
    var glow: Color { Color(hex: glowHex) ?? tint }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue: Double(v & 0xFF) / 255.0
        )
    }

    /// `#RRGGBB` in the sRGB space. Used to persist ColorPicker selections.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// Add this before the AppDelegate class
enum TransferState {
    case idle
    case pending
    case transferring
    case success
    case failed
}

// Add this before the AppDelegate class
enum ProcessState: Equatable {
    case notStarted
    case starting
    case running
    case completing
    case completed
    case failed(String)
    
    var description: String {
        switch self {
        case .notStarted: return "not started"
        case .starting: return "starting"
        case .running: return "running"
        case .completing: return "completing"
        case .completed: return "completed"
        case .failed(let error): return "failed: \(error)"
        }
    }
    
    static func == (lhs: ProcessState, rhs: ProcessState) -> Bool {
        switch (lhs, rhs) {
        case (.notStarted, .notStarted),
             (.starting, .starting),
             (.running, .running),
             (.completing, .completing),
             (.completed, .completed):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

// Add this before the AppDelegate class
enum DependencyState: Equatable {
    case notChecked
    case checking
    case ready
    case needsHomebrew
    case needsMagicWormhole
    case installing
    case error(String)
    
    static func == (lhs: DependencyState, rhs: DependencyState) -> Bool {
        switch (lhs, rhs) {
        case (.notChecked, .notChecked),
             (.checking, .checking),
             (.ready, .ready),
             (.needsHomebrew, .needsHomebrew),
             (.needsMagicWormhole, .needsMagicWormhole),
             (.installing, .installing):
            return true
        case (.error(let lhsError), .error(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

// Add this class to handle Sparkle's updater
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate: UpdaterDelegate?
    
    @Published var canCheckForUpdates = false
    
    init() {
        updaterDelegate = UpdaterDelegate()
        // If you want to start updates automatically:
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
        
        // Publish whether updates can be checked or not
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
    }
    
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("Found update: \(item.displayVersionString)")
    }
    
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            print("No update found. Current version: \(currentVersion)")
        }
    }
    
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        for item in appcast.items {
            print(item)
        }
    }
    
    // Add this method to enable gentle reminders
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        return Set(["stable"])
    }
}

// Add this before AppDelegate class
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var progress: Double = 0
    @Published var wormholeCode: String?
    @Published var fileName: String?
    @Published var fileSize: String?
    @Published var errorMessage: String?
    @Published var transferState: TransferState = .idle
    @Published var dependencyState: DependencyState = .notChecked
    @Published var installationProgress: String = ""
    @Published var isFirstLaunch = true
    /// The portal library and its sets, mirrored from portals.json. Every change made
    /// in-app is saved; changes loaded from disk are not written back.
    @Published var library = PortalLibrary(portals: [.wormhole]) {
        didSet {
            guard library != oldValue else { return }
            if !isApplyingLoadedLibrary { savePortals() }
            if library.set(id: baseSetID) == nil { baseSetID = PortalSet.defaultID }
            if let id = modifierSetID, library.set(id: id) == nil { modifierSetID = nil }
        }
    }

    /// The whole library (every portal, in library order). Assigning adds new portals
    /// to the default set and drops removed ones from every set.
    var portals: [PortalDefinition] {
        get { library.portals }
        set { library.setPortals(newValue) }
    }

    /// The set shown when no set modifier is held. Persisted; `action select-set` and
    /// `settings set activeSet=` change it.
    @Published var baseSetID: String = UserDefaults.standard.string(forKey: AppDelegate.activeSetDefaultsKey)
        ?? PortalSet.defaultID {
        didSet {
            guard baseSetID != oldValue else { return }
            UserDefaults.standard.set(baseSetID, forKey: AppDelegate.activeSetDefaultsKey)
        }
    }

    /// The set swapped in while its modifier key is held (see `ModifierSetTracker`).
    @Published private(set) var modifierSetID: String?

    /// What the portal window shows: the modifier set while held, else the base set.
    var activeSet: PortalSet {
        modifierSetID.flatMap(library.set(id:)) ?? library.set(id: baseSetID) ?? library.defaultSet
    }

    var activePortals: [PortalDefinition] { library.portals(in: activeSet) }

    /// Selected portal id per set id, remembered across launches.
    @Published private var selectedPortalBySet: [String: UUID] = AppDelegate.savedSelections() {
        didSet {
            guard selectedPortalBySet != oldValue else { return }
            let raw = selectedPortalBySet.mapValues(\.uuidString)
            UserDefaults.standard.set(raw, forKey: AppDelegate.selectionsDefaultsKey)
            // Older builds read this key; keep it in step with the default set.
            if let id = selectedPortalBySet[PortalSet.defaultID] {
                UserDefaults.standard.set(id.uuidString, forKey: AppDelegate.legacySelectedPortalDefaultsKey)
            }
        }
    }

    /// The selected portal of the active set. Falls back to the set's first portal (the
    /// built-in wormhole unless the set moved it) when the remembered one is gone.
    var selectedPortalID: UUID {
        get {
            let set = activeSet
            if let id = selectedPortalBySet[set.id], set.contains(id), library.portals.contains(where: { $0.id == id }) {
                return id
            }
            return library.portals(in: set).first?.id ?? PortalDefinition.wormholeID
        }
        set { selectedPortalBySet[activeSet.id] = newValue }
    }

    private static let legacySelectedPortalDefaultsKey = "selectedPortalID"
    private static let selectionsDefaultsKey = "selectedPortalBySet"
    private static let activeSetDefaultsKey = "activeSetID"
    private static let hotKeyDefaultsKey = "hotkey"

    private static func savedSelections() -> [String: UUID] {
        let raw = UserDefaults.standard.dictionary(forKey: selectionsDefaultsKey) as? [String: String] ?? [:]
        var result = raw.compactMapValues(UUID.init(uuidString:))
        if result[PortalSet.defaultID] == nil,
           let legacy = UserDefaults.standard.string(forKey: legacySelectedPortalDefaultsKey).flatMap(UUID.init(uuidString:)) {
            result[PortalSet.defaultID] = legacy
        }
        return result
    }

    /// Status text for command portals (pending verb / success label).
    @Published var portalMessage: String?

    var selectedPortal: PortalDefinition {
        activePortals.first { $0.id == selectedPortalID } ?? activePortals.first ?? .wormhole
    }

    /// What the in-flight transfer is, independent of which portal is now selected.
    enum TransferJob { case send, receive, command }
    @Published var currentJob: TransferJob?

    /// How the portal window is represented (MacHUD `panel mode`).
    @Published var panelMode: HUDPanelMode = .full

    // MARK: - Portal persistence

    let portalStore = PortalStore()
    private var isApplyingLoadedLibrary = false
    /// False until portals.json has been read successfully. While false the in-memory
    /// library is a placeholder (e.g. the file was written by a newer version) and
    /// must never overwrite the file.
    private var canSaveLibrary = false

    func savePortals() {
        guard canSaveLibrary else {
            print("⚠️ portals.json was not loaded; not saving over it")
            return
        }
        do {
            try portalStore.save(library)
        } catch {
            print("❌ failed to save portals: \(error.localizedDescription)")
        }
    }

    private func applyLoadedLibrary(_ loaded: PortalLibrary) {
        isApplyingLoadedLibrary = true
        library = loaded
        isApplyingLoadedLibrary = false
        canSaveLibrary = true
    }

    // MARK: - Sets

    /// Makes `key` (set name or id) the base set.
    @discardableResult
    func selectBaseSet(_ key: String) throws -> PortalSet {
        guard let set = library.set(named: key) else { throw PortalStoreError.setNotFound(key) }
        baseSetID = set.id
        return set
    }

    let modifierTracker = ModifierSetTracker()

    /// Applies the held modifiers (shift/option/control) to the active set.
    func applyHeldModifiers(_ held: Set<PortalSetModifier>) {
        let id = library.set(forHeldModifiers: held)?.id
        if id != modifierSetID { modifierSetID = id }
    }

    /// Silent PATH install: `~/.local/bin/portal` → this app's helper.
    /// Never overwrites someone else's `portal`, never touches Homebrew prefixes,
    /// never edits shell rc files.
    func installPortalCLISymlink() {
        let fm = FileManager.default
        guard let helper = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("portal"),
              fm.isExecutableFile(atPath: helper.path) else {
            print("❌ portal helper missing from bundle")
            return
        }
        let bin = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let link = bin.appendingPathComponent("portal")
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            if fm.fileExists(atPath: link.path) {
                if !isOurPortalSymlink(at: link, helper: helper) {
                    print("⚠️ ~/.local/bin/portal exists and is not us; leaving it")
                    return
                }
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
            print("✅ portal CLI linked at \(link.path)")
        } catch {
            print("❌ failed to install portal symlink: \(error)")
        }
    }

    private func isOurPortalSymlink(at link: URL, helper: URL) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        let resolved: URL
        if dest.hasPrefix("/") {
            resolved = URL(fileURLWithPath: dest).standardizedFileURL
        } else {
            resolved = link.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL
        }
        if resolved == helper.standardizedFileURL { return true }
        return resolved.path.lowercased().hasSuffix("/wormhole.app/contents/macos/portal")
    }
    
    private var sendProcessState: ProcessState = .notStarted {
        didSet {
            print("🔄 Send process state changed: \(sendProcessState.description)")
        }
    }
    private var receiveProcessState: ProcessState = .notStarted {
        didSet {
            print("🔄 Receive process state changed: \(receiveProcessState.description)")
        }
    }
    
    private var statusItem: NSStatusItem?
    private var portalWindowController: NSWindowController?
    /// The persistent portal `NSWindow` (distinct from the setup-wizard window, which
    /// also transiently occupies `portalWindowController`). Kept alive across
    /// show/hide toggles so the window retains its user-chosen position and size.
    private(set) var portalWindow: KeyableWindow?
    private var settingsWindowController: NSWindowController?
    
    private var receiveTask: Process?
    private var receiveTaskInputPipe: Pipe?
    
    private var sendTask: Process?
    private var sendOutputHandle: FileHandle?
    private var sendErrorHandle: FileHandle?
    
    // Add new error states
    enum TransferError: LocalizedError {
        case fileNotFound(String)
        case wormholeNotInstalled
        case transferRejected
        case transferFailed(String)
        case fileAccessDenied
        
        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path):
                return "File not found at: \(path)"
            case .wormholeNotInstalled:
                return "Magic Wormhole not found. Please install it via Homebrew first."
            case .transferRejected:
                return "Transfer was rejected by the receiver"
            case .transferFailed(let reason):
                return "Transfer failed: \(reason)"
            case .fileAccessDenied:
                return "Permission denied. Please check file access permissions."
            }
        }
    }
    
    private let updaterViewModel = UpdaterViewModel()
    
    private var hotKeyRegistration: UInt32?
    private(set) var hotKey: HUDHotKey = AppDelegate.savedHotKey()
    private(set) var hud: PortalHUDController?
    
    var isPortalWindowOpen: Bool {
        return portalWindowController?.window?.isVisible ?? false
    }
    
    private var isOpeningFromOnboarding = false
    
    /// True when this process is the host app for the unit-test bundle.
    private var isHostingUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // As a test host, skip every launch side effect: registering the
        // global hotkey, the menu bar item, dependency checks, and above all
        // re-pointing ~/.local/bin/portal at a DerivedData build.
        if isHostingUnitTests { return }

        print("Check if this is first launch")
        print("hasLaunchedBefore: \(UserDefaults.standard.bool(forKey: "hasLaunchedBefore"))")
        isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")

        // Load user-defined portals from portals.json (migrating UserDefaults once).
        // On failure the library stays a wormhole-only placeholder and is never saved.
        do {
            applyLoadedLibrary(try portalStore.load())
        } catch PortalStoreError.unknownVersion(let version) {
            print("❌ portals.json version \(version) is newer; not clobbering")
        } catch {
            print("❌ failed to load portals: \(error.localizedDescription)")
        }
        DispatchQueue.main.async { [weak self] in
            self?.portalStore.startWatching { [weak self] loaded in
                self?.applyLoadedLibrary(loaded)
            }
            self?.installPortalCLISymlink()
        }

        modifierTracker.onChange = { [weak self] held in self?.applyHeldModifiers(held) }

        // MacHUD contract: control socket at HUDSocket.path(for: "wormhole").
        let hud = PortalHUDController(app: self)
        hud.start()
        self.hud = hud

        // Set up status item (menu bar icon)
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = statusItem?.button {
                button.image = NSImage(systemSymbolName: "line.3.crossed.swirl.circle.fill", accessibilityDescription: "wormhole")
            }
        }
        
        setupMenus()
        setupHotKey()
        
        // Start dependency check
        checkDependencies()
        
        // Show portal window automatically on first launch
        if isFirstLaunch {
            // Small delay to ensure everything is initialized
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPortalWindow()
                // Only mark as launched after the window is shown to avoid race condition
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                print("isFirstLaunch, setting hasLaunchedBefore to true after window shown")
            }
        }

        // Lets automation/testing tools (e.g. scripts/ax-move-test.sh) open the portal
        // window deterministically, without depending on the global hotkey.
        if CommandLine.arguments.contains("--show-portal") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPortalWindow()
            }
        }
    }
    
    // MARK: - Setup
    
    func setupMenus() {
        let menu = NSMenu()
        
        // Add Check for Updates menu item
        if updaterViewModel.canCheckForUpdates {
            menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u"))
            menu.addItem(NSMenuItem.separator())
        }
        
        menu.addItem(NSMenuItem(title: "Portal", action: #selector(togglePortalWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Configure Portals…", action: #selector(showPortalSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.shared.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc func checkForUpdates() {
        updaterViewModel.checkForUpdates()
    }
    
    // MARK: - Hotkey

    static let defaultHotKey = HUDHotKey(key: "p", modifiers: ["option", "control"])

    private static func savedHotKey() -> HUDHotKey {
        UserDefaults.standard.string(forKey: hotKeyDefaultsKey).flatMap(parseHotKey) ?? defaultHotKey
    }

    /// Parses `option+control+p` (modifiers: command/cmd, option/alt, control/ctrl, shift).
    static func parseHotKey(_ string: String) -> HUDHotKey? {
        let parts = string.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty, HUDHotKeyCenter.keyCode(for: key) != nil else { return nil }
        let known: [String: String] = ["command": "command", "cmd": "command", "option": "option", "alt": "option",
                                       "opt": "option", "control": "control", "ctrl": "control", "shift": "shift"]
        var modifiers: [String] = []
        for part in parts.dropLast() {
            guard let m = known[part] else { return nil }
            if !modifiers.contains(m) { modifiers.append(m) }
        }
        guard !modifiers.isEmpty else { return nil }
        return HUDHotKey(key: key, modifiers: modifiers)
    }

    static func hotKeyString(_ hotKey: HUDHotKey) -> String {
        (hotKey.modifiers + [hotKey.key]).joined(separator: "+")
    }

    private func setupHotKey() {
        if !registerHotKey(hotKey, persist: false) && hotKey != Self.defaultHotKey {
            registerHotKey(Self.defaultHotKey, persist: false)
        }
    }

    /// Registers `newHotKey` in place of the current one; on failure the old one stays.
    /// `persist` saves it as the user's choice (`settings set hotkey=`).
    @discardableResult
    func registerHotKey(_ newHotKey: HUDHotKey, persist: Bool = true) -> Bool {
        if let id = hotKeyRegistration { HUDHotKeyCenter.shared.unregister(id) }
        hotKeyRegistration = nil
        if let id = HUDHotKeyCenter.shared.register(newHotKey, onPress: { [weak self] in self?.hotKeyPressed() }) {
            hotKeyRegistration = id
            hotKey = newHotKey
            if persist { UserDefaults.standard.set(Self.hotKeyString(newHotKey), forKey: Self.hotKeyDefaultsKey) }
            return true
        }
        if newHotKey != hotKey,
           let id = HUDHotKeyCenter.shared.register(hotKey, onPress: { [weak self] in self?.hotKeyPressed() }) {
            hotKeyRegistration = id
        }
        return false
    }

    private func hotKeyPressed() {
        if isPortalWindowOpen {
            closePortalWindow()
            return
        }
        showPortalWindow()
        // The hotkey chord is still held: follow set modifiers from here until it is
        // released, ignoring the chord's own modifiers.
        let chord = Set(hotKey.modifiers.compactMap { try? PortalSetModifier.parse($0) })
        modifierTracker.beginHotKeyChord(masking: chord)
    }
    
    // MARK: - Send
    
    func send(with path: String, showWindow: Bool = false) {
        print("📤 Starting send process for path: \(path)")
        
        // Clean up any existing process first
        if sendProcessState != .notStarted {
            print("⚠️ Cleaning up existing send process before starting new one")
            cleanupSendProcess(immediate: true)
        }
        
        sendProcessState = .starting
        currentJob = .send
        transferState = .pending
        progress = 0
        wormholeCode = nil
        fileName = nil
        fileSize = nil
        errorMessage = nil
        
        // File validation
        guard FileManager.default.fileExists(atPath: path) else {
            print("❌ File not found at path: \(path)")
            handleSendError(.fileNotFound(path))
            return
        }
        
        guard FileManager.default.isReadableFile(atPath: path) else {
            print("❌ File not readable at path: \(path)")
            handleSendError(.fileAccessDenied)
            return
        }
        
        // Check for wormhole installation
        let possiblePaths = [
            "/opt/homebrew/bin/wormhole",
            "/usr/local/bin/wormhole",
            "/usr/bin/wormhole"
        ]
        
        guard let wormholePath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("❌ Wormhole not found in expected paths")
            handleSendError(.wormholeNotInstalled)
            return
        }
        
        let task = Process()
        sendProcessState = .running
        
        // Set the launch path to /bin/zsh
        task.launchPath = "/bin/zsh"
        
        // Properly escape the file path for shell
        // Must escape: backslash, double quote, backtick, dollar sign, exclamation mark
        let escapedFilePath = path.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
                                 .replacingOccurrences(of: "`", with: "\\`")
                                 .replacingOccurrences(of: "$", with: "\\$")
                                 .replacingOccurrences(of: "!", with: "\\!")
        
        // Use quotes around the path to handle spaces and special characters
        task.arguments = ["-c", "\(wormholePath) send \"\(escapedFilePath)\""]
        
        print("📋 Command: \(wormholePath) send \"\(escapedFilePath)\"")
        
        // Optional flags we could add:
        // --code-length=3 (for longer codes)
        // --verify (for extra verification string)
        // --relay-url=URL (to use different relay server)
        // --transit-helper=HELPER (to override transit relay)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        sendOutputHandle = outputPipe.fileHandleForReading
        sendErrorHandle = errorPipe.fileHandleForReading
        
        setupSendOutputHandling()
        
        sendTask = task
        
        do {
            print("🚀 Launching send process")
            try task.run()
        } catch {
            print("❌ Failed to launch send process: \(error)")
            handleSendError(.transferFailed(error.localizedDescription))
            return
        }
        
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                print("🏁 Send process terminated with status: \(task.terminationStatus)")
                self?.handleSendProcessTermination(status: task.terminationStatus)
            }
        }
    }
    
    private func setupSendOutputHandling() {
        sendOutputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                print("📤 Received empty output data, ignoring")
                return
            }
            
            guard let output = String(data: data, encoding: .utf8) else {
                print("❌ Failed to decode output data")
                return
            }
            
            DispatchQueue.main.async {
                self?.processSendOutput(output)
            }
        }
        
        sendErrorHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                print("📤 Received empty error data, ignoring")
                return
            }
            
            guard let output = String(data: data, encoding: .utf8) else {
                print("❌ Failed to decode error data")
                return
            }
            
            DispatchQueue.main.async {
                self?.processSendOutput(output)
            }
        }
    }
    
    // Possible responses
    // TransferError: remote error, transfer abandoned: transfer rejected
    //Sending (<-192.168.1.15:52095)..
    //0%|          | 0.00/90.7k [00:00<?, ?B/s]
    //100%|██████████| 90.7k/90.7k [00:00<00:00, 47.8MB/s]
    //File sent.. waiting for confirmation
    //Confirmation received. Transfer complete.
    
    func processSendOutput(_ output: String) {
        print("📤 Processing send output: \(output)")
        
        if output.contains("TransferError") {
            if output.contains("transfer rejected") {
                handleSendError(.transferRejected)
            } else {
                handleSendError(.transferFailed(output))
            }
            return
        }
        
        let pattern = /.*%.*/
        
        // Set transferring state when we see the "Sending" message
        if output.contains("Sending (<-") {
            transferState = .transferring
        } else if output.contains("receive ") {
            wormholeCode = output.components(separatedBy: "receive ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let code = wormholeCode {
                print("🔑 Received wormhole code: \(code)")
                copyToClipboard(code)
            }
        } else if output.matches(of: pattern).count > 0 {
            guard let percentageString = output.components(separatedBy: "|").first else { return }
            let trimmedPercentageString = percentageString.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
            guard let percentage = Double(trimmedPercentageString) else { return }
              
            print("📊 Progress updated to \(percentage)%")
            progress = percentage
        } else if output.contains("Transfer complete") {
            print("✅ Transfer completed successfully")
            sendProcessState = .completing
            transferState = .success
            // Keep window open for a moment to show success state
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.cleanupSendProcess(immediate: false)
            }
        }
    }
    
    private func handleSendProcessTermination(status: Int32) {
        print("🔍 Handling send process termination")
        
        // Give a small delay to ensure all output is processed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            if status == 0 && self.sendProcessState == .running {
                print("✅ Send process completed successfully")
                self.sendProcessState = .completing
                self.transferState = .success
                
                // Delay cleanup to show success state
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.cleanupSendProcess(immediate: false)
                }
            } else if case .failed = self.sendProcessState {
                print("❌ Send process failed with status: \(status)")
                self.handleSendError(.transferFailed("Process terminated with status \(status)"))
            }
        }
    }
    
    private func handleSendError(_ error: TransferError) {
        print("❌ Handling send error: \(error.localizedDescription)")
        sendProcessState = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
        transferState = .failed
        cleanupSendProcess(immediate: false)
    }
    
    func cleanupSendProcess(immediate: Bool) {
        print("🧹 Starting send process cleanup (immediate: \(immediate))")
        
        let cleanup = { [weak self] in
            guard let self = self else { return }
            
            // Close file handles first
            print("📝 Closing file handles")
            self.sendOutputHandle?.readabilityHandler = nil
            self.sendErrorHandle?.readabilityHandler = nil
            self.sendOutputHandle = nil
            self.sendErrorHandle = nil
            
            // Terminate process if still running
            if let task = self.sendTask, task.isRunning {
                print("⏹️ Terminating running send process")
                task.terminate()
            }
            self.sendTask = nil
            
            // Reset state if not immediate (allow UI to show final state)
            if !immediate {
                print("🔄 Resetting send state")
                self.progress = 0
                self.wormholeCode = nil
                self.errorMessage = nil
                self.transferState = .idle
            }
            
            self.sendProcessState = .notStarted
        }
        
        if immediate {
            cleanup()
        } else {
            // Delay cleanup to ensure UI updates are visible
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: cleanup)
        }
    }
    
    // MARK: - Command Portals

    /// Escapes a string for safe placement inside a double-quoted shell context.
    /// Command-portal tokens (`{path}` etc.) are expected to sit inside double
    /// quotes in the user's template, mirroring the original traces command.
    private func shellEscapeForDoubleQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "`", with: "\\`")
         .replacingOccurrences(of: "$", with: "\\$")
    }

    /// Runs a user-defined command portal against the dropped file.
    func runCommandPortal(_ config: CommandPortalConfig, path: String) {
        print("⚙️ Running command portal for path: \(path)")

        currentJob = .command
        transferState = .pending
        let verb = config.pendingVerb.trimmingCharacters(in: .whitespaces)
        portalMessage = verb.isEmpty ? "working..." : "\(verb)..."
        errorMessage = nil

        guard FileManager.default.fileExists(atPath: path) else {
            handleSendError(.fileNotFound(path))
            return
        }

        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent
        let dir = url.deletingLastPathComponent().path

        let command = config.commandTemplate
            .replacingOccurrences(of: PortalToken.path, with: shellEscapeForDoubleQuotes(path))
            .replacingOccurrences(of: PortalToken.filename, with: shellEscapeForDoubleQuotes(filename))
            .replacingOccurrences(of: PortalToken.dir, with: shellEscapeForDoubleQuotes(dir))

        print("📋 Command: \(command)")

        let successText: String = {
            let label = config.successLabel.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return "done" }
            return label.replacingOccurrences(of: PortalToken.filename, with: filename)
        }()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()

            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            var args = [String]()
            if config.runInLoginShell { args.append("-l") }
            args.append(contentsOf: ["-c", command])
            task.arguments = args

            if let wd = config.workingDirectory?.trimmingCharacters(in: .whitespaces), !wd.isEmpty {
                let expanded = (wd as NSString).expandingTildeInPath
                task.currentDirectoryURL = URL(fileURLWithPath: expanded)
            }

            task.standardOutput = pipe
            task.standardError = errorPipe

            do {
                try task.run()

                // Drain both pipes before waiting: a command that writes more
                // than the pipe buffer (~64 KB) would otherwise block forever
                // and the portal would stay "pending".
                var errorData = Data()
                let stderrDrained = DispatchGroup()
                stderrDrained.enter()
                DispatchQueue.global(qos: .utility).async {
                    errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrDrained.leave()
                }
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                stderrDrained.wait()
                task.waitUntilExit()

                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    if task.terminationStatus == 0 {
                        print("✅ Command portal complete:\n\(output)")
                        self?.portalMessage = successText
                        self?.transferState = .success
                    } else {
                        print("❌ Command portal failed (status \(task.terminationStatus)):\n\(errorOutput)\n\(output)")
                        self?.errorMessage = "Command failed"
                        self?.transferState = .failed
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ Failed to launch command portal: \(error)")
                    self?.errorMessage = "Failed to run command"
                    self?.transferState = .failed
                }
            }
        }
    }

    // MARK: - Receive
    
    private func isValidWormholeCode(_ code: String) -> Bool {
        let pattern = /^\d+-[a-z]+-[a-z]+$/
        return code.matches(of: pattern).count == 1
    }

    func receive(code: String) {
        print("📥 Starting receive process for code: \(code)")

        // Validate code format to prevent shell injection
        let cleanedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidWormholeCode(cleanedCode) else {
            print("❌ Invalid wormhole code format: \(code)")
            handleReceiveError(.transferFailed("Invalid code format. Expected format: number-word-word"))
            return
        }

        // Clean up any existing process first
        if receiveProcessState != .notStarted {
            print("⚠️ Cleaning up existing receive process before starting new one")
            cleanupReceiveProcess(immediate: true)
        }

        receiveProcessState = .starting
        currentJob = .receive
        transferState = .pending
        progress = 0
        fileName = nil
        fileSize = nil
        errorMessage = nil

        // Verify Downloads directory exists and is writable
        let downloadsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        guard FileManager.default.fileExists(atPath: downloadsPath) else {
            print("❌ Downloads directory not found")
            handleReceiveError(.transferFailed("Downloads directory not found"))
            return
        }
        
        guard FileManager.default.isWritableFile(atPath: downloadsPath) else {
            print("❌ Downloads directory not writable")
            handleReceiveError(.fileAccessDenied)
            return
        }
        
        // Check for wormhole installation
        let possiblePaths = [
            "/opt/homebrew/bin/wormhole",
            "/usr/local/bin/wormhole",
            "/usr/bin/wormhole"
        ]
        
        guard let wormholePath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("❌ Wormhole not found in expected paths")
            handleReceiveError(.wormholeNotInstalled)
            return
        }
        
        let task = Process()
        receiveProcessState = .running
        
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", "cd ~/Downloads && \(wormholePath) receive \(cleanedCode)"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        receiveTaskInputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        task.standardInput = receiveTaskInputPipe
        
        setupReceiveOutputHandling(outputPipe: outputPipe, errorPipe: errorPipe)
        
        receiveTask = task
        
        do {
            print("🚀 Launching receive process")
            try task.run()
        } catch {
            print("❌ Failed to launch receive process: \(error)")
            handleReceiveError(.transferFailed(error.localizedDescription))
            return
        }
        
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                print("🏁 Receive process terminated with status: \(task.terminationStatus)")
                self?.receiveProcessState = .completed
                self?.handleReceiveProcessTermination(status: task.terminationStatus)
            }
        }
    }
    
    private func setupReceiveOutputHandling(outputPipe: Pipe, errorPipe: Pipe) {
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                print("📥 Received empty output data, ignoring")
                return
            }
            
            guard let output = String(data: data, encoding: .utf8) else {
                print("❌ Failed to decode output data")
                return
            }
            
            DispatchQueue.main.async {
                self?.processReceiveOutput(output)
            }
        }
        
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                print("📥 Received empty error data, ignoring")
                return
            }
            
            guard let output = String(data: data, encoding: .utf8) else {
                print("❌ Failed to decode error data")
                return
            }
            
            DispatchQueue.main.async {
                self?.processReceiveOutput(output)
            }
        }
    }
    
    func processReceiveOutput(_ output: String) {
        print("📥 Processing receive output: \(output)")
        
        if output.contains("TransferError") {
            if output.contains("transfer rejected") {
                handleReceiveError(.transferRejected)
            } else {
                handleReceiveError(.transferFailed(output))
            }
            return
        }
        
        if output.contains("Permission denied") {
            handleReceiveError(.fileAccessDenied)
            return
        }
        
        let pattern = /.*%.*/
        
        // Handle accept prompt
        if output.contains("ok? (Y/n):") {
            print("👍 Auto-confirming receive prompt")
            confirmReceive()
            return
        }
        
        // Extract file info
        if output.contains("Receiving file") {
            if let size = output.components(separatedBy: "(").last?.components(separatedBy: ")").first {
                print("📦 File size detected: \(size)")
                fileSize = size
            }

            let components = output.components(separatedBy: "\'")
            if components.count > 1 {
                let name = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                print("📄 Filename detected: \(name)")
                fileName = name
            } else {
                print("⚠️ Could not parse filename from output: \(output)")
            }

            transferState = .transferring
        }
        // Handle progress updates
        else if output.matches(of: pattern).count > 0 {
            if let percentageString = output.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: ""),
               let percentage = Double(percentageString) {
                print("📊 Progress update: \(percentage)%")
                progress = percentage
            }
        }
        // Handle completion
        else if output.contains("Received file") {
            print("✅ File received successfully")
            receiveProcessState = .completing
            transferState = .success
        }
    }
    
    private func handleReceiveProcessTermination(status: Int32) {
        print("🔍 Handling receive process termination")
        
        // Give a small delay to ensure all output is processed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            if status == 0 && self.receiveProcessState == .completed {
                print("✅ Receive process completed successfully")
                self.receiveProcessState = .completing
                
                // Delay cleanup to show success state
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.cleanupReceiveProcess(immediate: false)
                }
            } else if case .failed = self.receiveProcessState {
                print("❌ Receive process failed with status: \(status)")
                self.handleReceiveError(.transferFailed("Process terminated with status \(status)"))
            }
        }
    }
    
    private func handleReceiveError(_ error: TransferError) {
        print("❌ Handling receive error: \(error.localizedDescription)")
        receiveProcessState = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
        transferState = .failed
        cleanupReceiveProcess(immediate: false)
    }
    
    func cleanupReceiveProcess(immediate: Bool) {
        print("🧹 Starting receive process cleanup (immediate: \(immediate))")
        
        let cleanup = { [weak self] in
            guard let self = self else { return }
            
            // Close input pipe first
            print("📝 Closing input pipe")
            self.receiveTaskInputPipe?.fileHandleForWriting.closeFile()
            self.receiveTaskInputPipe = nil
            
            // Terminate process if still running
            if let task = self.receiveTask, task.isRunning {
                print("⏹️ Terminating running receive process")
                task.terminate()
            }
            self.receiveTask = nil
            
            // Reset state if not immediate (allow UI to show final state)
            if !immediate {
                print("🔄 Resetting receive state")
                self.progress = 0
                self.fileName = nil
                self.fileSize = nil
                self.errorMessage = nil
                self.transferState = .idle
            }
            
            self.receiveProcessState = .notStarted
        }
        
        if immediate {
            cleanup()
        } else {
            // Delay cleanup to ensure UI updates are visible
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: cleanup)
        }
    }
    
    private func confirmReceive() {
        print("👍 Sending receive confirmation")
        guard let data = ("Y\n").data(using: .utf8) else {
            print("❌ Failed to create confirmation data")
            return
        }
        
        receiveTaskInputPipe?.fileHandleForWriting.write(data)
    }
    
    // MARK: - Utility
    
    func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
    
    // MARK: - Windows
    
    func showPortalWindow() {
        // If a portal window is already open, bring it to front instead of creating a new one
        if isPortalWindowOpen {
            portalWindowController?.window?.makeKeyAndOrderFront(nil)
            return
        }

        // Show setup wizard if it's first launch or if dependencies aren't ready
        if isFirstLaunch || dependencyState != .ready {
            let contentView = SetupWizardView().environmentObject(self)
            let window = KeyableWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Wormhole Setup"
            window.isOpaque = false
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true
            window.level = .floating
            window.isRestorable = false
            window.center()
            
            let hostingView = NSHostingView(rootView: contentView)
            window.contentView = hostingView
            
            let windowController = NSWindowController(window: window)
            portalWindowController = windowController
            windowController.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        
        // Reuse the persistent window if it already exists instead of rebuilding it,
        // so the user's chosen position/size survive show/hide toggles.
        let window = ensurePortalWindow()
        if portalWindowController == nil || portalWindowController?.window !== window {
            portalWindowController = NSWindowController(window: window)
        }
        portalWindowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        portalVisibilityChanged()
    }

    /// The persistent portal window, created (hidden) on first use.
    @discardableResult
    func ensurePortalWindow() -> KeyableWindow {
        if let window = portalWindow { return window }
        let contentView = PortalView().environmentObject(self)
        let window = KeyableWindow(
            contentRect: NSRect(origin: .zero, size: portalWindowSize),
            // .resizable makes the size AX-settable (window managers, MacHUD) as well as the position.
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isRestorable = false
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier("portal")
        window.delegate = self

        // The window's frame belongs to the user, AX clients and MacHUD (`panel frame`),
        // not to SwiftUI: the hosting view sits in a plain container and follows it by
        // autoresizing, so the content's size never pins or resizes the window. A frame
        // smaller than the portal's natural 320×240 shows it centered and clipped.
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: portalWindowSize)
        hostingView.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: portalWindowSize))
        container.addSubview(hostingView)
        window.contentView = container

        window.setContentSize(portalWindowSize)

        // Only fall back to the top-right default position when no frame was
        // previously saved for this window (first launch, or defaults were cleared).
        let restoredSavedFrame = window.setFrameAutosaveName("PortalWindow")
        if !restoredSavedFrame, let screen = NSScreen.main {
            let rect = screen.frame
            let padding: CGFloat = 80 // Padding from the edges
            let x = max(0, rect.maxX - window.frame.width - padding)
            let y = max(0, rect.maxY - window.frame.height - padding)

            if x.isFinite && y.isFinite {
                window.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                print("⚠️ Invalid window coordinates detected, centering instead")
                window.center()
            }
        }

        portalWindow = window
        return window
    }

    /// Tells MacHUD subscribers the portal was shown or hidden.
    func portalVisibilityChanged() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.hud?.publishIfChanged() }
        }
    }
    
    // Add this method to toggle the portal window
    @objc func togglePortalWindow() {
        if isPortalWindowOpen {
            closePortalWindow()
        } else {
            showPortalWindow()
        }
    }
    
    @objc func showPortalSettings() {
        if let wc = settingsWindowController {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = PortalSettingsView().environmentObject(self)
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Portals"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.contentView = NSHostingView(rootView: contentView)

        let windowController = NSWindowController(window: window)
        settingsWindowController = windowController

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindowController = nil
        }

        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePortalWindow() {
        print("🪟 Closing portal window directly")

        if !isOpeningFromOnboarding {
            SoundManager.shared.playPortalClose()
        }

        // The persistent portal window is only ever hidden, never destroyed, so it
        // keeps its user-chosen frame across show/hide toggles. Any other window
        // currently tracked here (e.g. the setup wizard) is still fully closed.
        if let window = portalWindowController?.window, window === portalWindow {
            window.orderOut(nil)
            portalVisibilityChanged()
            return
        }

        self.portalWindowController?.close()
        self.portalWindowController = nil
    }

    deinit {
        print("🗑️ AppDelegate deinit")
        
        // Cleanup all processes and windows with immediate=true
        cleanupReceiveProcess(immediate: true)
        cleanupSendProcess(immediate: true)
        
        // Remove from status bar
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        
        // Clear status item reference
        statusItem = nil
    }
    
    // Add these new methods for dependency management
    func checkDependencies() {
        print("🔍 Starting dependency check...")
        dependencyState = .checking
        
        // Check Homebrew first
        print("🍺 Checking for Homebrew installation...")
        if !isHomebrewInstalled() {
            print("❌ Homebrew not found in any expected paths")
            dependencyState = .needsHomebrew
            return
        }
        print("✅ Homebrew found")
        
        // Then check Magic Wormhole
        print("🪄 Checking for Magic Wormhole installation...")
        if !isMagicWormholeInstalled() {
            print("❌ Magic Wormhole not found in any expected paths")
            dependencyState = .needsMagicWormhole
            return
        }
        print("✅ Magic Wormhole found")
        
        print("✨ All dependencies ready")
        dependencyState = .ready
    }
    
    private func isHomebrewInstalled() -> Bool {
        let possiblePaths = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        print("🔍 Checking Homebrew paths:")
        for path in possiblePaths {
            let exists = FileManager.default.fileExists(atPath: path)
            print("   - \(path): \(exists ? "✅" : "❌")")
        }
        return possiblePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
    
    private func isMagicWormholeInstalled() -> Bool {
        let possiblePaths = [
            "/opt/homebrew/bin/wormhole",
            "/usr/local/bin/wormhole",
            "/usr/bin/wormhole"
        ]
        print("🔍 Checking Magic Wormhole paths:")
        for path in possiblePaths {
            let exists = FileManager.default.fileExists(atPath: path)
            print("   - \(path): \(exists ? "✅" : "❌")")
        }
        return possiblePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
    
    func installMagicWormhole() {
        print("🚀 Starting Magic Wormhole installation...")
        
        guard isHomebrewInstalled() else {
            print("❌ Cannot install Magic Wormhole: Homebrew not found")
            dependencyState = .needsHomebrew
            return
        }
        print("✅ Homebrew available for installation")
        
        // Get the full path to brew
        let possibleBrewPaths = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        
        guard let brewPath = possibleBrewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("❌ Cannot find brew executable path")
            dependencyState = .error("Cannot find brew executable path")
            return
        }
        print("🍺 Found brew at path: \(brewPath)")
        
        dependencyState = .installing
        installationProgress = "Installing Magic Wormhole..."
        
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", "\(brewPath) install magic-wormhole"]
        
        print("📋 Installation command: \(brewPath) install magic-wormhole")
        print("🔧 Using shell: \(task.launchPath ?? "unknown")")
        
        // Set up environment variables
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        task.environment = env
        print("🌍 Setting PATH environment: \(env["PATH"] ?? "none")")
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let output = String(data: data, encoding: .utf8) {
                    print("📤 Installation output: \(output)")
                    DispatchQueue.main.async {
                        self?.installationProgress = output
                    }
                }
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let output = String(data: data, encoding: .utf8) {
                    print("⚠️ Installation error output: \(output)")
                    // Don't immediately set error state, as some error output is normal
                    DispatchQueue.main.async {
                        self?.installationProgress = output
                    }
                }
            }
        }
        
        task.terminationHandler = { [weak self] task in
            print("🏁 Installation process terminated with status: \(task.terminationStatus)")
            DispatchQueue.main.async {
                // Clean up pipe handlers first
                print("🧹 Cleaning up pipe handlers")
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                
                // Verify installation success by checking if wormhole is now installed
                if self?.isMagicWormholeInstalled() == true {
                    print("✅ Magic Wormhole is now installed, proceeding to ready state")
                    self?.dependencyState = .ready
                } else if task.terminationStatus == 0 {
                    // Process exited with success code but wormhole not found - try rechecking
                    print("⚠️ Process exited with success code but wormhole not found, rechecking dependencies")
                    self?.checkDependencies()
                } else {
                    print("❌ Installation failed with status: \(task.terminationStatus)")
                    self?.dependencyState = .error("Failed to install Magic Wormhole (status: \(task.terminationStatus))")
                }
            }
        }
        
        do {
            print("▶️ Launching installation process...")
            try task.run()
            print("✅ Installation process launched successfully")
        } catch {
            print("❌ Failed to launch installation process: \(error)")
            print("   - Error description: \(error.localizedDescription)")
            print("   - Error details: \(String(describing: error))")
            dependencyState = .error("Failed to start installation: \(error.localizedDescription)")
        }
    }
    
    func openPortalFromOnboarding() {
        isOpeningFromOnboarding = true
        closePortalWindow()

        isFirstLaunch = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.showPortalWindow()
        }

        // Reset the flag after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isOpeningFromOnboarding = false
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Handles the portal window being closed for real (e.g. via some route other
    /// than `closePortalWindow()`, which normally just hides it). Drops the stale
    /// references so the next `showPortalWindow()` call rebuilds the window instead
    /// of operating on a closed one.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === portalWindow else { return }
        modifierTracker.setWindowKey(false)
        portalWindow = nil
        if portalWindowController?.window === window {
            portalWindowController = nil
        }
    }

    /// `setFrameAutosaveName` is documented to save the frame automatically whenever
    /// the window moves or resizes, but that isn't reliably firing for this window
    /// (observed empirically: no "NSWindow Frame PortalWindow" default is ever
    /// written, even across a clean quit). Save explicitly on both notifications so
    /// the position set via a drag, or programmatically (e.g. Accessibility API
    /// automation), always persists.
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === portalWindow else { return }
        savePortalFrameIfResting(window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === portalWindow else { return }
        savePortalFrameIfResting(window)
    }

    /// Only the full-size, on-screen frame is the user's portal position: parked and
    /// compact frames (and the frames in between while animating) are never saved.
    func savePortalFrameIfResting(_ window: NSWindow) {
        let animating = MainActor.assumeIsolated { hud?.isAnimating ?? false }
        guard panelMode == .full, !animating else { return }
        window.saveFrame(usingName: "PortalWindow")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === portalWindow else { return }
        modifierTracker.setWindowKey(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === portalWindow else { return }
        modifierTracker.setWindowKey(false)
    }
}

// Add this before the SetupWizardView
struct AppFontModifier: ViewModifier {
    enum Size {
        case large
        case normal
        case small
        case tiny
        case forants
        
        var fontSize: CGFloat {
            switch self {
            case .large: return 20
            case .normal: return 14
            case .small: return 12
            case .tiny: return 10
            case .forants: return 8
            }
        }
    }
    
    let size: Size
    
    init(_ size: Size = .normal) {
        self.size = size
    }
    
    func body(content: Content) -> some View {
        content
            .font(.system(size: size.fontSize, design: .monospaced))
    }
}

extension View {
    func appFont(_ size: AppFontModifier.Size = .normal) -> some View {
        modifier(AppFontModifier(size))
    }
}

struct SetupWizardView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var showingOnboarding = false

    private let portalPurple = Color(red: 0.463, green: 0.204, blue: 0.514)  // #763483
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "line.3.crossed.swirl.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(portalPurple)
            
            if showingOnboarding {
                VStack(spacing: 16) {
                    Text("prepare for jump...")
                        .appFont(.large)
                        .bold()
                    
                    VStack(spacing: 12) {
                        Text("drag & drop files into the wormhole to send")
                            .appFont(.normal)
                            .multilineTextAlignment(.center)
                        
                        Text("click the wormhole to receive")
                            .appFont(.normal)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    
                    Button("open the wormhole") {
                        appDelegate.openPortalFromOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
            } else {
                Text("analyzing space-time conditions")
                    .appFont(.large)
                    .bold()
                
                switch appDelegate.dependencyState {
                case .checking:
                    ProgressView("checking dependencies...")
                        .appFont(.normal)
                    
                case .needsHomebrew:
                    VStack(spacing: 12) {
                        Text("Homebrew Required")
                            .appFont(.large)
                        
                        Text("Wormhole requires Homebrew to install Magic Wormhole. Please install Homebrew first:")
                            .appFont(.normal)
                            .multilineTextAlignment(.center)
                        
                        Text("```\n/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\n```")
                            .appFont(.small)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                        
                        Button("Copy Command") {
                            appDelegate.copyToClipboard(
                                "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                            )
                        }
                        .buttonStyle(.borderless)
                        
                        Text("After installing Homebrew, click Check Again")
                            .appFont(.small)
                            .foregroundStyle(.secondary)
                        
                        Button("Check Again") {
                            appDelegate.checkDependencies()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    
                case .needsMagicWormhole:
                    VStack(spacing: 12) {
                        Text("magic-wormhole required")
                            .appFont(.large)
                        
                        Text("wormhole needs magic-wormhole to transfer files. click below to install it automatically:")
                            .appFont(.normal)
                            .multilineTextAlignment(.center)
                        
                        Button("install magic-wormhole") {
                            appDelegate.installMagicWormhole()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    
                case .installing:
                    VStack(spacing: 12) {
                        ProgressView("installing magic-wormhole...")
                            .appFont(.normal)
                        Text(appDelegate.installationProgress)
                            .appFont(.small)
                            .foregroundStyle(.secondary)
                    }
                    
                case .error(let message):
                    VStack(spacing: 12) {
                        Text("Installation Error")
                            .appFont(.large)
                        
                        Text(message)
                            .appFont(.normal)
                            .foregroundStyle(.red)
                        
                        Button("Try Again") {
                            appDelegate.checkDependencies()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    
                case .ready:
                    VStack(spacing: 12) {
                        Text("space-time conditions optimal")
                            .appFont(.large)
                            .foregroundStyle(.green)
                        
                        Text("ready to warp?")
                            .appFont(.normal)
                            .padding(.top, 4)
                        
                        Button("initiate") {
                            withAnimation {
                                showingOnboarding = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    }
                    
                default:
                    EmptyView()
                }
            }
        }
        .frame(width: 400)
        .padding(24)
        .appFont()
        .onAppear {
            // If dependencies are ready, show onboarding immediately
            if appDelegate.dependencyState == .ready {
                showingOnboarding = true
            }
        }
    }
}

struct FrostCloud: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color.white.opacity(0.45))
        }
        .mask(
            EllipticalGradient(
                gradient: Gradient(stops: [
                    .init(color: .white,               location: 0.0),
                    .init(color: .white.opacity(0.85), location: 0.45),
                    .init(color: .white.opacity(0.35), location: 0.75),
                    .init(color: .clear,               location: 1.0),
                ]),
                center: .center,
                startRadiusFraction: 0.0,
                endRadiusFraction: 0.5
            )
        )
        .blur(radius: 6)
        .allowsHitTesting(false)
    }
}

private struct PortalSatelliteView: NSViewRepresentable {
    let portals: [PortalDefinition]
    let selectedPortalID: UUID
    let selectedScale: CGFloat
    let selectedRotationAngle: Double
    let selectedGlowIntensity: Double
    let onSelectionStarted: () -> Void
    let onSelect: (UUID) -> Void

    func makeNSView(context: Context) -> PortalSatelliteNSView {
        let view = PortalSatelliteNSView(frame: NSRect(origin: .zero, size: portalWindowSize))
        view.update(
            portals: portals,
            selectedPortalID: selectedPortalID,
            selectedScale: selectedScale,
            selectedRotationAngle: selectedRotationAngle,
            selectedGlowIntensity: selectedGlowIntensity,
            onSelectionStarted: onSelectionStarted,
            onSelect: onSelect
        )
        return view
    }

    func updateNSView(_ nsView: PortalSatelliteNSView, context: Context) {
        nsView.update(
            portals: portals,
            selectedPortalID: selectedPortalID,
            selectedScale: selectedScale,
            selectedRotationAngle: selectedRotationAngle,
            selectedGlowIntensity: selectedGlowIntensity,
            onSelectionStarted: onSelectionStarted,
            onSelect: onSelect
        )
    }
}

private final class PortalSatelliteNSView: NSView {
    private static let iconSize: CGFloat = 32
    private static let selectedIconSize: CGFloat = 96
    private static let hitRadius: CGFloat = 36
    private static let selectionDuration: CFTimeInterval = 0.45

    private let orbitLayer = CALayer()
    private var iconLayers: [UUID: CALayer] = [:]
    private var portals: [PortalDefinition] = []
    private var selectedPortalID = PortalDefinition.wormholeID
    private var selectedScale: CGFloat = 1
    private var selectedRotationAngle: Double = 0
    private var selectedGlowIntensity: Double = 0.1
    private var isSelecting = false
    private var onSelectionStarted: () -> Void = {}
    private var onSelect: (UUID) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(orbitLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbitLayer.frame = bounds
        CATransaction.commit()
        if !isSelecting {
            configureRoles()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        return portalID(at: localPoint) == nil ? nil : self
    }

    func update(
        portals: [PortalDefinition],
        selectedPortalID: UUID,
        selectedScale: CGFloat,
        selectedRotationAngle: Double,
        selectedGlowIntensity: Double,
        onSelectionStarted: @escaping () -> Void,
        onSelect: @escaping (UUID) -> Void
    ) {
        self.onSelectionStarted = onSelectionStarted
        self.onSelect = onSelect
        self.selectedScale = selectedScale
        self.selectedRotationAngle = selectedRotationAngle
        self.selectedGlowIntensity = selectedGlowIntensity

        let portalsChanged = portals != self.portals
        let selectionChanged = selectedPortalID != self.selectedPortalID
        self.selectedPortalID = selectedPortalID
        guard portalsChanged || selectionChanged else {
            updateSelectedAppearance()
            return
        }

        let newIDs = Set(portals.map(\.id))
        let oldIDs = Set(self.portals.map(\.id))
        let removedIDs = iconLayers.keys.filter { !newIDs.contains($0) }
        for id in removedIDs {
            iconLayers[id]?.removeFromSuperlayer()
            iconLayers[id] = nil
        }

        self.portals = portals
        for portal in portals {
            let iconLayer: CALayer
            if let existing = iconLayers[portal.id] {
                iconLayer = existing
            } else {
                iconLayer = makeIconLayer(for: portal)
                iconLayers[portal.id] = iconLayer
                orbitLayer.addSublayer(iconLayer)
            }
        }
        if !isSelecting {
            configureRoles()
            for portal in portals where !oldIDs.contains(portal.id) && portal.id != selectedPortalID {
                if let iconLayer = iconLayers[portal.id] {
                    animateSpawn(iconLayer)
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let id = portalID(at: point) {
            animateSelection(of: id)
        }
    }

    private func portalID(at point: CGPoint) -> UUID? {
        for portal in portals.reversed() where portal.id != selectedPortalID {
            guard let iconLayer = iconLayers[portal.id] else { continue }
            let position = (iconLayer.presentation() ?? iconLayer).position
            let dx = point.x - position.x
            let dy = point.y - position.y
            if dx * dx + dy * dy <= Self.hitRadius * Self.hitRadius {
                return portal.id
            }
        }
        return nil
    }

    private func animateSelection(of id: UUID) {
        guard id != selectedPortalID,
              let iconLayer = iconLayers[id],
              let portal = portals.first(where: { $0.id == id }) else { return }
        isSelecting = true
        onSelectionStarted()

        let current = iconLayer.presentation() ?? iconLayer
        let startPosition = current.position
        let startOpacity = current.opacity
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        iconLayer.removeAnimation(forKey: "portalOrbit")

        if let oldSelectedLayer = iconLayers[selectedPortalID] {
            let oldOpacity = oldSelectedLayer.presentation()?.opacity ?? oldSelectedLayer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            oldSelectedLayer.opacity = 0
            CATransaction.commit()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldOpacity
            fade.toValue = 0
            fade.duration = Self.selectionDuration * 0.8
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            oldSelectedLayer.add(fade, forKey: "portalSelectionFade")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.position = center
        iconLayer.opacity = 1
        iconLayer.zPosition = 10
        iconLayer.setAffineTransform(CGAffineTransform(scaleX: 3, y: 3))
        CATransaction.commit()

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = startPosition
        move.toValue = center

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 3

        let brighten = CABasicAnimation(keyPath: "opacity")
        brighten.fromValue = startOpacity
        brighten.toValue = 1

        let group = CAAnimationGroup()
        group.animations = [move, scale, brighten]
        group.duration = Self.selectionDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        iconLayer.add(group, forKey: "portalSelection")

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionDuration) { [weak self] in
            guard let self else { return }
            let oldSelectedID = self.selectedPortalID
            self.selectedPortalID = id

            self.configureSelected(iconLayer, for: portal)
            let inactive = self.portals.filter { $0.id != id }
            if let oldPortal = self.portals.first(where: { $0.id == oldSelectedID }),
               let oldSelectedLayer = self.iconLayers[oldSelectedID],
               let index = inactive.firstIndex(where: { $0.id == oldSelectedID }) {
                self.configureInactive(oldSelectedLayer, for: oldPortal)
                self.configureOrbit(
                    for: oldSelectedLayer,
                    portal: oldPortal,
                    index: index,
                    count: inactive.count
                )
                self.animateSpawn(oldSelectedLayer)
            }
            self.isSelecting = false
            self.updateSelectedAppearance()
            self.onSelect(id)
        }
    }

    private func configureRoles() {
        guard !portals.isEmpty, !bounds.isEmpty else { return }
        let inactive = portals.filter { $0.id != selectedPortalID }
        for portal in portals where portal.id == selectedPortalID {
            guard let iconLayer = iconLayers[portal.id] else { continue }
            configureSelected(iconLayer, for: portal)
        }
        for (index, portal) in inactive.enumerated() {
            guard let iconLayer = iconLayers[portal.id] else { continue }
            configureInactive(iconLayer, for: portal)
            configureOrbit(
                for: iconLayer,
                portal: portal,
                index: index,
                count: inactive.count
            )
        }
        updateSelectedAppearance()
    }

    private func configureSelected(_ iconLayer: CALayer, for portal: PortalDefinition) {
        iconLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: Self.selectedIconSize,
            height: Self.selectedIconSize
        )
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        iconLayer.opacity = 1
        iconLayer.zPosition = 10
        iconLayer.setAffineTransform(.identity)
        CATransaction.commit()
        updateIconLayer(iconLayer, for: portal, size: Self.selectedIconSize)
    }

    private func configureInactive(_ iconLayer: CALayer, for portal: PortalDefinition) {
        iconLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.bounds = CGRect(x: 0, y: 0, width: Self.iconSize, height: Self.iconSize)
        iconLayer.opacity = 1
        iconLayer.zPosition = 0
        iconLayer.setAffineTransform(.identity)
        CATransaction.commit()
        updateIconLayer(iconLayer, for: portal, size: Self.iconSize)
    }

    private func configureOrbit(
        for iconLayer: CALayer,
        portal: PortalDefinition,
        index: Int,
        count: Int
    ) {
        guard !bounds.isEmpty else { return }
        let bytes = withUnsafeBytes(of: portal.id.uuid) { Array($0) }
        let lane = index % 4
        let radiusX = CGFloat(76 + lane * 6)
        let radiusY = CGFloat(68 + lane * 4)
        let duration = CFTimeInterval(24 + lane * 8 + Int(bytes[2] % 7))
        let evenPhase = Double(index) / Double(max(count, 1))
        let phaseJitter = (Double(bytes[3]) / 255 - 0.5) * 0.12
        let phase = (evenPhase + phaseJitter + 1).truncatingRemainder(dividingBy: 1)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let orbitRect = CGRect(
            x: center.x - radiusX,
            y: center.y - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        )
        let path = CGMutablePath()
        path.addEllipse(in: orbitRect)

        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.path = path
        animation.duration = duration
        animation.timeOffset = duration * phase
        animation.repeatCount = .infinity
        animation.calculationMode = .paced
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.position = CGPoint(
            x: center.x + radiusX * cos(phase * 2 * .pi),
            y: center.y + radiusY * sin(phase * 2 * .pi)
        )
        CATransaction.commit()
        iconLayer.add(animation, forKey: "portalOrbit")
    }

    private func makeIconLayer(for portal: PortalDefinition) -> CALayer {
        let iconLayer = CALayer()
        iconLayer.name = portal.id.uuidString
        iconLayer.bounds = CGRect(x: 0, y: 0, width: Self.iconSize, height: Self.iconSize)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        iconLayer.opacity = 1
        return iconLayer
    }

    private func updateIconLayer(
        _ iconLayer: CALayer,
        for portal: PortalDefinition,
        size: CGFloat
    ) {
        let tint = NSColor(portal.tint)
        let glow = NSColor(portal.glow)
        iconLayer.contents = renderedSymbol(named: portal.symbolName, color: tint, size: size)
        iconLayer.shadowColor = glow.cgColor
        iconLayer.shadowOpacity = 0.35
        iconLayer.shadowRadius = 8
        iconLayer.shadowOffset = .zero
    }

    private func renderedSymbol(named name: String, color: NSColor, size: CGFloat) -> CGImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func updateSelectedAppearance() {
        guard !isSelecting, let iconLayer = iconLayers[selectedPortalID] else { return }
        let rotation = CGFloat(selectedRotationAngle * .pi / 180)
        let transform = CGAffineTransform(rotationAngle: rotation)
            .scaledBy(x: selectedScale, y: selectedScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.setAffineTransform(transform)
        iconLayer.shadowOpacity = Float(selectedGlowIntensity)
        iconLayer.shadowRadius = 20
        CATransaction.commit()
    }

    private func animateSpawn(_ iconLayer: CALayer) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.1, 1.15, 1]
        scale.keyTimes = [0, 0.75, 1]
        scale.duration = 0.55
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        iconLayer.add(scale, forKey: "portalSpawnScale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = iconLayer.opacity
        fade.duration = 0.35
        iconLayer.add(fade, forKey: "portalSpawnFade")
    }
}

struct PortalView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var isHovering = false
    @State private var isCopying = false
    @State private var glowIntensity = 0.1
    @State private var scale = 1.0
    
    // Colors for hover states
    private let forestGreen = Color(red: 0.424, green: 0.627, blue: 0.329)  // #6CA054
    private let burntOrange = Color(red: 0.82, green: 0.412, blue: 0.118)   // #D16A1E

    // New timer-based rotation states
    @State private var rotationAngle: Double = 0
    @State private var isRotating: Bool = false
    @State private var timerSubscription: AnyCancellable?
    private let timerPublisher = Timer.publish(every: 1/60, on: .main, in: .common)
    @State private var rotationSpeed: Double = 18.0 // 360 degrees / 20 seconds
    
    @State private var showingCodeInput = false
    @State private var code = ""
    @State private var isCodeValid = false
    @State private var isReceiveHovered = false
    @State private var isCancelHovered = false
    @State private var isCodeHovered = false
    @FocusState private var isCodeInputFocused: Bool
    
    private func startRotation() {
        guard !scale.isNaN && !rotationSpeed.isNaN else {
            print("⚠️ Invalid rotation values detected, resetting")
            scale = 1.0
            rotationSpeed = 18.0
            return
        }
        isRotating = true
        if timerSubscription == nil {
            timerSubscription = timerPublisher.connect() as? AnyCancellable
        }
    }

    private func pauseRotation() {
        isRotating = false
    }

    private func stopTimer() {
        timerSubscription?.cancel()
        timerSubscription = nil
    }
    
    private func resetPortal() {
        withAnimation(.spring(duration: 0.3)) {
            scale = 1.0
            glowIntensity = 0.1
            rotationSpeed = 18.0
            showingCodeInput = false
            code = ""
            isCodeValid = false
        }
        // Resume ambient sound and rotation if we're going back to idle state
        if appDelegate.transferState == .idle {
            SoundManager.shared.playAmbientSound()
            SoundManager.shared.playPortalOpen()
            // Ensure valid values before starting rotation
            if scale.isNaN { scale = 1.0 }
            if rotationSpeed.isNaN { rotationSpeed = 18.0 }
            if rotationAngle.isNaN { rotationAngle = 0 }
            startRotation()
        }
    }
    
    private func validateCode(_ code: String) -> Bool {
        let pattern = /^\d+-[a-z]+-[a-z]+$/
        return code.matches(of: pattern).count == 1
    }
    
    private func openDownloads() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { (urlData, error) in
            guard let urlData = urlData as? Data,
                  let path = String(data: urlData, encoding: .utf8),
                  let url = URL(string: path) else { return }

            // The portal the file was dropped on: a set modifier may be released
            // before the send starts.
            let portal = appDelegate.selectedPortal

            withAnimation(.easeIn(duration: 0.5)) {
                scale = 0.01
                rotationSpeed = 120.0
            }

            SoundManager.shared.playSend()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pauseRotation()
                switch portal.kind {
                case .wormhole:
                    appDelegate.send(with: url.path)
                case .command(let config):
                    appDelegate.runCommandPortal(config, path: url.path)
                }
            }
        }
        return true
    }

    var body: some View {
        Group {
            if appDelegate.panelMode == .compact {
                compactBody
            } else {
                fullBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isHovering, perform: handleDrop)
        .onChange(of: isHovering) { _, newValue in
            appDelegate.modifierTracker.setDragHover(newValue)
        }
    }

    /// MacHUD `panel mode compact`: the selected portal alone, on HUD glass.
    private var compactBody: some View {
        let portal = appDelegate.selectedPortal
        return ZStack {
            Image(systemName: portal.symbolName)
                .font(.system(size: 40))
                .foregroundStyle(portal.tint)
                .shadow(color: portal.glow.opacity(isHovering ? 0.9 : 0.5), radius: isHovering ? 10 : 5)
                .scaleEffect(isHovering ? 1.1 : 1.0)
                .animation(.spring(duration: 0.3), value: isHovering)
            if appDelegate.transferState == .pending || appDelegate.transferState == .transferring {
                Circle()
                    .trim(from: 0, to: appDelegate.transferState == .transferring ? max(0.02, appDelegate.progress / 100) : 0.15)
                    .stroke(portal.glow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(4)
            } else if appDelegate.transferState == .success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                    .offset(x: 22, y: 22)
            }
        }
        .frame(width: 72, height: 72)
        .hudGlass(HUDGlassView.Style(cornerRadius: 36, borderWidth: 1, borderAlpha: 0.2))
        .help("\(portal.name) (\(appDelegate.activeSet.name))")
    }

    private var fullBody: some View {
        VStack {
            if let error = appDelegate.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .appFont(.small)
                    .padding()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            switch appDelegate.transferState {
            case .idle:
                if showingCodeInput {
                    VStack(spacing: 8) {
                        TextField("enter code", text: $code)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                            .multilineTextAlignment(.center)
                            .frame(width: 150)
                            .focused($isCodeInputFocused)
                            .onSubmit {
                                if isCodeValid {
                                    let cleanedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                                    appDelegate.receive(code: cleanedCode)
                                }
                            }
                            .onChange(of: code) { _, newValue in
                                isCodeValid = validateCode(newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                        
                        if isCodeValid {
                            Button("receive") {
                                let cleanedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                                appDelegate.receive(code: cleanedCode)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(isReceiveHovered ? forestGreen : .primary)
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isReceiveHovered = hovering
                                }
                            }
                        }
                        
                        Button("cancel") {
                            resetPortal()
                        }
                        .buttonStyle(.borderless)
                        .appFont(.small)
                        .foregroundColor(isCancelHovered ? burntOrange : .primary)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isCancelHovered = hovering
                            }
                        }
                    }
                    .onAppear {
                        isCodeInputFocused = true
                        pauseRotation()
                        // Stop ambient while showing code input
                        SoundManager.shared.stopAmbientSound()
                    }
                } else {
                    ZStack {
                        PortalSatelliteView(
                            portals: appDelegate.activePortals,
                            selectedPortalID: appDelegate.selectedPortalID,
                            selectedScale: scale,
                            selectedRotationAngle: rotationAngle,
                            selectedGlowIntensity: glowIntensity,
                            onSelectionStarted: {
                                pauseRotation()
                                rotationAngle = 0
                            },
                            onSelect: { id in
                                guard appDelegate.activePortals.contains(where: { $0.id == id }) else {
                                    startRotation()
                                    return
                                }
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    appDelegate.selectedPortalID = id
                                }
                                startRotation()
                            }
                        )
                        .frame(width: portalWindowSize.width, height: portalWindowSize.height)

                        let portal = appDelegate.selectedPortal
                        Circle()
                            .fill(Color.white.opacity(0.001))
                            .frame(width: 96, height: 96)
                            .onTapGesture {
                                if portal.isWormhole {
                                    SoundManager.shared.playPortalClose()
                                    withAnimation {
                                        showingCodeInput = true
                                    }
                                }
                            }
                            .onDrop(of: [.fileURL], isTargeted: $isHovering, perform: handleDrop)
                            .zIndex(1)
                    }
                    .onAppear {
                        resetPortal()
                    }
                }
                
            case .pending:
                VStack(spacing: 4) {
                    Text(appDelegate.currentJob == .command
                         ? appDelegate.portalMessage ?? "working..."
                         : "waiting for peer...")
                        .foregroundColor(.secondary)
                        .appFont(.small)
                        .fixedSize(horizontal: true, vertical: true)

                    if let code = appDelegate.wormholeCode {
                        Text("receive code:")
                            .appFont(.tiny)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: true, vertical: true)
                        Text("\(code)")
                            .appFont(.small)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: true, vertical: true)
                            .onTapGesture {
                                appDelegate.copyToClipboard(code)
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isCopying = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    withAnimation {
                                        isCopying = false
                                    }
                                }
                            }
                            .foregroundColor(isCopying ? .green : (isCodeHovered ? forestGreen : .secondary))
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isCodeHovered = hovering
                                }
                            }
                        Text("(copied to clipboard)")
                            .appFont(.tiny)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    
                    Button("cancel") {
                        switch appDelegate.currentJob {
                        case .send: appDelegate.cleanupSendProcess(immediate: true)
                        case .receive: appDelegate.cleanupReceiveProcess(immediate: true)
                        case .command, .none: break
                        }
                        appDelegate.transferState = .idle
                    }
                    .buttonStyle(.borderless)
                    .appFont(.small)
                    .foregroundColor(isCancelHovered ? burntOrange : .primary)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isCancelHovered = hovering
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(.top, 8)
                
            case .transferring:
                VStack(spacing: 8) {
                    ProgressView(appDelegate.currentJob == .receive ? "receiving..." : "sending...", 
                               value: appDelegate.progress, total: 100)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 120)
                    Text("\(Int(appDelegate.progress))%")
                        .appFont(.small)
                        .foregroundColor(.secondary)
                    if let fileName = appDelegate.fileName {
                        Text(fileName)
                            .appFont(.tiny)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
            case .success:
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 50))

                    if appDelegate.currentJob == .command, let msg = appDelegate.portalMessage {
                        Text(msg)
                            .appFont(.small)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    } else if appDelegate.currentJob == .receive {
                        Button("Open Downloads") {
                            openDownloads()
                        }
                        .buttonStyle(.borderless)
                        .appFont(.small)
                        .padding(.top, 4)
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        appDelegate.transferState = .idle
                    }
                }
                
            case .failed:
                Button("Try Again") {
                    appDelegate.transferState = .idle
                    appDelegate.errorMessage = nil
                }
                .buttonStyle(.borderless)
                .appFont(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FrostCloud())
        .contentShape(Rectangle())
        .appFont()
        .onChange(of: isHovering) { _, newValue in
            if appDelegate.transferState == .idle && !showingCodeInput {
                withAnimation {
                    glowIntensity = newValue ? 0.5 : 0.0
                    scale = newValue ? 1.1 : 1.0
                    rotationSpeed = newValue ? 30.0 : 18.0
                }
                
                SoundManager.shared.playHover(pitchUp: newValue)
            }
        }
        .onChange(of: appDelegate.transferState) { _, newState in
            if newState == .idle {
                print("new state idle")
                appDelegate.portalMessage = nil
                resetPortal()
            } else if newState == .success && appDelegate.currentJob == .receive {
                // Play receive sound when file is received
                SoundManager.shared.playReceive()
            }
        }
        .onReceive(timerPublisher) { _ in
            if isRotating && !rotationSpeed.isNaN && !rotationAngle.isNaN {
                rotationAngle += rotationSpeed / 60
                if rotationAngle >= 360 {
                    rotationAngle -= 360
                }
            }
        }
        .onDisappear {
            stopTimer()
        }
    }
}

// MARK: - Portal settings editor

struct PortalSettingsView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var selection: UUID?
    @State private var editingSetID: String = PortalSet.defaultID
    @State private var setNamePrompt: SetNamePrompt?
    @State private var setNameDraft = ""
    @State private var errorText: String?

    private enum SetNamePrompt: Identifiable {
        case create, rename
        var id: Int { self == .create ? 0 : 1 }
    }

    private var library: PortalLibrary { appDelegate.library }
    private var editingSet: PortalSet { library.set(id: editingSetID) ?? library.defaultSet }
    private var setPortals: [PortalDefinition] { library.portals(in: editingSet) }
    private var otherPortals: [PortalDefinition] { library.portals.filter { !editingSet.contains($0.id) } }

    private var selectedPortal: PortalDefinition? {
        selection.flatMap { id in library.portals.first { $0.id == id } }
    }

    private var canRemoveSelected: Bool { selectedPortal.map { !$0.isWormhole } ?? false }

    private var canRemoveSelectedFromSet: Bool {
        guard let portal = selectedPortal else { return false }
        return !portal.isWormhole && editingSet.contains(portal.id)
    }

    /// Applies a library edit; errors are shown and leave the library unchanged.
    private func edit(_ body: (inout PortalLibrary) throws -> Void) {
        var copy = appDelegate.library
        do {
            try body(&copy)
            appDelegate.library = copy
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setLabel(_ set: PortalSet) -> String {
        set.modifier.map { "\(set.name)  \($0.symbol)" } ?? set.name
    }

    var body: some View {
        NavigationSplitView(sidebar: {
            VStack(spacing: 0) {
                setBar
                List(selection: $selection) {
                    Section("portals in \(editingSet.name)") {
                        ForEach(setPortals) { portal in
                            portalRow(portal)
                                .tag(portal.id)
                                .contextMenu {
                                    Button("Remove from \(editingSet.name)") { removeFromSet(portal.id) }
                                        .disabled(portal.isWormhole)
                                }
                        }
                        .onMove { source, destination in
                            edit { $0.moveInSet(editingSet.id, fromOffsets: source, toOffset: destination) }
                        }
                    }
                    if !otherPortals.isEmpty {
                        Section("not in this set") {
                            ForEach(otherPortals) { portal in
                                HStack {
                                    portalRow(portal).opacity(0.6)
                                    Spacer()
                                    Button {
                                        edit { try $0.addPortal(portal.id, toSet: editingSet.id) }
                                    } label: {
                                        Image(systemName: "plus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Add to \(editingSet.name)")
                                }
                                .tag(portal.id)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    Button(action: addPortal) {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("New portal")
                    Button(action: removeSelected) {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .help("Delete portal")
                    .disabled(!canRemoveSelected)
                    Spacer()
                    Button {
                        if let id = selection { removeFromSet(id) }
                    } label: {
                        Image(systemName: "rectangle.stack.badge.minus").frame(width: 24, height: 20)
                    }
                    .help("Remove from \(editingSet.name) (keeps the portal)")
                    .disabled(!canRemoveSelectedFromSet)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.bar)
            }
        }, detail: {
            if let id = selection, let binding = binding(for: id) {
                PortalEditor(portal: binding)
                    .id(id)
            } else {
                Text("select a portal")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        })
        .frame(minWidth: 680, minHeight: 460)
        .onAppear {
            if selection == nil {
                selection = appDelegate.selectedPortalID
            }
            editingSetID = appDelegate.activeSet.id
        }
        .alert(setNamePrompt == .rename ? "Rename Set" : "New Set", isPresented: Binding(
            get: { setNamePrompt != nil },
            set: { if !$0 { setNamePrompt = nil } }
        )) {
            TextField("name", text: $setNameDraft)
            Button(setNamePrompt == .rename ? "Rename" : "Create") { commitSetName() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Can't do that", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var setBar: some View {
        HStack(spacing: 6) {
            Picker("set", selection: $editingSetID) {
                ForEach(library.sets) { set in
                    Text(setLabel(set)).tag(set.id)
                }
            }
            .labelsHidden()
            Menu {
                Button("New Set…") {
                    setNameDraft = ""
                    setNamePrompt = .create
                }
                Button("Rename “\(editingSet.name)”…") {
                    setNameDraft = editingSet.name
                    setNamePrompt = .rename
                }
                Picker("Modifier", selection: Binding(
                    get: { editingSet.modifier },
                    set: { modifier in edit { try $0.setModifier(editingSet.id, modifier) } }
                )) {
                    Text("none").tag(PortalSetModifier?.none)
                    ForEach(PortalSetModifier.allCases, id: \.self) { m in
                        Text("\(m.symbol) \(m.rawValue)").tag(PortalSetModifier?.some(m))
                    }
                }
                .disabled(editingSet.isDefault)
                Button("Show This Set") { _ = try? appDelegate.selectBaseSet(editingSet.id) }
                    .disabled(appDelegate.baseSetID == editingSet.id)
                Divider()
                Button("Delete “\(editingSet.name)”", role: .destructive) {
                    let id = editingSet.id
                    edit { try $0.deleteSet(id) }
                    editingSetID = PortalSet.defaultID
                }
                .disabled(editingSet.isDefault)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help(editingSet.isDefault
              ? "The default set shows when no set modifier is held."
              : "Hold \(editingSet.modifier?.rawValue ?? "its modifier") with the portal focused to show this set.")
    }

    private func portalRow(_ portal: PortalDefinition) -> some View {
        Label(portal.name, systemImage: portal.symbolName)
            .foregroundStyle(portal.tint)
    }

    private func commitSetName() {
        let name = setNameDraft
        switch setNamePrompt {
        case .create:
            var created: PortalSet?
            edit { created = try $0.createSet(name: name) }
            if let created { editingSetID = created.id }
        case .rename:
            let id = editingSet.id
            edit { try $0.renameSet(id, to: name) }
        case nil:
            break
        }
        setNamePrompt = nil
    }

    private func removeFromSet(_ id: UUID) {
        let setID = editingSet.id
        edit { try $0.removePortal(id, fromSet: setID) }
    }

    private func binding(for id: UUID) -> Binding<PortalDefinition>? {
        guard appDelegate.portals.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { appDelegate.portals.first(where: { $0.id == id }) ?? .wormhole },
            set: { newValue in appDelegate.library.updatePortal(newValue) }
        )
    }

    /// New portals join the library, the default set, and the set being edited.
    private func addPortal() {
        let portal = PortalDefinition.newCommandPortal(name: uniquePortalName("new portal"))
        let setID = editingSet.id
        edit { $0.addPortal(portal, toSets: [setID]) }
        selection = portal.id
    }

    private func uniquePortalName(_ base: String) -> String {
        let taken = Set(appDelegate.portals.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var i = 2
        while taken.contains("\(base) \(i)".lowercased()) { i += 1 }
        return "\(base) \(i)"
    }

    /// Deletes the portal from the library and every set.
    private func removeSelected() {
        guard let portal = selectedPortal, !portal.isWormhole else { return }
        edit { $0.removePortal(id: portal.id) }
        selection = setPortals.first?.id
    }
}

struct PortalEditor: View {
    @Binding var portal: PortalDefinition

    private let symbolSuggestions = [
        "line.3.crossed.swirl.circle.fill", "photo.circle.fill", "face.dashed.fill",
        "paperplane.circle.fill", "folder.circle.fill", "arrow.up.circle.fill",
        "trash.circle.fill", "bolt.circle.fill", "cloud.circle.fill",
        "star.circle.fill", "doc.circle.fill", "tray.circle.fill"
    ]

    private var currentConfig: CommandPortalConfig? { portal.commandConfig }

    private func updateConfig(_ mutate: (inout CommandPortalConfig) -> Void) {
        guard var c = portal.commandConfig else { return }
        mutate(&c)
        portal.kind = .command(c)
    }

    private var tintBinding: Binding<Color> {
        Binding(get: { portal.tint }, set: { portal.tintHex = $0.hexString })
    }
    private var glowBinding: Binding<Color> {
        Binding(get: { portal.glow }, set: { portal.glowHex = $0.hexString })
    }

    var body: some View {
        Form {
            Section("appearance") {
                TextField("name", text: $portal.name)

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: portal.symbolName.isEmpty ? "questionmark.circle" : portal.symbolName)
                        .font(.system(size: 36))
                        .foregroundStyle(portal.tint)
                        .frame(width: 44, height: 44)
                    TextField("SF Symbol name", text: $portal.symbolName)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(symbolSuggestions, id: \.self) { name in
                            Button {
                                portal.symbolName = name
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 20))
                                    .foregroundStyle(name == portal.symbolName ? portal.tint : .secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 2)
                }

                ColorPicker("tint", selection: tintBinding, supportsOpacity: false)
                ColorPicker("glow", selection: glowBinding, supportsOpacity: false)
            }

            if portal.isWormhole {
                Section {
                    Text("the built-in wormhole portal sends & receives files via magic-wormhole. its behavior isn't editable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if currentConfig != nil {
                Section("command") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("shell command — runs on drop")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: Binding(
                            get: { currentConfig?.commandTemplate ?? "" },
                            set: { v in updateConfig { $0.commandTemplate = v } }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        Text("tokens: \(PortalToken.path), \(PortalToken.filename), \(PortalToken.dir) — put them inside double quotes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("run in login shell (zsh -l)", isOn: Binding(
                        get: { currentConfig?.runInLoginShell ?? true },
                        set: { v in updateConfig { $0.runInLoginShell = v } }
                    ))

                    TextField("working directory (optional)", text: Binding(
                        get: { currentConfig?.workingDirectory ?? "" },
                        set: { v in updateConfig { $0.workingDirectory = v.isEmpty ? nil : v } }
                    ))
                }

                Section("status text") {
                    TextField("pending verb (e.g. syncing)", text: Binding(
                        get: { currentConfig?.pendingVerb ?? "" },
                        set: { v in updateConfig { $0.pendingVerb = v } }
                    ))
                    TextField("success label (supports \(PortalToken.filename))", text: Binding(
                        get: { currentConfig?.successLabel ?? "" },
                        set: { v in updateConfig { $0.successLabel = v } }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
