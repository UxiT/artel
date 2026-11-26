import ArtelCore
import AppKit
import SwiftUI

// Shared visual vocabulary.
// Status is a signal colour (blue / orange / yellow / green / teal / red / gray) and always comes with a symbol.
// A project is a muted, non-status hue on a rounded square with the project's monogram, so it can't be read as a status.

enum ProjectPalette {
    struct Swatch {
        let name: String
        let color: Color
    }

    static let swatches: [Swatch] = [
        Swatch(name: "Purple", color: .purple),
        Swatch(name: "Lilac", color: Color(red: 0.62, green: 0.52, blue: 0.84)),
        Swatch(name: "Indigo", color: .indigo),
        Swatch(name: "Brown", color: .brown),
        Swatch(name: "Plum", color: Color(red: 0.56, green: 0.27, blue: 0.52)),
        Swatch(name: "Olive", color: Color(red: 0.47, green: 0.50, blue: 0.22)),
        Swatch(name: "Graphite", color: Color(red: 0.36, green: 0.40, blue: 0.47)),
        Swatch(name: "Sand", color: Color(red: 0.66, green: 0.58, blue: 0.42)),
    ]

    static var colors: [Color] { swatches.map(\.color) }
    static func index(_ i: Int) -> Int { ((i % swatches.count) + swatches.count) % swatches.count }
    static func color(_ i: Int) -> Color { swatches[index(i)].color }
    static func name(_ i: Int) -> String { swatches[index(i)].name }

    /// A project's marker for menu items: its emoji, else its colour swatch.
    @MainActor static func menuImage(for project: Project, size: CGFloat = 14) -> NSImage {
        guard let icon = project.icon else { return swatchImage(project.colorIndex, size: size - 2) }
        let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: size - 2)])
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = text.size()
            text.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A non-template image for menu items: SF Symbols in NSMenu are templates and lose their colour.
    @MainActor static func swatchImage(_ i: Int, size: CGFloat = 12) -> NSImage {
        let color = NSColor(color(i))
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: size * 0.25, yRadius: size * 0.25).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Project marker: the project's emoji, else a coloured rounded square with the first letter of its name.
struct ProjectBadge: View {
    let project: Project?
    var size: CGFloat = 16

    var body: some View {
        if let icon = project?.icon {
            Text(icon)
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
                .help(project.map { "Project \($0.name)" } ?? "")
        } else {
            letterBadge
        }
    }

    private var letterBadge: some View {
        let name = project?.name ?? "?"
        return RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(ProjectPalette.color(project?.colorIndex ?? 0).gradient)
            .frame(width: size, height: size)
            .overlay {
                if size >= 13 {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
            .help(project.map { "Project \($0.name)" } ?? "")
    }
}

extension TaskStatus {
    var color: Color {
        switch self {
        case .new: .gray
        case .inProgress: .blue
        case .done: .green
        }
    }

    /// Shape differs per status, so it reads without colour.
    var symbol: String {
        switch self {
        case .new: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// Task status as a coloured symbol of its own shape.
struct StatusDot: View {
    let status: TaskStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.caption)
            .foregroundStyle(status.color)
            .accessibilityLabel(status.title)
    }
}

extension SessionActivity {
    var color: Color {
        switch self {
        case .starting: .gray
        case .working: .blue
        case .waitingInput: .orange
        case .waitingPermission: .yellow
        case .ready: .teal
        case .idle: .green
        case .error: .red
        case .exited: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .starting: "hourglass"
        case .working: "bolt.fill"
        case .waitingInput: "questionmark.bubble.fill"
        case .waitingPermission: "hand.raised.fill"
        case .ready: "circle.dashed"
        case .idle: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .exited: "stop.circle"
        }
    }
}

/// Session status: symbol + text on a tinted capsule.
struct ActivityCapsule: View {
    let activity: SessionActivity

    var body: some View {
        Label(activity.title, systemImage: activity.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(activity.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(activity.color.opacity(0.16)))
            .fixedSize()
    }
}

/// Borders of cards and columns: stronger under Increase Contrast.
struct HairlineColor {
    @MainActor static func border(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Color.primary.opacity(0.6) : Color(nsColor: .separatorColor)
    }
}

// MARK: - Window tracking

/// Reports the NSWindow hosting a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onWindow = onWindow
        // A window that SwiftUI reuses (closed, then opened again) doesn't move the probe: report it here too.
        if let window = nsView.window { DispatchQueue.main.async { onWindow(window) } }
    }
}

// MARK: - File watching

/// Calls `onChange` when the file at `url` is written, replaced or removed (atomic saves replace the inode,
/// so the source is re-armed after every event). Replaces polling of mtimes.
@MainActor final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { source?.cancel() }

    private func arm() {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // The file doesn't exist (yet): look again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete],
                                                          queue: .main)
        s.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                let replaced = !source.data.intersection([.rename, .delete]).isEmpty
                self.onChange()
                if replaced {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
                }
            }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }
}
