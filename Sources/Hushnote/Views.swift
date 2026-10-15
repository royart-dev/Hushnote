import SwiftUI
import AppKit
import HushnoteCore

struct RootView: View {
    let state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let strip = state.isWorking || !state.progress.isEmpty
        HStack(spacing: 0) {
            Sidebar(state: state).frame(width: 256)
            Hairline(vertical: true)
            VStack(spacing: 0) {
                Group {
                    switch state.route {
                    case .capture: CaptureView(state: state)
                    case .settings: SettingsView(state: state)
                    case .meeting(let id):
                        if let meeting = state.current, meeting.id == id { MeetingView(state: state, meeting: meeting).id(id) }
                        else { Color.clear }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if strip { StatusStrip(state: state).transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8))) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: strip)
        }
        .frame(minWidth: 940, minHeight: 640)
        .background(HN.canvas)
        .foregroundStyle(HN.ink)
        .tint(HN.ink)
        .ignoresSafeArea()
        .alert("Hushnote needs attention", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    let state: AppState
    @State private var trashing: MeetingHeader?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Logo().frame(width: 15, height: 15)
                Text("Hushnote").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 46).padding(.bottom, 18)

            RailButton(selected: state.route == .capture, action: { state.route = .capture }) {
                HStack(spacing: 10) {
                    Lamp(color: HN.signal, filled: state.isRecording, blinking: state.isRecording)
                    Text(state.isRecording ? "Recording" : "New recording").font(.system(size: 13, weight: .medium))
                    Spacer()
                    if let start = state.recordingStartedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(Format.duration(context.date.timeIntervalSince(start))).font(.hnData).foregroundStyle(HN.signal)
                        }
                    } else { KeyCaps() }
                }
                .padding(.vertical, 11)
            }

            Hairline().padding(.top, 8)
            HStack {
                Tag("Log")
                Spacer()
                Tag(String(format: "%02d", state.log.count))
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.log) { header in
                        RailButton(selected: state.route == .meeting(header.id), action: { state.route = .meeting(header.id) }) {
                            MeetingRow(header: header, active: (state.isRecording && header.state == .recording) || state.busyID == header.id)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.locations.directory(header.id)]) }
                            Divider()
                            Button("Move to Trash…") { trashing = header }.disabled(state.isLocked(header.id))
                        }
                    }
                }
                if state.log.isEmpty {
                    Text("Recordings appear here.").font(.system(size: 12)).foregroundStyle(HN.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 8)
                }
            }
            .scrollIndicators(.never)

            Hairline()
            HStack(spacing: 8) {
                Button { state.route = .settings } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                        Text("Settings")
                    }
                }
                .buttonStyle(.instrument(.quiet))
                .foregroundStyle(state.route == .settings ? HN.ink : HN.ink2)
                Spacer()
                Lamp(color: HN.cool)
                Tag("On-device")
            }
            .padding(.leading, 11).padding(.trailing, 18).frame(height: 46)
        }
        .background(HN.rail)
        .confirmationDialog("Move “\(trashing?.title ?? "")” to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }), presenting: trashing) { header in
            Button("Move to Trash", role: .destructive) { state.moveToTrash(header.id) }
        } message: { _ in
            Text("Its local audio checkpoints and transcript go to the Trash. Exported notes are not affected.")
        }
    }
}

