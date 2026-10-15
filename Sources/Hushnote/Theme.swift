import SwiftUI
import AppKit
import HushnoteCore

/// Hushnote's visual language: a matte field-recorder panel. Warm neutrals, hairline rules,
/// 2–3 pt corners, monospaced instrument labels, and one signal colour reserved for recording.
enum HN {
    static let canvas = Color(light: 0xF3F1EC, dark: 0x131210)
    static let rail = Color(light: 0xEAE7E0, dark: 0x1C1B18)
    static let well = Color(light: 0xFBFAF7, dark: 0x1F1E1B)
    // Ink, cream and signal are the exact colours of design/Hushnote_AppIcon.svg.
    static let ink = Color(light: 0x1C1B18, dark: 0xF5EFE5)
    static let ink2 = Color(light: 0x4B4841, dark: 0xBEB9AF)
    static let muted = Color(light: 0x8A867D, dark: 0x8B867C)
    static let rule = Color(light: 0xDDD9D0, dark: 0x2A2825)
    static let ruleStrong = Color(light: 0xC5C0B5, dark: 0x3C3A36)
    static let signal = Color(light: 0xF74D21, dark: 0xF74D21)
    static let cool = Color(light: 0x23808F, dark: 0x5DB7C6)
    static let amber = Color(light: 0xB27416, dark: 0xE2A541)
    static let canvasNS = NSColor(light: 0xF3F1EC, dark: 0x131210)

    static let corner: CGFloat = 3
    static let speakerMarks = [cool, amber, Color(light: 0x6B5FA8, dark: 0x9D93D8), Color(light: 0x5E7A34, dark: 0x9BBE63)]
}

extension NSColor {
    convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) { self.init(nsColor: NSColor(light: light, dark: dark)) }
}

extension Font {
    static let hnLabel = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let hnData = Font.system(size: 11, design: .monospaced)
    static let hnBody = Font.system(size: 13)
    static let hnReading = Font.system(size: 14)
    static let hnTitle = Font.system(size: 26, weight: .semibold)
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated)).uppercased() }
    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy"; return f }()
    static func stamp(_ date: Date) -> String {
        (dayFormatter.string(from: date) + " · " + date.formatted(date: .omitted, time: .shortened)).uppercased()
    }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

extension MeetingState {
    var label: String {
        switch self {
        case .recording: "Recording"
        case .interrupted: "Interrupted"
        case .ready: "Unprocessed"
        case .processing: "Processing"
        case .complete: "Done"
        case .failed: "Failed"
        }
    }
    var lamp: (color: Color, filled: Bool) {
        switch self {
        case .recording: (HN.signal, true)
        case .processing: (HN.amber, true)
        case .ready: (HN.cool, true)
        case .complete: (HN.muted, false)
        case .interrupted: (HN.amber, false)
        case .failed: (HN.signal, false)
        }
    }
}

// MARK: Primitives

/// Uppercase monospaced instrument label.
struct Tag: View {
    let text: String
    var color: Color = HN.muted
    init(_ text: String, color: Color = HN.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.hnLabel).tracking(1.1).foregroundStyle(color).lineLimit(1)
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(HN.rule).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A status LED. Blinks in discrete steps like hardware, never a continuous animation.
struct Lamp: View {
    var color: Color
    var filled = true
    var blinking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if blinking && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.6)) { context in
                led.opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0 ? 1 : 0.25)
            }
        } else { led }
    }
    private var led: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(filled ? color : .clear)
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(color, lineWidth: filled ? 0 : 1.2))
            .frame(width: 7, height: 7)
    }
}

struct KeyCaps: View {
    var keys = ["⌥", "⌘", "R"]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(HN.ink2)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(HN.well, in: RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HN.ruleStrong, lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Option Command R")
    }
}

