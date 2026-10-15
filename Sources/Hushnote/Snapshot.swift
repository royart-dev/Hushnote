#if DEBUG
import AppKit
import SwiftUI
import HushnoteCore

/// Debug-only: renders the real views offscreen with fixture data so UI changes
/// can be reviewed without screen-recording permission or a live session.
/// Usage: .build/debug/Hushnote --snapshot <output-directory>
@MainActor
enum Snapshot {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scene in scenes {
            let state = AppState(preview: fixtures)
            scene.configure(state)
            render(RootView(state: state), size: scene.size, to: directory.appendingPathComponent(scene.name + ".png"), appearance: scene.appearance)
        }
        let state = AppState(preview: fixtures)
        render(MeetingView(state: state, meeting: fixtures[0], tab: .transcript), size: CGSize(width: 860, height: 760),
               to: directory.appendingPathComponent("8-transcript.png"), appearance: .aqua)
        renderStatusIcons(to: directory.appendingPathComponent("9-menu-bar.png"))
        print("Wrote \(scenes.count + 2) snapshots to \(directory.path)")
    }

    struct Scene {
        let name: String
        var size = CGSize(width: 1120, height: 760)
        var appearance: NSAppearance.Name = .aqua
        let configure: @MainActor (AppState) -> Void
    }

    static let scenes: [Scene] = [
        Scene(name: "1-capture") { $0.route = .capture },
        Scene(name: "2-meeting") { $0.route = .meeting(fixtures[0].id) },
        Scene(name: "3-meeting-dark", appearance: .darkAqua) { $0.route = .meeting(fixtures[0].id) },
        Scene(name: "4-processing") { s in s.route = .meeting(fixtures[2].id); s.previewWorking(fixtures[2].id, "Transcribing · 4 of 9", 3.0 / 9) },
        Scene(name: "5-recording-dark", appearance: .darkAqua) { s in s.previewRecording(Date().addingTimeInterval(-1_394), title: "Weekly design sync") },
        Scene(name: "6-settings") { $0.route = .settings },
        Scene(name: "7-interrupted") { $0.route = .meeting(fixtures[3].id) },
    ]

    static func render<V: View>(_ view: V, size: CGSize, to url: URL, appearance: NSAppearance.Name) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Idle, working and recording icons at 1x and 3x, on light and dark menu-bar grounds,
    /// tinted the way the menu bar tints template images.
    static func renderStatusIcons(to url: URL) {
        let icons = [StatusIcon.idle, StatusIcon.working, StatusIcon.recording]
        let scale: CGFloat = 2, cell: CGFloat = 76, size = NSSize(width: cell * 6 * scale, height: cell * 2 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let y = CGFloat(1 - row) * cell * scale
                (row == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: cell * scale).fill()
                for (column, icon) in icons.enumerated() {
                    for (pass, points) in [CGFloat(16), 48].enumerated() {
                        let side = points * scale
                        let x = (CGFloat(column * 2 + pass) * cell + (cell - points) / 2) * scale
                        let target = NSRect(x: x, y: y + (cell - points) / 2 * scale, width: side, height: side)
                        if icon.isTemplate {
                            let tinted = NSImage(size: target.size, flipped: false) { rect in
                                icon.draw(in: rect); NSColor.labelColor.set(); rect.fill(using: .sourceAtop); return true
                            }
                            tinted.draw(in: target)
                        } else { icon.draw(in: target) }
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static let fixtures: [Meeting] = {
        var a = Meeting(title: "Q4 roadmap review", project: "Northwind")
        a.startedAt = Date(timeIntervalSince1970: 1_791_900_000)
        a.duration = 2_538; a.state = .complete
        a.chunks = [AudioChunk(file: "system-0.caf", source: "system", start: 0, duration: 30)]
        a.speakerNames = ["Speaker 1": "Maya", "Speaker 2": "Arjun"]
        a.summaryMethod = "Local Qwen 2.5 1.5B; AI-generated, review against transcript"
        a.summary = """
        ## Summary
        The team reviewed Q4 priorities and agreed to ship offline sync before expanding to team billing. [00:04:12]

        ## Decisions
        - Offline sync ships first; team billing moves to January. [00:11:40]
        - Keep the current sync vendor through the beta. [00:23:05]

        ## Action items
        - Arjun to share the revised vendor quote by Friday. [00:31:18]
        - Maya to draft the beta announcement. [00:36:02]
        """
        let lines: [(Double, String, String)] = [
            (12, "Speaker 1", "Okay, let's start with the roadmap. The big question is whether offline sync goes out before team billing."),
            (41, "Speaker 2", "I think it has to. Billing depends on accounts being stable, and we only get that once sync is live."),
            (88, "You", "Agreed. If we hold sync for billing we lose the whole beta window."),
            (252, "Speaker 1", "So the decision is sync first, billing in January. Does anyone disagree?"),
            (700, "Speaker 2", "No, but we need the vendor to commit on conflict handling. Right now it's last write wins."),
            (1385, "You", "Let's keep them through the beta and revisit the contract after we see the usage numbers."),
            (1878, "Speaker 2", "I'll get the revised quote over by Friday."),
            (2162, "Speaker 1", "And I'll draft the beta announcement so we can review it next week."),
        ]
        a.transcript = lines.map { TranscriptSegment(start: $0.0, end: $0.0 + 12, speaker: $0.1, text: $0.2) }
        var b = Meeting(title: "Vendor sync — conflict handling", project: "Northwind")
        b.startedAt = a.startedAt.addingTimeInterval(-86_400 * 2); b.duration = 1_412; b.state = .complete
        var c = Meeting(title: "Design crit", project: "")
        c.startedAt = a.startedAt.addingTimeInterval(-86_400 * 3); c.duration = 3_160; c.state = .processing
        c.chunks = a.chunks
        var d = Meeting(title: "Untitled meeting", project: "")
        d.startedAt = a.startedAt.addingTimeInterval(-86_400 * 6); d.duration = 845; d.state = .interrupted
        d.warnings = ["The Mac went to sleep. This session ended; saved audio is recoverable."]
        return [a, b, c, d]
    }()
}
#endif