/// A flush, square-edged list row. Selection is a canvas-coloured slot with an ink edge.
struct RailButton<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? HN.canvas : hover ? HN.ink.opacity(0.035) : .clear)
                .overlay(alignment: .leading) { if selected { Rectangle().fill(HN.ink).frame(width: 2) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct MeetingRow: View {
    let header: MeetingHeader
    var active = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(header.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Lamp(color: header.state.lamp.color, filled: header.state.lamp.filled, blinking: active)
            }
            Text(meta).font(.hnData).foregroundStyle(HN.muted).lineLimit(1)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityValue(header.state.label)
    }
    private var meta: String {
        var parts = [Format.day(header.startedAt), Format.duration(header.duration)]
        if !header.project.isEmpty { parts.append(header.project.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Capture

struct CaptureView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Tag(state.isRecording ? "Recording" : "New recording", color: state.isRecording ? HN.signal : HN.muted)
                    Spacer()
                    Tag(Format.day(Date()))
                }
                Readout(start: state.recordingStartedAt).padding(.top, 18)
                HStack(spacing: 8) {
                    Lamp(color: state.isRecording ? HN.signal : HN.ruleStrong, blinking: state.isRecording)
                    Tag(state.isRecording ? "Rec · 16 kHz mono · local" : state.isStarting ? "Arming…" : "Standby",
                        color: state.isRecording ? HN.signal : HN.muted)
                }
                .padding(.top, 6)

                Hairline().padding(.vertical, 28)

                if let title = state.recordingTitle {
                    VStack(alignment: .leading, spacing: 6) {
                        Tag("Title")
                        Text(title).font(.system(size: 20, weight: .semibold))
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 7) {
                            Tag("Title")
                            Field(placeholder: "Untitled meeting", text: $state.title)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Tag("Project")
                            Field(placeholder: "Optional", text: $state.project)
                        }
                        .frame(width: 200)
                    }
                    .disabled(state.isStarting)
                }

                if !state.hasSpeechModels && !state.isRecording {
                    HStack(spacing: 10) {
                        Lamp(color: HN.amber, filled: false)
                        Text("Speech models aren’t installed. You can record now and process later.").font(.system(size: 12)).foregroundStyle(HN.ink2)
                        Spacer()
                        Button("Set up") { state.route = .settings }.buttonStyle(.instrument(.quiet))
                    }
                    .padding(.top, 22)
                }

                Hairline().padding(.vertical, 28)
                Tag("Inputs").padding(.bottom, 4)
                InputRow(channel: "CH 1", name: "System audio", detail: "Everything playing on this Mac") {
                    HStack(spacing: 7) { Lamp(color: HN.cool); Tag("Always on", color: HN.ink2) }
                }
                Hairline()
                InputRow(channel: "CH 2", name: "Microphone", detail: "Your voice, on its own track") {
                    Toggle("Include my microphone", isOn: $state.includeMicrophone).toggleStyle(InstrumentSwitch()).labelsHidden()
                        .disabled(state.isRecording || state.isStarting)
                }

                Hairline().padding(.top, 4).padding(.bottom, 28)
                HStack(spacing: 14) {
                    Button { state.toggleRecording() } label: {
                        HStack(spacing: 9) {
                            if state.isRecording { RoundedRectangle(cornerRadius: 1).fill(HN.canvas).frame(width: 9, height: 9) }
                            else { Circle().fill(.white).frame(width: 9, height: 9) }
                            Text(state.isStarting ? "Requesting access…" : state.isRecording ? "Stop" : "Record")
                        }
                    }
                    .buttonStyle(.instrument(state.isRecording ? .stop : .record))
                    .disabled(state.isStarting)
                    KeyCaps()
                    Text("from any app").font(.system(size: 12)).foregroundStyle(HN.muted)
                    Spacer()
                    if !state.isRecording {
                        Button("Import audio…") { state.importAudio() }.buttonStyle(.instrument(.quiet)).disabled(state.isWorking)
                    }
                }
                Text("The window hides while recording. Stop from the menu bar or with ⌥⌘R. Starting a recording pauses any processing; it resumes from saved checkpoints.")
                    .font(.system(size: 11)).foregroundStyle(HN.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 48).padding(.top, 44).padding(.bottom, 48)
        }
    }
}

/// The recorder clock. Unlit segments when idle; ticks once a second while live.
struct Readout: View {
    let start: Date?
    var body: some View {
        if let start {
            TimelineView(.periodic(from: start, by: 1)) { context in digits(context.date.timeIntervalSince(start), live: true) }
        } else { digits(0, live: false) }
    }
    private func digits(_ elapsed: Double, live: Bool) -> some View {
        Text(Meeting.timestamp(elapsed))
            .font(.system(size: 76, weight: .light, design: .monospaced)).tracking(-3)
            .foregroundStyle(live ? HN.ink : HN.ruleStrong)
            .accessibilityLabel(live ? "Elapsed \(Meeting.timestamp(elapsed))" : "Not recording")
    }
}

