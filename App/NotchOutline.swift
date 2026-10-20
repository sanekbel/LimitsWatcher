import AppKit
import SwiftUI
import Combine

/// A thin line hugging the MacBook notch, drawn from its top-left corner around the bottom to the top-right,
/// as long as the first limit of the first provider in the list is full.
/// Hovering the notch unfolds an "island" below it with every provider's cards.
@MainActor
final class NotchOutlineController {
    private let state = NotchOutlineState()
    private var panel: NotchPanel?
    private var bag = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    /// Polls the pointer while the island is open: once it is open the panel takes the mouse,
    /// so the global monitor no longer sees the moves.
    private var exitTimer: Timer?

    init(model: AppModel, settings: AppSettings) {
        model.$usages
            .combineLatest(settings.$showNotchOutline)
            .receive(on: RunLoop.main)
            .sink { [weak self] usages, enabled in self?.update(usages: usages, enabled: enabled) }
            .store(in: &bag)

        model.$lastRefresh
            .receive(on: RunLoop.main)
            .sink { [weak self] date in self?.state.lastRefresh = date }
            .store(in: &bag)

        // External displays, lid closed / opened, resolution changes.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &bag)

        // Mouse moves don't need the Accessibility permission (only key events do).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// The built-in display, if it has a notch.
    static var notchScreen: NSScreen? {
        NSScreen.screens.first {
            $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        }
    }

    private func update(usages: [ProviderUsage], enabled: Bool) {
        state.usages = usages
        let percent = usages.lazy.compactMap { $0.windows.first { $0.usedPercent != nil }?.usedPercent }.first
        guard enabled, let percent else {
            state.visible = false
            collapse()
            panel?.orderOut(nil)
            return
        }
        state.percent = percent
        state.visible = true
        layout()
    }

    // MARK: Geometry (global screen coordinates, origin bottom-left)

    /// The notch itself plus the outline margin.
    private var notchZone: NSRect? {
        guard let screen = Self.notchScreen, let left = screen.auxiliaryTopLeftArea else { return nil }
        let margin = NotchOutlineView.margin
        let size = state.notchSize
        return NSRect(
            x: screen.frame.minX + left.width - margin,
            y: screen.frame.maxY - size.height - margin,
            width: size.width + 2 * margin,
            height: size.height + margin
        )
    }

    /// Where the open island is, with a little slack so the pointer can wobble at its edge.
    private var islandZone: NSRect? {
        guard let notch = notchZone, state.islandSize != .zero else { return notchZone }
        let size = state.islandSize
        let island = NSRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height)
        return island.union(notch).insetBy(dx: -8, dy: -8)
    }

    private func layout() {
        guard state.visible, let screen = Self.notchScreen,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else {
            panel?.orderOut(nil)
            return
        }

        let frame = screen.frame
        let height = screen.safeAreaInsets.top
        let notchWidth = frame.width - left.width - right.width
        state.notchSize = CGSize(width: notchWidth, height: height)

        // Always as big as the open island (plus room for its shadow); the transparent rest lets clicks through
        // while the island is closed.
        let width = max(notchWidth + 2 * NotchOutlineView.margin, NotchOutlineView.islandWidth + 60)
        let panelHeight = min(640, frame.height - 120)
        let rect = NSRect(
            x: frame.minX + left.width + notchWidth / 2 - width / 2,
            y: frame.maxY - panelHeight,
            width: width,
            height: panelHeight
        )

        let panel = self.panel ?? makePanel()
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the menu bar, so the line stays visible around the notch.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchOutlineView(state: state))
        self.panel = panel
        return panel
    }

    // MARK: Hover

    private func pointerMoved() {
        guard state.visible, !state.expanded, let zone = notchZone else { return }
        guard zone.contains(NSEvent.mouseLocation) else {
            hoverTask?.cancel()
            hoverTask = nil
            return
        }
        guard hoverTask == nil else { return }
        // A short pause, so sweeping the pointer across the menu bar doesn't pop the island open.
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.hoverTask = nil
            if let zone = self.notchZone, zone.contains(NSEvent.mouseLocation) { self.expand() }
        }
    }

    private func expand() {
        guard state.visible, !state.expanded else { return }
        state.expanded = true
        panel?.ignoresMouseEvents = false
        exitTimer?.invalidate()
        exitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let zone = self.islandZone, !zone.contains(NSEvent.mouseLocation) { self.collapse() }
            }
        }
    }

    private func collapse() {
        exitTimer?.invalidate()
        exitTimer = nil
        guard state.expanded else { return }
        state.expanded = false
        state.islandSize = .zero
        panel?.ignoresMouseEvents = true
    }
}

