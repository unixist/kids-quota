import AppKit
import SwiftUI
import KidsQuotaService

/// This view has no administrative token and no configuration operations.
@MainActor
final class ChildStatusModel: ObservableObject {
    @Published private(set) var state: ChildStatusDisplayState = .loading
    @Published private(set) var refreshing = false
    private let queue = DispatchQueue(label: "com.kidsquota.agent.balances", qos: .utility)
    private let socket: String
    private let development: Bool
    private var generation = 0
    private var timer: Timer?
    private var preview = false

    init(socket: String, development: Bool) { self.socket = socket; self.development = development }

    func open() {
        guard !preview else { return }
        state = .loading
        refresh()
        timer?.invalidate()
        // A dedicated connection and queue keep UI reads out of metering's path.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func close() {
        guard !preview else { return }
        timer?.invalidate(); timer = nil
        generation += 1; refreshing = false; state = .loading
    }
    func refresh() {
        guard !refreshing, !preview else { return }
        refreshing = true
        let requestGeneration = generation, socket = socket, development = development
        queue.async { [weak self] in
            let result = try? SocketIO.request(["op": "childStatus"], path: socket, development: development)
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration else { return }
                self.state.accept(result)
                self.refreshing = false
            }
        }
    }
    #if DEBUG
    func showPreview() {
        preview = true
        state.accept([
            "type": "childStatus", "configured": true, "childName": "Alex", "resetTimeZone": "America/Chicago",
            "items": [
                ["serviceId": "chesscom", "name": "Chess.com", "domains": [["hostname": "chess.com", "includeSubdomains": true]], "weeklyLimitSeconds": 21600, "usedSeconds": 5220, "remainingSeconds": 16380, "resetAt": "2026-11-02T06:00:00Z", "coverage": "complete"],
                ["serviceId": "chatgpt", "name": "ChatGPT", "domains": [["hostname": "chatgpt.com", "includeSubdomains": true], ["hostname": "chat.openai.com", "includeSubdomains": true]], "weeklyLimitSeconds": 21600, "usedSeconds": 21600, "remainingSeconds": 0, "resetAt": "2026-11-02T06:00:00Z", "coverage": "incomplete"]
            ]
        ])
    }
    #endif
}

struct ChildStatusView: View {
    @ObservedObject var model: ChildStatusModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "hourglass").font(.title2).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your time").font(.title3.weight(.semibold))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.refreshing)
                    .help("Refresh remaining time")
                    .accessibilityLabel("Refresh remaining time")
            }.padding(20)
            Divider()
            content
        }
        .frame(width: 380)
        .background(.background)
    }

    private var subtitle: String {
        if case .ready(let status) = model.state, let name = status.childName { return "\(name)'s weekly allowance" }
        return "Kids Quota"
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            message(icon: "clock", title: "Checking your time…", detail: "Getting your latest balances.")
        case .notConfigured:
            message(icon: "person.crop.circle.badge.questionmark", title: "This account isn't set up yet", detail: "Ask your parent to link this Mac login in Kids Quota.")
        case .unavailable:
            message(icon: "wifi.exclamationmark", title: "Can't check your time right now", detail: "Your balance will appear when Kids Quota reconnects. Ask your parent if this keeps happening.")
        case .ready(let status):
            if status.items.isEmpty {
                message(icon: "list.bullet", title: "No allowances yet", detail: "Your parent can add websites and apps to your weekly allowances.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(status.items) { item in balance(item) }
                    }.padding(16)
                }.frame(height: min(CGFloat(status.items.count) * 140 + 32, 400))
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    if let reset = status.items.first?.resetAt, let zone = status.resetTimeZone {
                        Label("Resets \(ChildStatusPresentation.resetLabel(reset, timeZone: zone))", systemImage: "arrow.clockwise")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Websites and linked apps share each allowance. Only your parent can change limits.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(16)
            }
        }
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(28).frame(minHeight: 210)
    }

    private func balance(_ item: ChildStatusItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(item.remainingSeconds == 0 ? "Time used up" : "\(ChildStatusPresentation.duration(item.remainingSeconds)) left")
                    .font(.headline).monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(item.remainingSeconds == 0 ? Color.secondary : Color.primary)
                    .accessibilityLabel("\(ChildStatusPresentation.accessibleDuration(item.remainingSeconds)) remaining")
            }
            if !item.domains.isEmpty {
                Text(item.domains.map(\.hostname).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Linked apps").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: item.fractionRemaining)
                .tint(item.remainingSeconds == 0 ? .secondary : .accentColor)
                .accessibilityLabel("\(item.name) time remaining")
                .accessibilityValue("\(ChildStatusPresentation.accessibleDuration(item.remainingSeconds)) of \(ChildStatusPresentation.accessibleDuration(item.weeklyLimitSeconds))")
            Text("\(ChildStatusPresentation.duration(item.usedSeconds)) used of \(ChildStatusPresentation.duration(item.weeklyLimitSeconds)) this week")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
final class ChildStatusMenu: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let model: ChildStatusModel

    init(socket: String, development: Bool) {
        model = ChildStatusModel(socket: socket, development: development)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Kids Quota — your remaining time")
            button.toolTip = "Kids Quota — your remaining time"
            button.target = self; button.action = #selector(toggle)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ChildStatusView(model: model))
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        model.open()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { model.close() }

    #if DEBUG
    func previewWindow() -> NSWindow {
        model.showPreview()
        let window = NSWindow(contentViewController: NSHostingController(rootView: ChildStatusView(model: model)))
        window.title = "Kids Quota — Child view preview"
        window.styleMask = [.titled, .closable]
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
    #endif
}