struct InputRow<Control: View>: View {
    let channel: String, name: String, detail: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack(spacing: 16) {
            Tag(channel).frame(width: 40, alignment: .leading)
            Text(name).font(.system(size: 13, weight: .medium)).frame(width: 120, alignment: .leading)
            Text(detail).font(.system(size: 12)).foregroundStyle(HN.muted)
            Spacer()
            control
        }
        .frame(height: 44)
    }
}

// MARK: Meeting

struct MeetingView: View {
    let state: AppState
    let meeting: Meeting
    @State var tab = Tab.notes
    @State private var editingNotes = false
    @State private var flash: UUID?
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    enum Tab { case notes, transcript }

    var body: some View {
        let locked = state.isLocked(meeting.id)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(locked: locked)
                    ForEach(Array(meeting.warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Lamp(color: HN.amber, filled: false)
                            Text(warning).font(.system(size: 12)).foregroundStyle(HN.ink2).textSelection(.enabled)
                        }
                        .padding(.top, 10)
                    }
                    if !meeting.transcript.isEmpty { speakers(locked: locked).padding(.top, 28) }
                    tabs.padding(.top, 30)
                    Group {
                        switch tab {
                        case .notes: notes(locked: locked)
                        case .transcript: transcript
                        }
                    }
                    .padding(.top, 20)
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 48).padding(.top, 44).padding(.bottom, 56)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "hushnote", let seconds = Double(url.lastPathComponent) else { return .systemAction }
                jump(to: seconds, proxy: proxy); return .handled
            })
        }
    }

    private func header(locked: Bool) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Lamp(color: meeting.state.lamp.color, filled: meeting.state.lamp.filled, blinking: state.busyID == meeting.id)
                    Tag(meeting.state.label, color: HN.ink2)
                    Tag("·"); Tag(Format.stamp(meeting.startedAt))
                    Tag("·"); Tag(Meeting.timestamp(meeting.duration))
                }
                TextField("Untitled meeting", text: binding(\.title))
                    .textFieldStyle(.plain).font(.hnTitle).focusEffectDisabled()
                HStack(spacing: 8) {
                    Tag("Project")
                    TextField("None", text: binding(\.project)).textFieldStyle(.plain).font(.hnData).focusEffectDisabled().frame(maxWidth: 240)
                }
            }
            .disabled(locked)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if state.hasSpeechModels {
                    Button(meeting.transcript.isEmpty ? "Process" : "Process again") { state.processMeeting(meeting.id) }
                        .disabled(state.isWorking || state.isRecording || meeting.chunks.isEmpty)
                } else {
                    Button("Set up models") { state.route = .settings }
                }
                Button("Export .md") { state.exportCurrent() }
                    .buttonStyle(.instrument(.primary))
                    .disabled(state.isWorking || meeting.transcript.isEmpty)
            }
            .buttonStyle(.instrument())
            .padding(.top, 22)
        }
    }

    private func binding(_ field: WritableKeyPath<Meeting, String>) -> Binding<String> {
        Binding(get: { meeting[keyPath: field] }, set: { value in state.edit { $0[keyPath: field] = value } })
    }

    private func speakers(locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Tag("Speakers")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(meeting.speakers, id: \.self) { speaker in
                    HStack(spacing: 0) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1).fill(mark(speaker)).frame(width: 7, height: 7)
                            Text(code(speaker)).font(.hnLabel).foregroundStyle(HN.muted)
                        }
                        .frame(width: 54, alignment: .leading).padding(.leading, 9)
                        Hairline(vertical: true)
                        TextField(speaker, text: Binding(get: { meeting.displayName(speaker) },
                                                         set: { name in state.edit { $0.speakerNames[speaker] = name } }))
                            .textFieldStyle(.plain).font(.system(size: 12)).focusEffectDisabled().padding(.horizontal, 9)
                    }
                    .frame(height: 28)
                    .background(HN.well, in: RoundedRectangle(cornerRadius: HN.corner))
                    .overlay(RoundedRectangle(cornerRadius: HN.corner).strokeBorder(HN.rule, lineWidth: 1))
                }
            }
            .disabled(locked)
        }
    }

    private var tabs: some View {
        HStack(alignment: .bottom, spacing: 24) {
            tabButton("Notes", .notes)
            tabButton("Transcript", .transcript, count: meeting.transcript.count)
            Spacer()
            if tab == .notes, !meeting.summary.isEmpty {
                Button(editingNotes ? "Done" : "Edit") { editingNotes.toggle() }
                    .buttonStyle(.instrument(.quiet)).disabled(state.isLocked(meeting.id)).padding(.bottom, 4)
            }
        }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func tabButton(_ title: String, _ value: Tab, count: Int? = nil) -> some View {
        Button {
            if reduceMotion { tab = value } else { withAnimation(.easeInOut(duration: 0.18)) { tab = value } }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Tag(title, color: tab == value ? HN.ink : HN.muted)
                    if let count, count > 0 { Tag(String(count), color: HN.muted) }
                }
                ZStack {
                    Rectangle().fill(.clear).frame(height: 2)
                    if tab == value { Rectangle().fill(HN.ink).frame(height: 2).matchedGeometryEffect(id: "tab", in: underline) }
                }
            }
            .fixedSize().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func notes(locked: Bool) -> some View {
        if meeting.summary.isEmpty && meeting.transcript.isEmpty {
            unprocessed
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if editingNotes && !locked {
                    TextEditor(text: binding(\.summary))
                        .font(.system(size: 13, design: .monospaced)).lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(10).frame(minHeight: 380)
                        .background(HN.well, in: RoundedRectangle(cornerRadius: HN.corner))
                        .overlay(RoundedRectangle(cornerRadius: HN.corner).strokeBorder(HN.ink2, lineWidth: 1))
                } else {
                    NotesText(markdown: meeting.summary)
                }
                if !meeting.summaryMethod.isEmpty {
                    Hairline().padding(.top, 32)
                    Text(meeting.summaryMethod).font(.hnData).foregroundStyle(HN.muted).padding(.top, 10)
                }
            }
        }
    }

    private var unprocessed: some View {
        let busy = state.isWorking && state.busyID == meeting.id
        return VStack(alignment: .leading, spacing: 10) {
            Tag(busy ? "Processing" : meeting.chunks.isEmpty ? "No audio" : "Not processed", color: HN.ink2)
            Text(busy ? "Separating speakers, transcribing and writing notes on this Mac. Progress is shown below."
                 : meeting.chunks.isEmpty ? "No audio was captured for this meeting."
                 : "\(meeting.chunks.count) checkpoint\(meeting.chunks.count == 1 ? "" : "s") · \(Meeting.timestamp(meeting.duration)) of audio saved on this Mac. Processing separates speakers, transcribes, then writes notes — all locally.")
                .font(.system(size: 13)).foregroundStyle(HN.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: HN.corner).strokeBorder(HN.ruleStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    @ViewBuilder private var transcript: some View {
        if meeting.transcript.isEmpty {
            unprocessed
        } else {
            let lines = meeting.transcript.enumerated().map { index, segment in
                TranscriptLine(segment: segment, showSpeaker: index == 0 || meeting.transcript[index - 1].speaker != segment.speaker)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    TranscriptRow(line: line, name: meeting.displayName(line.segment.speaker), mark: mark(line.segment.speaker),
                                  highlighted: flash == line.id)
                }
            }
            .padding(.horizontal, -10)
        }
    }

    /// Timestamp links in notes jump to the matching passage and flash it briefly.
    private func jump(to seconds: Double, proxy: ScrollViewProxy) {
        guard let target = meeting.transcript.last(where: { $0.start <= seconds + 0.5 }) ?? meeting.transcript.first else { return }
        tab = .transcript; flash = target.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            if reduceMotion { proxy.scrollTo(target.id, anchor: .center) }
            else { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target.id, anchor: .center) } }
            try? await Task.sleep(for: .seconds(1.4))
            if flash == target.id {
                if reduceMotion { flash = nil } else { withAnimation(.easeOut(duration: 0.5)) { flash = nil } }
            }
        }
    }

    private func code(_ speaker: String) -> String {
        switch speaker {
        case "You": "YOU"
        case "Meeting audio": "MIX"
        case "Overlapping speakers": "OVL"
        default: speaker.hasPrefix("Speaker ") ? "S" + speaker.dropFirst(8) : String(speaker.prefix(3)).uppercased()
        }
    }

    private func mark(_ speaker: String) -> Color {
        switch speaker {
        case "You": return HN.ink
        case "Meeting audio", "Overlapping speakers": return HN.muted
        default:
            let others = meeting.speakers.filter { $0.hasPrefix("Speaker ") }
            return HN.speakerMarks[(others.firstIndex(of: speaker) ?? 0) % HN.speakerMarks.count]
        }
    }
}