/// Borderless panels still get pushed below the menu bar by default; this one has to sit in it.
private final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchOutlineState: ObservableObject {
    @Published var percent: Double = 0
    @Published var notchSize: CGSize = .zero
    @Published var usages: [ProviderUsage] = []
    @Published var lastRefresh: Date?
    @Published var expanded = false
    var islandSize: CGSize = .zero
    var visible = false
}

struct NotchOutlineView: View {
    /// Room around the notch for the stroke and its black border.
    static let margin: CGFloat = 9
    static let lineWidth: CGFloat = 4
    /// Black border on each side of the line, so it reads on a light menu bar too.
    static let border: CGFloat = 2
    static let islandWidth: CGFloat = 380

    @ObservedObject var state: NotchOutlineState

    var body: some View {
        ZStack(alignment: .top) {
            if state.expanded {
                NotchIsland(state: state)
                    .transition(.scale(scale: 0.3, anchor: .top).combined(with: .opacity))
            } else {
                outline
                    .frame(width: state.notchSize.width + 2 * Self.margin, height: state.notchSize.height + Self.margin)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: state.expanded)
        .environment(\.locale, Loc.locale)
    }

    private var outline: some View {
        let shape = NotchShape(notch: state.notchSize, margin: Self.margin, offset: Self.lineWidth / 2 + 0.5)
        let style = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
        return ZStack {
            // Full-length black band: its inner half merges with the notch, the outer half frames the line.
            shape.stroke(Color.black, style: StrokeStyle(lineWidth: Self.lineWidth + 2 * Self.border, lineCap: .round, lineJoin: .round))
            shape.stroke(Color.white.opacity(0.18), style: style)
            shape
                .trim(from: 0, to: min(max(state.percent, 0), 100) / 100)
                .stroke(Palette.color(for: state.percent), style: style)
        }
        .animation(.easeInOut(duration: 0.6), value: state.percent)
    }
}

/// The open state: a black panel growing out of the notch with the same cards as the popover.
private struct NotchIsland: View {
    @ObservedObject var state: NotchOutlineState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(state.usages) { usage in
                ProviderCard(usage: usage)
            }
            if let date = state.lastRefresh {
                Text("\(L("обновлено", "updated")) \(date, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, state.notchSize.height + 10)
        .padding(.bottom, 16)
        .frame(width: NotchOutlineView.islandWidth, alignment: .leading)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        )
        .environment(\.colorScheme, .dark)
        .background(GeometryReader { geo in
            Color.clear.preference(key: IslandSizeKey.self, value: geo.size)
        })
        .onPreferenceChange(IslandSizeKey.self) { size in
            state.islandSize = size
        }
    }
}

private struct IslandSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The notch outline, open at the top edge of the screen, pushed `offset` points outside the notch.
private struct NotchShape: Shape {
    let notch: CGSize
    let margin: CGFloat
    let offset: CGFloat
    /// Bottom corner radius of the MacBook notch, approximately.
    let cornerRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let x0 = margin - offset
        let x1 = margin + notch.width + offset
        let y1 = notch.height + offset
        let r = cornerRadius + offset

        var p = Path()
        p.move(to: CGPoint(x: x0, y: 0))
        p.addLine(to: CGPoint(x: x0, y: y1 - r))
        p.addArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: x1 - r, y: y1))
        p.addArc(center: CGPoint(x: x1 - r, y: y1 - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: x1, y: 0))
        return p
    }
}