/// The Hushnote mark from design/Hushnote_Logo.svg. The artwork is cream for dark grounds; here the H
/// follows the ink colour so it reads in both themes (cream in dark mode), and the pill stays vermilion.
struct Logo: View {
    var body: some View {
        ZStack {
            LogoShape(part: .mark).fill(HN.ink)
            LogoShape(part: .pill).fill(HN.signal)
        }
        .aspectRatio(LogoGeometry.size, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct LogoShape: Shape {
    enum Part { case mark, pill }
    let part: Part
    func path(in rect: CGRect) -> Path {
        Path(part == .mark ? LogoGeometry.mark : LogoGeometry.pillPath).applying(LogoGeometry.transform(into: rect))
    }
}

/// Menu-bar renderings of the mark. Idle and working are template images, so macOS tints them for
/// the menu bar; recording keeps the pill red, so it draws the H in the label colour itself.
enum StatusIcon {
    static let idle = make(template: true) { context in
        context.setBlendMode(.clear); context.addPath(LogoGeometry.pillPath); context.fillPath()
    }
    static let working = make(template: true) { context in context.addPath(LogoGeometry.pillPath); context.fillPath() }
    static let recording = make(template: false) { context in
        context.setFillColor(NSColor.systemRed.cgColor); context.addPath(LogoGeometry.pillPath); context.fillPath()
    }

    private static func make(template: Bool, pill: @escaping (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.concatenate(LogoGeometry.transform(into: rect))
            context.setFillColor(template ? NSColor.black.cgColor : NSColor.labelColor.cgColor)
            context.addPath(LogoGeometry.mark); context.fillPath()
            pill(context)
            return true
        }
        image.isTemplate = template
        return image
    }
}

struct Field: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .hnBody
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(font).focused($focused).focusEffectDisabled()
            .padding(.horizontal, 9).frame(height: 30)
            .background(HN.well, in: RoundedRectangle(cornerRadius: HN.corner))
            .overlay(RoundedRectangle(cornerRadius: HN.corner).strokeBorder(focused ? HN.ink2 : HN.rule, lineWidth: 1))
    }
}

// MARK: Controls

struct InstrumentButton: ButtonStyle {
    enum Kind { case primary, secondary, quiet, record, stop }
    var kind: Kind = .secondary
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, kind: kind) }

    private struct Face: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hover = false
        var body: some View {
            let large = kind == .record || kind == .stop
            configuration.label
                .font(.system(size: large ? 13 : 12, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .quiet ? 7 : large ? 18 : 12)
                .frame(height: large ? 36 : 26)
                .background(background, in: RoundedRectangle(cornerRadius: HN.corner))
                .overlay {
                    if kind == .secondary { RoundedRectangle(cornerRadius: HN.corner).strokeBorder(HN.ruleStrong, lineWidth: 1) }
                }
                .overlay { if configuration.isPressed { RoundedRectangle(cornerRadius: HN.corner).fill(Color.black.opacity(0.08)) } }
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
                .contentShape(Rectangle())
                .onHover { hover = $0 && enabled }
        }
        private var foreground: Color {
            switch kind {
            case .primary, .stop: HN.canvas
            case .record: .white
            case .secondary: HN.ink
            case .quiet: hover ? HN.ink : HN.ink2
            }
        }
        private var background: Color {
            switch kind {
            case .primary, .stop: hover ? HN.ink.opacity(0.86) : HN.ink
            case .record: hover ? HN.signal.opacity(0.9) : HN.signal
            case .secondary, .quiet: hover ? HN.ink.opacity(0.06) : .clear
            }
        }
    }
}

extension ButtonStyle where Self == InstrumentButton {
    static func instrument(_ kind: InstrumentButton.Kind = .secondary) -> InstrumentButton { InstrumentButton(kind: kind) }
}

/// A flat hardware-style switch: a square knob that slides in a 2 pt-cornered track.
struct InstrumentSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }
    private struct Face: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let on = configuration.isOn
            ZStack(alignment: on ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 2.5).fill(on ? HN.ink : HN.well)
                    .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(on ? HN.ink : HN.ruleStrong, lineWidth: 1))
                RoundedRectangle(cornerRadius: 1.5).fill(on ? HN.canvas : HN.ink2).frame(width: 12, height: 12).padding(2)
            }
            .frame(width: 30, height: 16)
            .opacity(enabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: on)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { configuration.isOn.toggle() } }
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

/// Stepped activity meter for indeterminate work. Ticks at 8 Hz; static under Reduce Motion.
struct Meter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let levels: [[CGFloat]] = [[0.4, 0.9, 0.6, 0.3], [0.7, 0.5, 1, 0.5], [1, 0.3, 0.7, 0.8], [0.5, 0.8, 0.4, 1], [0.3, 1, 0.9, 0.6], [0.8, 0.6, 0.5, 0.4]]
    var body: some View {
        if reduceMotion { bars(Self.levels[1]) }
        else {
            TimelineView(.periodic(from: .now, by: 0.125)) { context in
                bars(Self.levels[Int(context.date.timeIntervalSinceReferenceDate * 8) % Self.levels.count])
            }
        }
    }
    private func bars(_ heights: [CGFloat]) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(heights.indices, id: \.self) { i in Rectangle().fill(HN.amber).frame(width: 2, height: 4 + 9 * heights[i]) }
        }
        .frame(height: 13, alignment: .bottom).accessibilityHidden(true)
    }
}

/// Determinate progress as a row of LED segments.
struct SegmentBar: View {
    var fraction: Double
    var segments = 24
    var body: some View {
        let lit = Int((fraction * Double(segments)).rounded(.down))
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                Rectangle().fill(i < lit ? HN.ink : HN.ruleStrong.opacity(0.6)).frame(width: 4, height: 9)
            }
        }
        .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