struct TranscriptLine: Identifiable {
    let segment: TranscriptSegment
    let showSpeaker: Bool
    var id: UUID { segment.id }
}

struct TranscriptRow: View {
    let line: TranscriptLine
    let name: String
    let mark: Color
    let highlighted: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(Meeting.timestamp(line.segment.start)).font(.hnData).foregroundStyle(HN.muted).frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if line.showSpeaker {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1).fill(mark).frame(width: 6, height: 6)
                        Text(name.uppercased()).font(.hnLabel).tracking(0.8).foregroundStyle(HN.ink2)
                    }
                }
                Text(line.segment.text).font(.hnReading).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.top, line.showSpeaker ? 14 : 4).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? HN.cool.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 2))
    }
}

/// Renders the summary's light Markdown: headings become instrument labels, list items get
/// rules, and [hh:mm:ss] references become links into the transcript.
struct NotesText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(NoteOutline.parse(markdown).enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Tag(text, color: HN.ink2).padding(.top, index == 0 ? 0 : 14)
                case .item(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("—").font(.hnData).foregroundStyle(HN.muted)
                        inline(text)
                    }
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> some View {
        Text(Self.attributed(text)).font(.hnReading).lineSpacing(4).tint(HN.cool).fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ text: String) -> AttributedString {
        let linked = text.replacing(#/\[(\d{2}):(\d{2}):(\d{2})\]/#) { match in
            let seconds = (Int(match.1) ?? 0) * 3600 + (Int(match.2) ?? 0) * 60 + (Int(match.3) ?? 0)
            return "[\(match.1):\(match.2):\(match.3)](hushnote://t/\(seconds))"
        }
        var result = (try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in result.runs where run.link?.scheme == "hushnote" {
            result[run.range].font = .system(size: 12, weight: .medium, design: .monospaced)
        }
        return result
    }
}

// MARK: Status

struct StatusStrip: View {
    let state: AppState
    var body: some View {
        HStack(spacing: 12) {
            if state.isWorking { Meter() } else { Lamp(color: state.progress == "Needs attention" ? HN.signal : HN.cool) }
            Text(state.progress).font(.hnData).foregroundStyle(HN.ink2).lineLimit(1).truncationMode(.middle)
            if let fraction = state.progressFraction { SegmentBar(fraction: fraction) }
            Spacer()
            if state.isWorking {
                Button("Cancel") { state.cancelWork() }.buttonStyle(.instrument(.quiet))
            } else {
                if let url = state.lastExport, state.progress.hasPrefix("Saved") {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.instrument(.quiet))
                }
                Button { state.progress = "" } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.instrument(.quiet)).accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 20).padding(.trailing, 14).frame(height: 40)
        .background(HN.rail)
        .overlay(alignment: .top) { Hairline() }
        .task(id: state.progress) {
            guard !state.isWorking, !state.progress.isEmpty else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled && !state.isWorking { state.progress = "" }
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Tag("Settings")
                Text("Set it once, then forget it.").font(.hnTitle).padding(.top, 10)

                section("01", "Save location") {
                    SettingRow("Folder") {
                        Text(state.destination?.path(percentEncoded: false) ?? "Not chosen — you’ll be asked on first export")
                            .font(.hnData).foregroundStyle(state.destination == nil ? HN.muted : HN.ink).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 12)
                        Button("Choose…") { state.chooseDestination() }
                        Button("Google Drive…") { state.chooseDestination(drive: true) }
                    }
                    SettingRow("Drive link") {
                        Field(placeholder: "https://drive.google.com/drive/folders/…", text: $state.driveLink, font: .hnData)
                        Button("Keep") { state.saveDriveLink() }
                        if let url = state.validDriveURL { Link(destination: url) { Image(systemName: "arrow.up.right") }.buttonStyle(.instrument(.quiet)) }
                    }
                    SettingRow("Audio") {
                        Text("Attach compressed audio to exported notes").font(.hnBody)
                        Spacer()
                        Toggle("Attach audio", isOn: $state.includeAudioInExport).toggleStyle(InstrumentSwitch()).labelsHidden()
                    }
                    note("Choose the Google Drive for desktop folder that matches your link once. Hushnote writes ordinary files there, offline if needed; Drive syncs them. Processing always stays on this Mac.")
                }

                section("02", "Local models") {
                    ModelRow(name: "Speech", detail: "Parakeet TDT v2 · speaker separation", size: "466 MB", installed: state.hasSpeechModels) {
                        Button(state.hasSpeechModels ? "Verify" : "Download") { state.installSpeechModels() }
                    }
                    ModelRow(name: "Summary", detail: "Qwen 2.5 1.5B · 4-bit · Metal", size: "1.12 GB", installed: state.hasSummaryModel) {
                        if !state.hasSummaryModel { Button("Download") { state.installSummaryModel() } }
                    }
                    note("Models load in a separate process after you stop recording and unload when it exits. Without the summary model, notes contain selected transcript excerpts. Downloads fetch model files only; recording, transcription and summaries never touch the network.")
                }
                .disabled(state.isWorking)

                section("03", "Recording") {
                    SettingRow("After stop") {
                        Text("Process automatically").font(.hnBody)
                        Spacer()
                        Toggle("Process automatically", isOn: $state.autoProcess).toggleStyle(InstrumentSwitch()).labelsHidden()
                    }
                    SettingRow("Shortcut") {
                        KeyCaps()
                        Text("Start or stop from any app").font(.hnBody).foregroundStyle(HN.ink2)
                        Spacer()
                    }
                    SettingRow("Storage") {
                        Text(state.storageBytes.map { "Local recordings · \(Format.bytes($0))" } ?? "Local recordings").font(.hnData)
                        Spacer()
                        Button("Open folder") { NSWorkspace.shared.open(state.locations.sessions) }
                    }
                    note("Use headphones for cleaner microphone separation; with speakers, other participants also reach your microphone. Uncompressed checkpoints use about 115 MB per hour per track — move meetings you no longer need to the Trash from the log.")
                }
            }
            .buttonStyle(.instrument())
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 48).padding(.top, 44).padding(.bottom, 56)
        }
        .onAppear { state.refreshStorage() }
    }

    private func section<Content: View>(_ number: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) { Tag(number, color: HN.muted); Tag(title, color: HN.ink) }
                .padding(.bottom, 10)
            Hairline()
            content()
        }
        .padding(.top, 40)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(HN.muted).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 12).padding(.leading, 112)
    }
}

struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Tag(label).frame(width: 104, alignment: .leading)
                content
            }
            .frame(minHeight: 48)
            Hairline()
        }
    }
}

struct ModelRow<Action: View>: View {
    let name: String, detail: String, size: String
    let installed: Bool
    @ViewBuilder let action: Action
    var body: some View {
        SettingRow(name) {
            Lamp(color: installed ? HN.cool : HN.ruleStrong, filled: installed)
            Text(detail).font(.hnBody)
            Spacer()
            Tag(installed ? "Installed" : size, color: installed ? HN.cool : HN.muted)
            action
        }
    }
}
