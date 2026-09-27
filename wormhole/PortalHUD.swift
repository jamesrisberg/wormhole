import AppKit
import Combine
import HUDKit

/// The MacHUD contract for Wormhole: one panel, `portal`, served over
/// `HUDSocket.path(for: "wormhole")` by `HUDControlRouter`.
///
/// - `panel show/hide/toggle id=portal` — the portal window.
/// - `panel frame id=portal x y w h` — sets the window frame (AppKit coordinates).
/// - `panel mode id=portal full|compact|parked` — `parked` slides the window off the
///   nearest screen edge leaving a sliver; `compact` is a 72 pt selected-portal button.
/// - `state` — visibility, mode, `badge` "1" while a transfer is in flight, `status`.
/// - `action select-set name=<set>`, `action send path=<file>` (replies with the code).
/// - `settings get/set` — `activeSet`, `hotkey`.
@MainActor
final class PortalHUDController: HUDPanelHost {
    static let panelID = "portal"
    nonisolated static let socketName = "wormhole"
    /// Points left on screen when parked.
    static let parkPeek: CGFloat = 12
    static let compactSize = CGSize(width: 72, height: 72)

    private unowned let app: AppDelegate
    let server: HUDSocketServer
    private var router: HUDControlRouter!
    /// The full-mode frame to return to while parked or compact.
    private var restFrame: CGRect?
    /// Edge and peek MacHUD asked for with `panel mode parked` (nil: nearest edge, default peek).
    private var parkEdge: HUDEdge?
    private var parkPeekOverride: CGFloat?
    private var peek: CGFloat { parkPeekOverride ?? Self.parkPeek }
    private var animations = 0
    private var lastPublished: HUDPanelState?
    private var cancellables: Set<AnyCancellable> = []

    var isAnimating: Bool { animations > 0 }

    init(app: AppDelegate, socketPath: String = HUDSocket.path(for: PortalHUDController.socketName)) {
        self.app = app
        server = HUDSocketServer(path: socketPath, label: "wormhole.hud")
        router = HUDControlRouter(host: self, server: server, manifest: HUDManifest.main)
    }

    func start() {
        router.install()
        if !server.start() { print("❌ HUD socket failed to start at \(server.path)") }
        app.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publishIfChanged() }
            .store(in: &cancellables)
    }

    /// Pushes a `state` event when the panel's state differs from the last one pushed.
    func publishIfChanged() {
        let current = state
        guard current != lastPublished else { return }
        lastPublished = current
        router.publishState()
    }

    // MARK: - State

    private var window: NSWindow? { app.portalWindow }

    var state: HUDPanelState {
        HUDPanelState(
            id: Self.panelID,
            visible: window?.isVisible ?? false,
            mode: app.panelMode,
            badge: transferInFlight ? "1" : nil,
            status: status
        )
    }

    private var transferInFlight: Bool {
        app.transferState == .pending || app.transferState == .transferring
    }

    private var status: String {
        let job: String
        switch app.currentJob {
        case .send: job = "sending"
        case .receive: job = "receiving"
        case .command, .none: job = app.portalMessage ?? "working"
        }
        switch app.transferState {
        case .idle: return "idle, set \(app.activeSet.name)"
        case .pending: return app.currentJob == .command ? job : "waiting for peer"
        case .transferring: return "\(job) \(Int(app.progress))%"
        case .success: return "done"
        case .failed: return "failed: \(app.errorMessage ?? "error")"
        }
    }

    var panelStates: [HUDPanelState] { [state] }

    // MARK: - Panel verbs

    func showPanel(_ id: String) throws {
        // The router publishes after panel verbs; don't repeat it from the change sink.
        defer { lastPublished = state }
        if app.panelMode == .parked { try setPanelMode(id, mode: .full) }
        app.showPortalWindow()
    }

    func hidePanel(_ id: String) throws {
        // The router publishes after panel verbs; don't repeat it from the change sink.
        defer { lastPublished = state }
        // Hidden is always hidden at the full-size frame, so the next show is normal.
        if app.panelMode != .full, let window, let restFrame {
            app.panelMode = .full
            window.setFrame(restFrame, display: false)
            self.restFrame = nil
        }
        app.panelMode = .full
        app.closePortalWindow()
    }

    func togglePanel(_ id: String) throws {
        (window?.isVisible ?? false) ? try hidePanel(id) : try showPanel(id)
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        // The router publishes after panel verbs; don't repeat it from the change sink.
        defer { lastPublished = state }
        guard frame.width > 0, frame.height > 0, frame.origin.x.isFinite, frame.origin.y.isFinite else {
            throw HUDControlError.invalid("frame must have a positive size")
        }
        let window = app.ensurePortalWindow()
        switch app.panelMode {
        case .full, .compact:
            window.setFrame(frame, display: true)
        case .parked:
            restFrame = frame
            let screen = HUDParking.screenFrame(for: frame)
            let edge = parkEdge ?? HUDParking.nearestEdge(for: frame, in: screen)
            window.setFrame(HUDParking.offScreenFrame(for: frame, edge: edge, peek: peek, in: screen), display: true)
        }
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode) throws {
        try setPanelMode(id, mode: mode, options: HUDPanelModeOptions())
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        // The router publishes after panel verbs; don't repeat it from the change sink.
        defer { lastPublished = state }
        let current = app.panelMode
        guard mode != current else { return }
        let window = app.ensurePortalWindow()
        let rest = restFrame ?? window.frame
        switch mode {
        case .parked:
            if current == .full { restFrame = window.frame }
            // Park the full-size portal, even when leaving compact.
            window.setFrame(rest, display: false)
            let screen = HUDParking.screenFrame(for: rest)
            parkEdge = options.edge
            parkPeekOverride = options.peek
            let edge = options.edge ?? HUDParking.nearestEdge(for: rest, in: screen)
            app.panelMode = .parked
            if !window.isVisible {
                window.setFrame(HUDParking.offScreenFrame(for: rest, edge: edge, peek: peek, in: screen), display: false)
                window.orderFrontRegardless()
            } else {
                animations += 1
                HUDParking.slideOut(window, edge: edge, peek: peek) { [weak self] in self?.finishAnimation() }
            }
        case .full:
            app.panelMode = .full
            restFrame = nil
            animations += 1
            if current == .parked {
                HUDParking.slideIn(window, to: rest) { [weak self] in self?.finishAnimation() }
            } else {
                HUDAnimation.reveal(window, to: rest) { [weak self] in self?.finishAnimation() }
            }
        case .compact:
            if current == .full { restFrame = window.frame }
            let size = Self.compactSize
            let target = CGRect(x: rest.midX - size.width / 2, y: rest.midY - size.height / 2,
                                width: size.width, height: size.height)
            app.panelMode = .compact
            animations += 1
            if current == .parked {
                window.setFrame(CGRect(origin: window.frame.origin, size: size), display: false)
                HUDParking.slideIn(window, to: HUDParking.restFrame(for: target, in: HUDParking.screenFrame(for: rest))) { [weak self] in
                    self?.finishAnimation()
                }
            } else {
                HUDAnimation.reveal(window, to: target) { [weak self] in self?.finishAnimation() }
            }
        }
    }

    private func finishAnimation() {
        animations = max(0, animations - 1)
        if animations == 0, let window, app.panelMode == .full {
            app.savePortalFrameIfResting(window)
        }
        publishIfChanged()
    }

    // MARK: - Settings

    func settings() -> [String: Any] {
        [
            "activeSet": app.library.set(id: app.baseSetID)?.name ?? app.library.defaultSet.name,
            "sets": app.library.sets.map(\.name),
            "hotkey": AppDelegate.hotKeyString(app.hotKey),
        ]
    }

    func updateSettings(_ values: [String: String]) throws {
        for key in values.keys where key != "activeSet" && key != "hotkey" {
            throw HUDControlError.invalid("unknown setting \(key) (settings: activeSet, hotkey)")
        }
        if let raw = values["hotkey"] {
            guard let hotKey = AppDelegate.parseHotKey(raw) else {
                throw HUDControlError.invalid("hotkey must look like option+control+p")
            }
            guard app.registerHotKey(hotKey) else {
                throw HUDControlError.invalid("could not register \(raw); another app may own it")
            }
        }
        if let name = values["activeSet"] {
            do { try app.selectBaseSet(name) } catch { throw HUDControlError.invalid(error.localizedDescription) }
        }
    }

    // MARK: - Actions

    static let actions = ["select-set", "send"]

    /// Accepts both `{"name": "select-set", "set": "work"}` and the CLI shape
    /// `action select-set name=work`, which the router delivers as name "work" with
    /// a bare `select-set` flag.
    static func resolveAction(_ name: String, args: [String: String]) -> (action: String, args: [String: String]) {
        guard !actions.contains(name), let bare = actions.first(where: { args[$0] == "1" }) else { return (name, args) }
        var rest = args
        rest[bare] = nil
        if bare == "select-set", rest["set"] == nil { rest["set"] = name }
        return (bare, rest)
    }

    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        let (name, args) = Self.resolveAction(name, args: args)
        switch name {
        case "select-set":
            guard let key = args["set"] ?? args["value"] else {
                done(["ok": false, "error": "select-set needs set=<name>"]); return
            }
            do {
                let set = try app.selectBaseSet(key)
                publishIfChanged()
                done(["ok": true, "activeSet": set.name])
            } catch {
                done(["ok": false, "error": error.localizedDescription])
            }
        case "send":
            guard let raw = args["path"], !raw.isEmpty else {
                done(["ok": false, "error": "send needs path=<file>"]); return
            }
            send(path: (raw as NSString).expandingTildeInPath, done: done)
        default:
            done(["ok": false, "error": "unknown action \(name) (actions: select-set, send)"])
        }
    }

    /// Starts a wormhole send and replies once the code is known (or it fails).
    private func send(path: String, done: @escaping ([String: Any]) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else {
            done(["ok": false, "error": "no such file \(path)"]); return
        }
        guard app.transferState == .idle else {
            done(["ok": false, "error": "busy: a transfer is in progress"]); return
        }
        if !(window?.isVisible ?? false) || app.panelMode == .parked { try? showPanel(Self.panelID) }
        app.send(with: path)

        var finished = false
        var watch: AnyCancellable?
        let finish: ([String: Any]) -> Void = { response in
            guard !finished else { return }
            finished = true
            watch?.cancel()
            done(response)
        }
        watch = app.$wormholeCode.combineLatest(app.$transferState)
            .receive(on: RunLoop.main)
            .sink { [weak self] code, state in
                if let code { finish(["ok": true, "code": code]) }
                else if state == .failed { finish(["ok": false, "error": self?.app.errorMessage ?? "send failed"]) }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            finish(["ok": true, "code": NSNull(), "status": "pending"])
        }
    }
}
