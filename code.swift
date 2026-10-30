/**
 
 # All Code
 
 Written by GPT 6.1 Sol and GPT 6 Astra.
 
 Achraf Kassioui
 Created 20 Oct 2026
 Updated 29 Oct 2026
 
 */
@preconcurrency import AVFoundation
import AVKit
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox
import ImageIO
import CoreImage

// MARK: Appearance and Settings

/// Colors for the canvas, crop rectangle, handles, and export button.
enum CropAppearance {
    static let exportAccent = Color(red: 225.0 / 255.0, green: 0, blue: 0)
    /// Default canvas colors for light and dark appearance.
    static let canvas = NSColor(name: "CanvasBackground") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: isDark ? 0.20 : 0.78, alpha: 1)
    }
    static let cropBorder = NSColor(Color(red: 225.0 / 255.0, green: 0, blue: 0))
    static let cropHandles = NSColor.white
    static let excludedArea = NSColor.black.withAlphaComponent(0.45)
}

/// The four-arrow cursor for moving the crop rectangle.
@MainActor
enum CropCursors {
    static let moveCrop: NSCursor = {
        let image = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { _ in
            let arrows = NSBezierPath()
            arrows.move(to: NSPoint(x: 14, y: 3))
            arrows.line(to: NSPoint(x: 14, y: 25))
            arrows.move(to: NSPoint(x: 3, y: 14))
            arrows.line(to: NSPoint(x: 25, y: 14))
            for endpoint in [NSPoint(x: 14, y: 3), NSPoint(x: 14, y: 25)] {
                let direction: CGFloat = endpoint.y < 14 ? 1 : -1
                arrows.move(to: NSPoint(x: 10, y: endpoint.y + direction * 4))
                arrows.line(to: endpoint)
                arrows.line(to: NSPoint(x: 18, y: endpoint.y + direction * 4))
            }
            for endpoint in [NSPoint(x: 3, y: 14), NSPoint(x: 25, y: 14)] {
                let direction: CGFloat = endpoint.x < 14 ? 1 : -1
                arrows.move(to: NSPoint(x: endpoint.x + direction * 4, y: 10))
                arrows.line(to: endpoint)
                arrows.line(to: NSPoint(x: endpoint.x + direction * 4, y: 18))
            }
            arrows.lineJoinStyle = .round
            NSColor.white.setStroke()
            arrows.lineWidth = 4
            arrows.stroke()
            NSColor.black.setStroke()
            arrows.lineWidth = 2
            arrows.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 14, y: 14))
    }()
}

/// Positions the timeline and leaves room for it when fitting the video.
struct CropWorkspaceLayout {
    let size: CGSize
    let playbackHeight: CGFloat
    var playbackWidth: CGFloat { max(240, min(650, size.width - 48)) }
    var playbackCenter: CGPoint { CGPoint(x: size.width / 2, y: size.height - 20 - playbackHeight / 2) }
    var framingInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: playbackHeight + 40, right: 0) }
}

/// Zoom levels for the plus and minus buttons. Each step changes the size by the same proportion.
enum CropZoomStops {
    static let minimum = 0.1
    /// Maximum zoom. Set 10 for 1000%.
    static let maximum = 10.0
    static var range: ClosedRange<Double> { minimum...maximum }
    static let values: [Double] = {
        let firstExponent = Int(ceil(log2(minimum) * 4))
        let lastExponent = Int(floor(log2(maximum) * 4))
        let stops = (firstExponent...lastExponent).map { pow(2.0, Double($0) / 4) }
        return [minimum] + stops.filter { $0 > minimum && $0 < maximum } + [maximum]
    }()
    static func next(from zoom: Double, increasing: Bool) -> Double {
        increasing
        ? (values.first { $0 > zoom + 0.000001 } ?? maximum)
        : (values.last { $0 < zoom - 0.000001 } ?? minimum)
    }
}

/// Use English number formatting, such as 15.4 MB.
enum CropFormatting {
    static let locale = Locale(identifier: "en_US")
    static let seconds = FloatingPointFormatStyle<Double>.number
        .grouping(.never)
        .precision(.fractionLength(2))
        .locale(locale)
}

// MARK: Window Menus

/// Attach explicitly requested tabs and track the active export window.
@MainActor @Observable
final class CropWindowRegistry {
    static let shared = CropWindowRegistry()
    
    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow? = nil) { self.window = window }
    }
    
    private var tabParents: [UUID: WindowReference] = [:]
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    @ObservationIgnored private var focusObservers: [NSObjectProtocol] = []
    /// Save applies to the export window the user is working in.
    private(set) var activeExport: ExportDocument?
    
    private init() {
        for notificationName in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow else { return }
                    self?.activeExport = window.windowController?.document as? ExportDocument
                }
            })
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow else { return }
                if self.activeExport === window.windowController?.document { self.activeExport = nil }
            }
        }
    }
    
    func requestTab(_ identity: UUID, parent: NSWindow) {
        tabParents[identity] = WindowReference(parent)
    }
    
    func attach(_ window: NSWindow, identity: UUID) {
        window.tabbingIdentifier = "GoodFrame.Editor"
        window.tabbingMode = .automatic
        if let parent = tabParents.removeValue(forKey: identity)?.window, parent !== window {
            parent.addTabbedWindow(window, ordered: .above)
        }
    }
    
    
}

/// The actions available in the current window, such as Open, Export, and Fit.
struct CropWindowActions {
    var open: () -> Void
    var close: () -> Void
    var export: () -> Void
    var fit: () -> Void
    var actualSize: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var preview: () -> Void
    var inspector: () -> Void
    var resetCrop: () -> Void
    var matchBitrate: () -> Void
    var canOpen: Bool
    var canExport: Bool
    var canEdit: Bool
    var canMatchBitrate: Bool
    var isImage: Bool
    var isHDR: Bool
    var bitrateRange: ClosedRange<Double>
    var previewing: Bool
    var inspecting: Bool
}

extension FocusedValues {
    @Entry var cropWindowActions: CropWindowActions?
    @Entry var cropHistory: EditHistory?
    @Entry var cropPlayback: PlaybackState?
}

/// The app menus and their keyboard shortcuts.
struct CropWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.cropWindowActions) private var actions
    @FocusedValue(\.cropHistory) private var history
    @FocusedValue(\.cropPlayback) private var playback
    
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "cropper", value: UUID()) }
                .keyboardShortcut("n")
            Button("New Tab") {
                guard let parent = NSApp.keyWindow else { return }
                let identity = UUID()
                CropWindowRegistry.shared.requestTab(identity, parent: parent)
                openWindow(id: "cropper", value: identity)
            }
            .keyboardShortcut("t")
            .disabled(actions == nil)
            Divider()
            Button("Open…") { actions?.open() }
                .keyboardShortcut("o")
                .disabled(actions?.canOpen != true)
            Button("Close File") { actions?.close() }
                .disabled(actions?.canEdit != true)
        }
        /// Export and save the result, followed by the standard Close commands.
        CommandGroup(before: .saveItem) {
            Button(actions?.isImage == true ? "Export Image…" : (history?.exportsFrame == true ? "Export Current Frame…" : "Export Video…")) { actions?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.canExport != true)
            Button("Save…") { CropWindowRegistry.shared.activeExport?.save(nil) }
                .keyboardShortcut("s")
                .disabled(CropWindowRegistry.shared.activeExport == nil)
                .help("Save the exported file")
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { actions?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(actions?.canEdit != true)
            Button("Zoom Out") { actions?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(actions?.canEdit != true)
            Button("Zoom to Fit") { actions?.fit() }
                .keyboardShortcut("0")
                .disabled(actions?.canEdit != true)
            Button("Actual Size") { actions?.actualSize() }
                .keyboardShortcut("1")
                .disabled(actions?.canEdit != true)
            
            Divider()
            
            Button(actions?.inspecting == true ? "Hide Inspector" : "Show Inspector") { actions?.inspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions?.canEdit != true)
        }
        CommandMenu("Playback") {
            Button(playback?.isPlaying == true ? "Pause" : "Play") { playback?.togglePlayback() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(playback == nil)
            Divider()
            Button("Previous Frame") { playback?.step(by: -1) }
                .keyboardShortcut("[", modifiers: [])
                .disabled(playback == nil || playback?.selectedFrame == 0)
            Button("Next Frame") { playback?.step(by: 1) }
                .keyboardShortcut("]", modifiers: [])
                .disabled(playback == nil || (playback?.selectedFrame ?? 0) >= (playback?.frameCount ?? 0) - 1)
            Divider()
            Button(playback?.isMuted == true ? "Unmute" : "Mute") { playback?.toggleMute() }
                .disabled(playback == nil)
        }
        CommandMenu("Crop") {
            Button(actions?.previewing == true ? "Exit Preview" : "Preview Crop") { actions?.preview() }
                .keyboardShortcut("p")
                .disabled(actions?.canEdit != true)
            Button("Reset Crop") { actions?.resetCrop() }
                .disabled(actions?.canEdit != true)
        }
        CommandMenu("Encode") {
            Group {
                if actions?.isImage == true {
                    Picker("Format", selection: Binding(
                        get: { history?.imageEncoding.format ?? .png },
                        set: { history?.imageEncoding.format = $0 })) {
                            Text("PNG")
                                .tag(ImageEncodingSettings.Format.png)
                            Text("JPEG")
                                .tag(ImageEncodingSettings.Format.jpeg)
                        }
                } else {
                    Picker("Format", selection: Binding(
                        get: { history?.exportFormat ?? .hevc },
                        set: { history?.exportFormat = $0 })) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.rawValue)
                                    .tag(format)
                                    .disabled(actions?.isHDR == true && format == .h264)
                            }
                        }
                }
                Divider()
                if actions?.isImage == true || history?.exportsFrame == true {
                    Button("Increase Quality") { adjustQuality(by: 0.05) }
                        .disabled(history?.imageEncoding.format != .jpeg || (history?.imageEncoding.quality ?? 1) >= 1)
                    Button("Decrease Quality") { adjustQuality(by: -0.05) }
                        .disabled(history?.imageEncoding.format != .jpeg || (history?.imageEncoding.quality ?? 0) <= 0)
                    Button("Reset Quality") { history?.imageEncoding.quality = ImageEncodingSettings().quality }
                        .disabled(history?.imageEncoding.format != .jpeg)
                } else {
                    Button("Increase Bitrate") { adjustBitrate(by: 0.5) }
                        .disabled((history?.bitrate ?? 0) >= (actions?.bitrateRange.upperBound ?? 40))
                    Button("Decrease Bitrate") { adjustBitrate(by: -0.5) }
                        .disabled((history?.bitrate ?? 0) <= (actions?.bitrateRange.lowerBound ?? 0.5))
                    Button("Match Original Bitrate") { actions?.matchBitrate() }
                        .disabled(actions?.canMatchBitrate != true)
                }
            }
            .disabled(actions?.canEdit != true)
        }
    }
    
    /// Give the menu the same quality range as the inspector slider.
    private func adjustQuality(by amount: Double) {
        guard let history else { return }
        history.imageEncoding.quality = min(1, max(0, history.imageEncoding.quality + amount))
    }
    
    /// Change video bitrate in half-megabit steps.
    private func adjustBitrate(by amount: Double) {
        guard let history, let actions else { return }
        history.bitrate = min(actions.bitrateRange.upperBound, max(actions.bitrateRange.lowerBound, history.bitrate + amount))
    }
}

// MARK: Main View

struct EditorView: View {
    let windowIdentity: UUID
    init(windowIdentity: UUID = UUID()) { self.windowIdentity = windowIdentity }
    @State private var sourceURL: URL?
    @State private var player: AVPlayer?
    @State private var playback = PlaybackState()
    @State private var imageSource: ImageSource?
    @State private var sourceSize = CGSize.zero
    @State private var sourceMbps = 0.0
    @State private var sourceFPS = 0.0
    @State private var sourceBytes: Int64 = 0
    @State private var sourceIsHDR = false
    @State private var videoHasTransparency = false
    @State private var previewOnly = false
    @State private var dropTargeted = false
    @State private var showInspector = true
    @State private var playbackHeight: CGFloat = 48
    private let inspectorWidth: CGFloat = 320
    @State private var canvasColor = Color(nsColor: CropAppearance.canvas)
    @State private var history = EditHistory()
    @State private var cameraRequest = 0
    @State private var centerCameraOnRequest = true
    private var crop: CropMargins { history.value.crop }
    private var settings: EncodingSettings { history.value.encoding }
    
    private var cropBinding: Binding<CropMargins> { $history.crop }
    @State private var zoom = 1.0
    @State private var fit = true
    @State private var duration = 0.0
    @State private var busy = false
    @State private var exportState = CropExportState()
    @State private var openError: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportError: String?
    
    private var loaded: Bool { sourceURL != nil }
    /// An empty editor can receive a Finder file. Occupied editors let SwiftUI open another scene.
    private var incomingFileEvents: Set<String> { !loaded && !busy ? ["*"] : [] }
    private var isImage: Bool { imageSource != nil }
    private var outputWidth: Int { Int(sourceSize.width) - crop.left - crop.right }
    private var outputHeight: Int { Int(sourceSize.height) - crop.top - crop.bottom }
    private var validCrop: Bool {
        let minimum = history.pixelStep
        return [crop.left, crop.top, crop.right, crop.bottom].allSatisfy { $0 >= 0 }
        && outputWidth >= minimum && outputHeight >= minimum
        && (isImage || (outputWidth.isMultiple(of: 2) && outputHeight.isMultiple(of: 2)))
    }
    
    /// The image or video canvas, inspector, and video timeline.
    var body: some View {
        GeometryReader { geometry in
            let layout = CropWorkspaceLayout(size: geometry.size, playbackHeight: player == nil ? 0 : playbackHeight)
            
            ZStack(alignment: .topTrailing) {
                (loaded ? canvasColor : Color(nsColor: .windowBackgroundColor))
                CropCanvas(
                    player: player, image: imageSource?.image, sourceSize: sourceSize, crop: cropBinding, zoom: $zoom, fit: $fit,
                    previewOnly: previewOnly, cameraRequest: cameraRequest, centerCameraOnRequest: centerCameraOnRequest, framingInsets: player == nil ? NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20) : layout.framingInsets,
                    history: history, playback: !busy && !isImage ? playback : nil, windowIdentity: windowIdentity, canvasColor: loaded ? NSColor(canvasColor) : .windowBackgroundColor, onFit: requestFit,
                    onExitPreview: { previewOnly = false }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .disabled(busy)
                if !loaded {
                    EmptyCanvasView(open: openMedia, sample: loadSample)
                        .disabled(busy)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if player != nil {
                    PlaybackControls(playback: playback)
                        .disabled(busy)
                        .cropPanel()
                        .frame(width: layout.playbackWidth)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            playbackHeight = $0
                        }
                        .position(layout.playbackCenter)
                }
            }
        }
        .inspector(isPresented: Binding(get: { loaded && showInspector }, set: { showInspector = $0 })) {
            InspectorView(
                history: history, imageSource: imageSource, sourceSize: sourceSize, sourceMbps: sourceMbps,
                sourceFPS: sourceFPS, sourceBytes: sourceBytes, sourceIsHDR: sourceIsHDR, duration: duration, videoHasTransparency: videoHasTransparency,
                loaded: loaded, busy: busy, canvasColor: $canvasColor,
                exportState: exportState, canExport: canExport, export: exportMedia,
                cancel: { exportTask?.cancel() }
            )
            .inspectorColumnWidth(inspectorWidth)
        }
        .overlay {
            if dropTargeted {
                DropHighlightView()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .environment(\.locale, CropFormatting.locale)
        /// Get the product name from project settings and display in title bar
        .navigationTitle(sourceURL?.lastPathComponent ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""))
        .background {
            EditorToolbar(
                zoom: $zoom, fit: $fit, loaded: loaded, busy: busy,
                canUndo: history.canUndo, canRedo: history.canRedo, previewOnly: previewOnly,
                open: openMedia, undo: undoEdit, redo: redoEdit,
                preview: { previewOnly.toggle() }, inspector: toggleInspector,
                step: requestZoomStep, actualSize: requestActualSize, fitVideo: requestFit)
            .frame(width: 0, height: 0)
        }
        .focusedSceneValue(\.cropHistory, history)
        .focusedSceneValue(\.cropPlayback, loaded && !isImage && !busy ? playback : nil)
        .focusedSceneValue(\.cropWindowActions, windowActions)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: receiveMedia)
        /// Open files sent by Finder, including drops onto the app icon.
        .onOpenURL { url in
            if url.isFileURL { loadMedia(url) }
        }
        /// SwiftUI reuses an empty editor or opens a new one according to the Mac's tab preference.
        .handlesExternalEvents(preferring: incomingFileEvents, allowing: incomingFileEvents)
        .onExitCommand { previewOnly = false }
        .onChange(of: history.exportsFrame) {
            if history.exportsFrame { playback.pause() }
        }
        .alert("Could Not Open File", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .alert("Could Not Export File", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        /// Ask before closing a window that is exporting.
        .dismissalConfirmationDialog("Cancel Export and Close?", shouldPresent: busy) {
            Button("Keep Exporting", role: .cancel) { }
            Button("Cancel Export and Close", role: .destructive) {
                exportTask?.cancel()
            }
        } message: {
            Text("The unfinished export will be discarded.")
        }
        .onAppear { _ = ExportTemporaryStorage.shared }
        .onDisappear { exportTask?.cancel() }
    }
    
    /// Show or hide the inspector with an animation.
    private func toggleInspector() { withAnimation { showInspector.toggle() } }
    
    private func undoEdit() { CropUndoRouting.perform(history, redo: false) }
    private func redoEdit() { CropUndoRouting.perform(history, redo: true) }
    
    private var canExport: Bool {
        loaded && validCrop && !busy && (isImage || (history.exportsFrame
                                                     ? playback.frameCount > 0
                                                     : settings.isValid && (!sourceIsHDR || settings.codec == .hevc)))
    }
    private var originalBitrate: Double { sourceMbps.isFinite && sourceMbps > 0 ? sourceMbps : 2.5 }
    private func requestFit() {
        fit = true
        centerCameraOnRequest = true
        cameraRequest += 1
    }
    private func requestActualSize() {
        zoom = 1
        fit = false
        centerCameraOnRequest = true
        cameraRequest += 1
    }
    
    /// Animate one zoom step while keeping the current part of the video in view.
    private func requestZoomStep(increasing: Bool) {
        zoom = CropZoomStops.next(from: zoom, increasing: increasing)
        fit = false
        centerCameraOnRequest = false
        cameraRequest += 1
    }
    
    /// Connect menu commands to this window.
    private var windowActions: CropWindowActions {
        CropWindowActions(
            open: openMedia, close: closeMedia, export: exportMedia, fit: requestFit, actualSize: requestActualSize,
            zoomIn: { requestZoomStep(increasing: true) }, zoomOut: { requestZoomStep(increasing: false) },
            preview: { previewOnly.toggle() }, inspector: toggleInspector,
            resetCrop: { cropBinding.wrappedValue = .fullImage(sourceSize, multiple: history.pixelStep) },
            matchBitrate: { history.bitrate = originalBitrate },
            canOpen: !busy, canExport: canExport, canEdit: loaded && !busy, canMatchBitrate: loaded && !isImage && !history.exportsFrame && !busy,
            isImage: isImage, isHDR: sourceIsHDR, bitrateRange: EncodingSettings.bitrateRange(for: sourceMbps),
            previewing: previewOnly, inspecting: showInspector)
    }
    
    /// Open an image or video dropped onto the window.
    private func receiveMedia(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) } else { url = item as? URL }
            Task { @MainActor in
                guard !busy else { return }
                if let url, url.isFileURL { loadMedia(url) } else { openError = error?.localizedDescription ?? "Drop a local image or video file." }
            }
        }
        return true
    }
    
    /// Choose an image or video to crop.
    private func openMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video] + ImageSource.supportedTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        loadMedia(selectedURL)
    }
    
    /// Open the sample video included with the app.
    private func loadSample() {
        guard let sampleURL = Bundle.main.url(forResource: "Good Frame Sample", withExtension: "mov") else {
            openError = String(localized: "The bundled sample video is unavailable.")
            return
        }
        loadMedia(sampleURL)
    }
    
    /// Close the file and return to the empty screen.
    private func closeMedia() {
        guard !busy else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playback.disconnect()
        player = nil
        imageSource = nil
        sourceURL = nil
        sourceSize = .zero
        sourceMbps = 0
        sourceFPS = 0
        sourceBytes = 0
        sourceIsHDR = false
        videoHasTransparency = false
        duration = 0
        previewOnly = false
        zoom = 1
        fit = true
        history.reset(CropEdit())
        exportState.message = nil
    }
    
    /// Open the file, read its size, and show the inspector.
    private func loadMedia(_ selectedURL: URL) {
        exportState.progress = nil
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let contentType = try selectedURL.resourceValues(forKeys: [.contentTypeKey]).contentType
                if contentType?.conforms(to: .image) == true {
                    let source = try await Task.detached(priority: .userInitiated) { try ImageSource.load(selectedURL) }.value
                    player?.pause()
                    player?.replaceCurrentItem(with: nil)
                    playback.disconnect()
                    player = nil
                    imageSource = source
                    sourceURL = selectedURL
                    showInspector = true
                    sourceSize = CGSize(width: source.image.width, height: source.image.height)
                    sourceBytes = source.bytes
                    sourceMbps = 0
                    sourceFPS = 0
                    sourceIsHDR = false
                    self.duration = 0
                    history.pixelStep = 1
                    history.reset(CropEdit(crop: .fullImage(sourceSize, multiple: 1), imageEncoding: ImageEncodingSettings(format: source.type == .jpeg ? .jpeg : .png)))
                    fit = true
                    cameraRequest += 1
                    previewOnly = false
                    exportState.message = nil
                    return
                }
                let asset = AVURLAsset(url: selectedURL)
                let geometry = try await VideoExporter.geometry(for: asset)
                let duration = try await asset.load(.duration).seconds
                let frameRate = try await geometry.track.load(.nominalFrameRate)
                let dataRate = try await geometry.track.load(.estimatedDataRate)
                let fileSize = try selectedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let color = try await VideoExporter.colorInfo(for: geometry.track)
                let frames = try await Task.detached(priority: .userInitiated) {
                    try VideoFrameIndex.load(asset: asset, track: geometry.track, duration: duration)
                }.value
                imageSource = nil
                history.pixelStep = 2
                sourceIsHDR = color.isHDR
                videoHasTransparency = try await geometry.track.load(.mediaCharacteristics).contains(.containsAlphaChannel)
                sourceBytes = Int64(fileSize)
                sourceSize = geometry.bounds.size
                sourceMbps = Double(dataRate) / 1_000_000
                sourceFPS = Double(frameRate)
                sourceURL = selectedURL
                showInspector = true
                player?.pause()
                let openedPlayer = AVPlayer(url: selectedURL)
                player = openedPlayer
                playback.connect(to: openedPlayer, frames: frames, duration: duration)
                let originalRate = originalBitrate
                history.reset(
                    CropEdit(
                        crop: .fullImage(sourceSize), encoding: EncodingSettings(codec: color.isHDR ? .hevc : settings.codec, megabitsPerSecond: originalRate)))
                self.duration = duration
                fit = true
                previewOnly = false
                exportState.message = nil
            } catch {
                openError = error.localizedDescription
            }
        }
    }
    
    /// Export an opened image or the selected video frame, then open the export window.
    private func exportImage(sourceURL: URL) {
        /// Remember which window started this export.
        let exportWindow = NSApp.keyWindow
        let selectedCrop = crop.rectangle(in: sourceSize)
        let selectedSettings = history.imageEncoding
        let openedImage = imageSource
        let frameTime = openedImage == nil ? playback.pauseForExport() : nil
        let frameNumber = openedImage == nil ? playback.selectedFrame + 1 : nil
        let destination = ExportTemporaryStorage.shared.directory.appendingPathComponent("GoodFrame-\(UUID().uuidString).\(selectedSettings.format.fileExtension)")
        busy = true
        exportState.bytes = 0
        exportState.progress = 0
        exportState.indeterminate = true
        exportState.message = nil
        exportTask = Task { @MainActor in
            var handedOff = false
            defer {
                if !handedOff { try? FileManager.default.removeItem(at: destination) }
                busy = false
                exportState.progress = nil
                exportState.indeterminate = false
                exportTask = nil
            }
            let started = Date()
            let worker = Task.detached(priority: .userInitiated) {
                let image: ImageSource
                if let openedImage {
                    image = openedImage
                } else if let frameTime {
                    image = try await VideoFrameExporter.image(from: sourceURL, at: frameTime)
                } else {
                    throw ImageError.unreadableFrame
                }
                try Task.checkCancellation()
                try ImageExporter.export(source: image, destination: destination, crop: selectedCrop, settings: selectedSettings)
                return image.isHDR
            }
            do {
                let isHDR = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let summary = ExportSummary(
                    codec: selectedSettings.format.rawValue, bitrate: 0, bytes: Int64(bytes), elapsed: Date().timeIntervalSince(started),
                    isHDR: isHDR, resolution: selectedCrop.size, imageFormat: selectedSettings.format.rawValue)
                let suffix = frameNumber.map { "-frame-\($0)" } ?? "-framed"
                let document = try ExportDocument(
                    exportURL: destination, title: sourceURL.deletingPathExtension().lastPathComponent + suffix,
                    summary: summary, contentType: selectedSettings.format.contentType, parentWindow: exportWindow)
                NSDocumentController.shared.addDocument(document)
                document.makeWindowControllers()
                document.showWindows()
                handedOff = true
            } catch {
                if Task.isCancelled {
                    exportState.message = "Export cancelled"
                } else {
                    exportState.message = "Export failed"
                    exportError = error.localizedDescription
                }
            }
        }
    }
    
    /// Export the crop, then open the export window.
    private func exportMedia() {
        /// Remember which window started this export.
        let exportWindow = NSApp.keyWindow
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard canExport, let sourceURL else { return }
        if imageSource != nil || history.exportsFrame {
            exportImage(sourceURL: sourceURL)
            return
        }
        let selectedCrop = crop.rectangle(in: sourceSize)
        let selectedSettings = settings
        previewOnly = false
        withAnimation { showInspector = true }
        player?.pause()
        busy = true
        let operation = UUID()
        exportState.operation = operation
        exportState.bytes = 0
        exportState.progress = 0
        exportState.message = nil
        exportTask = Task { @MainActor in
            let destinationURL = ExportTemporaryStorage.shared.directory.appendingPathComponent("GoodFrame-\(UUID().uuidString).mov")
            var handedOff = false
            defer {
                if !handedOff { try? FileManager.default.removeItem(at: destinationURL) }
                busy = false
                exportState.operation = nil
                exportState.progress = nil
                exportTask = nil
            }
            do {
                let started = Date()
                try await VideoExporter.export(
                    source: sourceURL, destination: destinationURL, crop: selectedCrop, settings: selectedSettings,
                    fileSize: { bytes in Task { @MainActor in if exportState.operation == operation { exportState.bytes = bytes } } },
                    progress: { value in Task { @MainActor in if exportState.operation == operation { exportState.progress = value } } })
                try Task.checkCancellation()
                let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
                let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let summary = ExportSummary(
                    codec: selectedSettings.codec.rawValue, bitrate: selectedSettings.megabitsPerSecond,
                    bytes: bytes, elapsed: Date().timeIntervalSince(started), isHDR: sourceIsHDR, resolution: selectedCrop.size)
                let document = try ExportDocument(
                    exportURL: destinationURL, title: sourceURL.deletingPathExtension().lastPathComponent + "-framed", summary: summary, parentWindow: exportWindow)
                NSDocumentController.shared.addDocument(document)
                document.makeWindowControllers()
                document.showWindows()
                handedOff = true
                exportState.message = nil
            } catch {
                if Task.isCancelled {
                    exportState.message = "Export cancelled"
                } else {
                    exportState.message = "Export failed"
                    exportError = error.localizedDescription
                }
            }
        }
    }
    
}

/// Highlight the file drop area using the window's corner shape.
struct DropHighlightView: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            ConcentricRectangle()
                .stroke(Color.accentColor, lineWidth: 3)
                .padding(6)
        } else {
            ContainerRelativeShape()
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(6)
        }
    }
}

/// Invite the user to open or drop a file when the canvas is empty.
struct EmptyCanvasView: View {
    let open: () -> Void
    let sample: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            /// The app's icon welcomes a new image or video.
            Image("good-frame-768-light-drop")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .accessibilityHidden(true)
            
            VStack(spacing: 12) {
                Button(action: open) {
                    Text("Drop or Open…")
                        .frame(minWidth: 120)
                }
                .welcomeButtonStyle()
                .controlSize(.large)
                Button(action: sample) {
                    Text("Sample Video")
                        .underline()
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }
}

// MARK: Editor Controls

/// The zoom slider, plus and minus buttons, percentage, and Fit button.
struct ZoomControls: View {
    @Binding var zoom: Double
    @Binding var fit: Bool
    let enabled: Bool
    let step: (Bool) -> Void
    let actualSize: () -> Void
    let fitVideo: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            /// Make the whole button clickable, including the space around the icon.
            Button("Zoom Out", systemImage: "minus") {
                step(false)
            }
            .labelStyle(.iconOnly)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            /// Repeat zoom steps while the mouse button is held.
            .buttonRepeatBehavior(.enabled)
            .disabled(zoom <= CropZoomStops.minimum)
            .help("Zoom out (⌘−)")
            
            Slider(
                value: Binding(
                    get: { zoom },
                    set: {
                        zoom = $0
                        fit = false
                    }), in: CropZoomStops.range
            )
            .frame(width: 160)
            .accessibilityLabel("Canvas zoom")
            .help("Adjust canvas zoom")
            
            Button("Zoom In", systemImage: "plus") {
                step(true)
            }
            .labelStyle(.iconOnly)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .buttonRepeatBehavior(.enabled)
            .disabled(zoom >= CropZoomStops.maximum)
            .help("Zoom in (⌘+)")
            
            /// Show the zoom percentage with no digit grouping.
            Button(action: actualSize) {
                Text(verbatim: "\(Int((zoom * 100).rounded()))%")
            }
            .monospacedDigit()
            .buttonStyle(.plain)
            .frame(width: 48)
            .help("Actual size (⌘1)")
            Button("Fit", action: fitVideo)
                .buttonStyle(.plain)
                .frame(width: 40, height: 28)
                .help("Fit to window (⌘0)")
        }
        .padding(.horizontal, 6)
        .fixedSize()
        .disabled(!enabled)
    }
}

/// Connect the editor's actions to its native window toolbar.
struct EditorToolbar: NSViewRepresentable {
    @Binding var zoom: Double
    @Binding var fit: Bool
    let loaded: Bool
    let busy: Bool
    let canUndo: Bool
    let canRedo: Bool
    let previewOnly: Bool
    let open: () -> Void
    let undo: () -> Void
    let redo: () -> Void
    let preview: () -> Void
    let inspector: () -> Void
    let step: (Bool) -> Void
    let actualSize: () -> Void
    let fitVideo: () -> Void
    
    func makeNSView(context: Context) -> EditorToolbarView {
        EditorToolbarView(actions: self)
    }
    
    func updateNSView(_ view: EditorToolbarView, context: Context) {
        view.update(self)
    }
}

/// Own the toolbar for this editor window.
final class EditorToolbarView: NSView, NSToolbarDelegate, NSMenuItemValidation {
    private var actions: EditorToolbar
    private let editorToolbar = NSToolbar(identifier: "GoodFrame.EditorToolbar")
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let zoomView: NSHostingView<ZoomControls>
    private let zoomMenu = NSMenu(title: "Zoom")
    
    private static let openID = NSToolbarItem.Identifier("open")
    private static let undoID = NSToolbarItem.Identifier("undo")
    private static let redoID = NSToolbarItem.Identifier("redo")
    private static let previewID = NSToolbarItem.Identifier("preview")
    private static let zoomID = NSToolbarItem.Identifier("zoom")
    private static let inspectorID = NSToolbarItem.Identifier("inspector")
    
    init(actions: EditorToolbar) {
        self.actions = actions
        zoomView = NSHostingView(rootView: ZoomControls(
            zoom: actions.$zoom, fit: actions.$fit, enabled: actions.loaded && !actions.busy,
            step: actions.step, actualSize: actions.actualSize, fitVideo: actions.fitVideo))
        super.init(frame: .zero)
        editorToolbar.delegate = self
        editorToolbar.displayMode = .iconOnly
        zoomView.sizingOptions = [.intrinsicContentSize]
        
        addButton(Self.openID, title: "Open…", symbol: "folder", help: "Open an image or video (⌘O)", action: #selector(openMedia))
        addButton(Self.undoID, title: "Undo", symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: #selector(undoEdit))
        addButton(Self.redoID, title: "Redo", symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: #selector(redoEdit))
        addButton(Self.previewID, title: "Preview Crop", symbol: "eye", help: "Preview the crop (⌘P)", action: #selector(togglePreview))
        addButton(Self.inspectorID, title: "Inspector", symbol: "sidebar.right", help: "Show or hide the inspector (⌥⌘I)", action: #selector(toggleInspector))
        
        /// One glass background for the complete zoom control.
        let zoomItem = NSToolbarItemGroup(itemIdentifier: Self.zoomID)
        zoomItem.label = "Zoom"
        zoomItem.paletteLabel = "Zoom"
        zoomItem.autovalidates = false
        zoomItem.view = zoomView
        
        /// The overflow menu contains actions, not the slider.
        for (title, selector) in [
            ("Zoom Out", #selector(zoomOut)), ("Zoom In", #selector(zoomIn)),
            ("Actual Size", #selector(actualSize)), ("Fit", #selector(fitVideo))
        ] {
            let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            menuItem.target = self
            zoomMenu.addItem(menuItem)
        }
        let menuItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        menuItem.submenu = zoomMenu
        zoomItem.menuFormRepresentation = menuItem
        items[Self.zoomID] = zoomItem
        update(actions)
    }
    
    required init?(coder: NSCoder) { fatalError("Use init(actions:)") }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.toolbar = editorToolbar
    }
    
    private func addButton(_ identifier: NSToolbarItem.Identifier, title: String, symbol: String, help: String, action: Selector) {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.paletteLabel = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.toolTip = help
        item.target = self
        item.action = action
        item.autovalidates = false
        if #available(macOS 26.0, *) {
            item.isNavigational = [Self.openID, Self.undoID, Self.redoID].contains(identifier)
        }
        items[identifier] = item
    }
    
    func update(_ actions: EditorToolbar) {
        self.actions = actions
        let enabled = actions.loaded && !actions.busy
        items[Self.openID]?.isEnabled = !actions.busy
        items[Self.undoID]?.isEnabled = actions.canUndo && !actions.busy
        items[Self.redoID]?.isEnabled = actions.canRedo && !actions.busy
        items[Self.previewID]?.isEnabled = enabled
        items[Self.zoomID]?.isEnabled = enabled
        items[Self.inspectorID]?.isEnabled = enabled
        items[Self.previewID]?.label = actions.previewOnly ? "Exit Preview" : "Preview Crop"
        items[Self.previewID]?.image = NSImage(systemSymbolName: actions.previewOnly ? "eye.slash" : "eye", accessibilityDescription: nil)
        zoomView.rootView = ZoomControls(
            zoom: actions.$zoom, fit: actions.$fit, enabled: enabled,
            step: actions.step, actualSize: actions.actualSize, fitVideo: actions.fitVideo)
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.openID, Self.undoID, Self.redoID, .flexibleSpace, Self.previewID, .space, Self.zoomID, .space, Self.inspectorID]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        items[identifier]
    }
    
    /// Keep overflow commands in sync with the zoom limits.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard actions.loaded && !actions.busy else { return false }
        if menuItem.action == #selector(zoomOut) { return actions.zoom > CropZoomStops.minimum }
        if menuItem.action == #selector(zoomIn) { return actions.zoom < CropZoomStops.maximum }
        return true
    }
    
    @objc private func openMedia() { actions.open() }
    @objc private func undoEdit() { actions.undo() }
    @objc private func redoEdit() { actions.redo() }
    @objc private func togglePreview() { actions.preview() }
    @objc private func toggleInspector() { actions.inspector() }
    @objc private func zoomOut() { actions.step(false) }
    @objc private func zoomIn() { actions.step(true) }
    @objc private func actualSize() { actions.actualSize() }
    @objc private func fitVideo() { actions.fitVideo() }
}

/// Export progress, file size, and status message.
@MainActor @Observable
final class CropExportState {
    
    var indeterminate = false
    var progress: Double?
    var operation: UUID?
    var bytes: Int64 = 0
    var message: LocalizedStringKey?
    
}

/// The inspector with video information, crop fields, encoding options, and canvas color.
struct InspectorView: View {
    @Bindable var history: EditHistory
    let imageSource: ImageSource?
    let sourceSize: CGSize
    let sourceMbps: Double
    let sourceFPS: Double
    let sourceBytes: Int64
    let sourceIsHDR: Bool
    let duration: Double
    let videoHasTransparency: Bool
    let loaded: Bool
    let busy: Bool
    @Binding var canvasColor: Color
    let exportState: CropExportState
    let canExport: Bool
    let export: () -> Void
    let cancel: () -> Void
    private var crop: CropMargins { history.crop }
    private var cropBinding: Binding<CropMargins> { $history.crop }
    private var outputWidth: Int { Int(sourceSize.width) - crop.left - crop.right }
    private var outputHeight: Int { Int(sourceSize.height) - crop.top - crop.bottom }
    private var originalBitrate: Double { sourceMbps.isFinite && sourceMbps > 0 ? sourceMbps : 2.5 }
    
    /// Arrange the inspector controls in sections.
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let imageSource {
                        CropInspectorSection("Original") {
                            CropOriginalRow("Format", value: imageSource.formatName)
                            CropOriginalRow("Resolution", value: "\(Int(sourceSize.width)) × \(Int(sourceSize.height))")
                                .help("Pixels")
                            CropOriginalRow("Size", value: sourceBytes.formatted(.byteCount(style: .file).locale(CropFormatting.locale)))
                            if let profile = imageSource.colorProfileName {
                                CropOriginalRow("Color profile", value: profile)
                            }
                        }
                    } else {
                        CropOriginalSection(
                            size: sourceSize, bitrate: sourceMbps, frameRate: sourceFPS,
                            duration: duration, bytes: sourceBytes, loaded: loaded, isHDR: sourceIsHDR)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            Text("Crop")
                                .font(.headline)
                            Spacer()
                            Text(!loaded ? "— × —" : "\(outputWidth) × \(outputHeight) px")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            CropResetButton("Reset Crop") { cropBinding.wrappedValue = .fullImage(sourceSize, multiple: history.pixelStep) }
                        }
                        /// Place the margin fields around the width and height fields.
                        VStack(spacing: 8) {
                            marginField("Top", edge: .top)
                                .frame(width: 132)
                            HStack(spacing: 8) {
                                marginField("Left", edge: .left)
                                VStack(alignment: .leading, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Width")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        dimensionField("Width", horizontal: true)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Height")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        dimensionField("Height", horizontal: false)
                                    }
                                }
                                .padding(8)
                                .frame(width: 132)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(.separator, lineWidth: 1)
                                }
                                marginField("Right", edge: .right)
                            }
                            marginField("Bottom", edge: .bottom)
                                .frame(width: 132)
                        }
                    }
                    .disabled(!loaded || busy)
                    if let imageSource {
                        ImageEncodingSection(history: history, hasTransparency: imageSource.hasTransparency)
                            .disabled(busy)
                    } else {
                        CropEncodingSection(
                            history: history, originalBitrate: originalBitrate, sourceMbps: sourceMbps,
                            loaded: loaded, busy: busy, isHDR: sourceIsHDR, hasTransparency: videoHasTransparency)
                    }
                    CropCanvasSection(color: $canvasColor)
                }
                .controlSize(.small)
                .padding(16)
            }
            Divider()
                .opacity(0.45)
            CropExportFooter(
                state: exportState, canExport: canExport, loaded: loaded,
                outputWidth: outputWidth, outputHeight: outputHeight,
                encodingName: imageSource == nil ? history.exportFormat.rawValue : history.imageEncoding.format.rawValue,
                exportTitle: imageSource != nil ? "Export Image" : (history.exportsFrame ? "Export Current Frame" : "Export Video"),
                export: export, cancel: cancel)
        }
    }
    
    /// A crop margin field and its stepper.
    private func marginField(_ title: String, edge: CropMargins.Edge) -> some View {
        let value = Binding<Int>(
            get: { crop[edge] },
            set: { requested in
                var updated = crop
                updated.set(edge, to: requested, in: sourceSize, multiple: history.pixelStep)
                cropBinding.wrappedValue = updated
            })
        
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                CropNumberField(value: value, label: title, history: history, showsPlaceholder: !loaded)
                    .frame(height: 22)
                pixelStepper(value, title: title)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    /// A crop width or height field and its stepper.
    private func dimensionField(_ title: String, horizontal: Bool) -> some View {
        let value = Binding<Int>(
            get: { horizontal ? outputWidth : outputHeight },
            set: { requested in
                history.resizeCrop(
                    width: horizontal ? requested : outputWidth,
                    height: horizontal ? outputHeight : requested, in: sourceSize)
            })
        
        return HStack(spacing: 4) {
            CropDimensionField(
                value: value, maximum: Int(horizontal ? sourceSize.width : sourceSize.height), label: title, history: history, showsPlaceholder: !loaded
            )
            .frame(height: 22)
            pixelStepper(value, title: title)
        }
    }
    
    /// Apply any typed value before increasing or decreasing it.
    private func pixelStepper(_ value: Binding<Int>, title: String) -> some View {
        Stepper(
            title,
            onIncrement: {
                NSApp.keyWindow?.makeFirstResponder(nil)
                value.wrappedValue += history.pixelStep
            },
            onDecrement: {
                NSApp.keyWindow?.makeFirstResponder(nil)
                value.wrappedValue -= history.pixelStep
            }
        )
        .labelsHidden()
        .fixedSize()
        /// Tab moves between fields. Arrow keys adjust the focused number.
        .focusable(false)
        .help("Pixels")
    }
    
}

/// Information about the opened video.
struct CropOriginalSection: View {
    let size: CGSize
    let bitrate: Double
    let frameRate: Double
    let duration: Double
    let bytes: Int64
    let loaded: Bool
    let isHDR: Bool
    
    var body: some View {
        CropInspectorSection("Original") {
            CropOriginalRow("Dynamic range", value: loaded ? (isHDR ? "HDR" : "SDR") : "—")
            CropOriginalRow("Resolution", value: loaded ? "\(Int(size.width)) × \(Int(size.height))" : "— × —")
            CropOriginalRow("Bitrate", value: loaded ? "\(bitrate.formatted(.number.precision(.fractionLength(2)).locale(CropFormatting.locale))) Mbps" : "—")
            CropOriginalRow(
                "Frame rate", value: loaded ? "\(frameRate.formatted(.number.precision(.fractionLength(0)).locale(CropFormatting.locale))) fps" : "—")
            CropOriginalRow("Duration", value: loaded ? "\(duration.formatted(.number.precision(.fractionLength(2)).locale(CropFormatting.locale))) s" : "—")
            CropOriginalRow("Size", value: loaded ? bytes.formatted(.byteCount(style: .file).locale(CropFormatting.locale)) : "—")
        }
    }
}

/// A row with a label on the left and a value on the right.
struct CropOriginalRow: View {
    let title: LocalizedStringKey
    let value: String
    init(_ title: LocalizedStringKey, value: String) {
        self.title = title
        self.value = value
    }
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// A section title and its controls.
struct CropInspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Choose a video export or a single-frame image export.
struct CropEncodingSection: View {
    @Bindable var history: EditHistory
    let originalBitrate: Double
    let sourceMbps: Double
    let loaded: Bool
    let busy: Bool
    let isHDR: Bool
    let hasTransparency: Bool
    
    var body: some View {
        CropInspectorSection("Encoding") {
            HStack {
                Text("Format")
                Spacer()
                CropFormatPicker(selection: $history.exportFormat, isHDR: isHDR)
                    .fixedSize()
            }
            if history.exportsFrame {
                ImageQualityControls(history: history, hasTransparency: hasTransparency)
            } else {
                HStack {
                    Text("Bitrate")
                    Spacer()
                    Text(loaded ? "\(history.bitrate.formatted(.number.precision(.fractionLength(2)).locale(CropFormatting.locale))) Mbps" : "—")
                        .monospacedDigit()
                    CropResetButton("Match Original Bitrate") { history.bitrate = originalBitrate }
                }
                Slider(
                    value: $history.bitrate, in: EncodingSettings.bitrateRange(for: sourceMbps), step: 0.5,
                    onEditingChanged: { if $0 { history.begin() } else { history.end() } }
                )
                .accessibilityLabel("Video bitrate in Mbps")
                .help("Higher bitrate preserves more detail and produces larger files.")
            }
        }
        .disabled(!loaded || busy)
    }
}

/// H.264 is disabled for HDR. PNG and JPEG export the current frame.
struct CropFormatPicker: NSViewRepresentable {
    @Binding var selection: ExportFormat
    let isHDR: Bool
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: ExportFormat.allCases.map(\.rawValue), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.selectFormat(_:)))
        control.controlSize = .small
        control.setAccessibilityLabel(String(localized: "Export format"))
        return control
    }
    
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.isEnabled = context.environment.isEnabled
        control.setEnabled(!isHDR, forSegment: 0)
        control.selectedSegment = ExportFormat.allCases.firstIndex(of: selection) ?? 1
        control.setToolTip(String(localized: "H.264 supports SDR video"), forSegment: 0)
        control.setToolTip(String(localized: "HEVC supports SDR and HDR video"), forSegment: 1)
        control.setToolTip(String(localized: "Export the current frame as PNG"), forSegment: 2)
        control.setToolTip(String(localized: "Export the current frame as JPEG"), forSegment: 3)
    }
    
    final class Coordinator: NSObject {
        var parent: CropFormatPicker
        
        init(_ parent: CropFormatPicker) { self.parent = parent }
        
        @objc func selectFormat(_ sender: NSSegmentedControl) {
            guard ExportFormat.allCases.indices.contains(sender.selectedSegment) else { return }
            let selected = ExportFormat.allCases[sender.selectedSegment]
            guard !parent.isHDR || selected != .h264 else { return }
            parent.selection = selected
        }
    }
}

/// Canvas background color.
struct CropCanvasSection: View {
    @Binding var color: Color
    
    var body: some View {
        CropInspectorSection("Canvas") {
            HStack {
                Text("Background")
                Spacer()
                ColorPicker("Background", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .help("Canvas background")
                CropResetButton("Reset Background") { color = Color(nsColor: CropAppearance.canvas) }
            }
        }
    }
}

/// A reset icon button.
struct CropResetButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    
    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    
    var body: some View {
        Button(action: action) { Label(title, systemImage: "arrow.counterclockwise") }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .help("Reset")
    }
}

/// The export button, progress bar, status message, Cancel button, and help button.
struct CropExportFooter: View {
    let state: CropExportState
    let canExport: Bool
    let loaded: Bool
    let outputWidth: Int
    let outputHeight: Int
    let encodingName: String
    let exportTitle: LocalizedStringKey
    let export: () -> Void
    let cancel: () -> Void
    @State private var showHelp = false
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Button(action: export) {
                    Text(exportTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(canExport ? Color.white : Color.secondary)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(canExport ? CropAppearance.exportAccent : Color(nsColor: .controlColor))
                .disabled(!canExport)
                .help("Export the crop (⇧⌘E)")
                .opacity(state.progress == nil ? 1 : 0)
                .allowsHitTesting(state.progress == nil)
                .accessibilityHidden(state.progress != nil)
                if let progress = state.progress {
                    /// Show progress and file size in the space occupied by the export button.
                    VStack(spacing: 3) {
                        HStack {
                            Text(state.indeterminate ? "Exporting…" : (progress >= 0.99 ? "Finalizing…" : "Exporting \(Int(progress * 100))%"))
                            Spacer(minLength: 4)
                            Text(state.bytes, format: .byteCount(style: .file).locale(CropFormatting.locale))
                        }
                        .font(.caption)
                        .monospacedDigit()
                        if state.indeterminate {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(CropAppearance.exportAccent)
                                .accessibilityLabel("Export progress")
                        } else {
                            ProgressView(value: min(max(progress, 0), 1), total: 1)
                                .progressViewStyle(.linear)
                                .tint(CropAppearance.exportAccent)
                                .accessibilityLabel("Export progress")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 34)
            HStack(spacing: 8) {
                if let message = state.message {
                    Text(message)
                        .lineLimit(1)
                } else if loaded {
                    Text("\(outputWidth) × \(outputHeight) px · \(encodingName)")
                        .lineLimit(1)
                } else {
                    Text("Ready")
                }
                Spacer(minLength: 0)
                if state.progress != nil {
                    Button("Cancel", action: cancel)
                        .help("Cancel export")
                }
                Button("Canvas Help", systemImage: "questionmark.circle") { showHelp.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Canvas shortcuts")
                    .popover(isPresented: $showHelp) {
                        Text(
                            """
                            Pan: hold H and drag, or use the middle or right mouse button.
                            Zoom: CMD-Scroll.
                            Fit: double-click.
                            Keep crop ratio: Shift-drag a corner.
                            """
                        )
                        .font(.callout)
                        .padding(16)
                    }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .controlSize(.small)
            .frame(height: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: 90)
    }
}

/// Glass styling for the welcome button, floating timeline, and crop fields.
extension View {
    /// Use a glass welcome button when macOS supports it.
    @ViewBuilder
    fileprivate func welcomeButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
    
    @ViewBuilder
    fileprivate func cropPanel() -> some View {
        if #available(macOS 26.0, *) {
            padding(12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: Undo and Numeric Fields

/// Video formats export the whole clip. Image formats export the selected frame.
enum ExportFormat: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"
    case png = "PNG"
    case jpeg = "JPEG"
    
    var id: String { rawValue }
    var isImage: Bool { self == .png || self == .jpeg }
}

/// The crop and encoding settings saved for each undo step.
struct CropEdit: Equatable {
    var crop = CropMargins()
    var encoding = EncodingSettings()
    var imageEncoding = ImageEncodingSettings()
    var exportsFrame = false
}

/// Stores crop and encoding changes so they can be undone.
@MainActor @Observable
final class EditHistory {
    
    private var currentCrop = CropMargins()
    /// Remember the crop center while width and height change, including one-pixel steps.
    private var resizeCenter: CGPoint?
    private var currentCodec = EncodingSettings.Codec.hevc
    private var currentBitrate = 2.5
    private var currentImageEncoding = ImageEncodingSettings()
    private var currentExportsFrame = false
    /// Videos use even dimensions. Images can be cropped one pixel at a time.
    var pixelStep = 2
    var value: CropEdit { CropEdit(crop: currentCrop, encoding: EncodingSettings(codec: currentCodec, megabitsPerSecond: currentBitrate), imageEncoding: currentImageEncoding, exportsFrame: currentExportsFrame) }
    var exportsFrame: Bool { currentExportsFrame }
    var exportFormat: ExportFormat {
        get {
            if exportsFrame { return imageEncoding.format == .png ? .png : .jpeg }
            return codec == .h264 ? .h264 : .hevc
        }
        set {
            var edit = value
            edit.exportsFrame = newValue.isImage
            switch newValue {
            case .h264: edit.encoding.codec = .h264
            case .hevc: edit.encoding.codec = .hevc
            case .png: edit.imageEncoding.format = .png
            case .jpeg: edit.imageEncoding.format = .jpeg
            }
            set(edit)
        }
    }
    var imageEncoding: ImageEncodingSettings {
        get { currentImageEncoding }
        set {
            var edit = value
            edit.imageEncoding = newValue
            set(edit)
        }
    }
    private var transaction: CropEdit?
    private(set) var revision = 0
    @ObservationIgnored let manager = UndoManager()
    
    init() {
        manager.groupsByEvent = false
    }
    
    var canUndo: Bool {
        _ = revision
        return manager.canUndo || (transaction != nil && transaction != value)
    }
    var canRedo: Bool {
        _ = revision
        return manager.canRedo
    }
    var crop: CropMargins {
        get { currentCrop }
        set {
            var edit = value
            edit.crop = newValue
            set(edit)
        }
    }
    var codec: EncodingSettings.Codec {
        get { currentCodec }
        set {
            var edit = value
            edit.encoding.codec = newValue
            set(edit)
        }
    }
    var bitrate: Double {
        get { currentBitrate }
        set {
            var edit = value
            edit.encoding.megabitsPerSecond = newValue
            set(edit)
        }
    }
    /// Resize around the same center until the crop is moved or its margins are edited.
    func resizeCrop(width: Int, height: Int, in size: CGSize) {
        let rectangle = crop.rectangle(in: size)
        let center = resizeCenter ?? CGPoint(x: rectangle.midX, y: rectangle.midY)
        var edit = value
        edit.crop = crop.resized(width: width, height: height, in: size, multiple: pixelStep, center: center)
        set(edit)
        resizeCenter = center
    }
    
    func reset(_ edit: CropEdit) {
        transaction = nil
        manager.removeAllActions()
        apply(edit)
        revision += 1
    }
    /// Treat a whole drag or field edit as one undo step.
    func begin() { if transaction == nil { transaction = value } }
    func end() {
        if let transaction, transaction != value { register(transaction) }
        transaction = nil
    }
    func set(_ edit: CropEdit) {
        guard edit != value else { return }
        if transaction == nil { register(value) }
        apply(edit)
    }
    /// Restore the crop and export settings for this undo step.
    private func apply(_ edit: CropEdit) {
        if currentCrop != edit.crop { resizeCenter = nil }
        currentCrop = edit.crop
        currentCodec = edit.encoding.codec
        currentBitrate = edit.encoding.megabitsPerSecond
        currentImageEncoding = edit.imageEncoding
        currentExportsFrame = edit.exportsFrame
    }
    private func register(_ previous: CropEdit) {
        let grouping = !manager.isUndoing && !manager.isRedoing
        if grouping { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { target in
            target.register(target.value)
            target.apply(previous)
            target.revision += 1
        }
        manager.setActionName(String(localized: "Crop and Encoding"))
        if grouping { manager.endUndoGrouping() }
        revision += 1
    }
    func undo() {
        end()
        if manager.canUndo { manager.undo() }
        revision += 1
    }
    func redo() {
        end()
        if manager.canRedo { manager.redo() }
        revision += 1
    }
    
}

/// Undo typing while a text field is being edited. Otherwise, undo crop or encoding changes.
@MainActor
enum CropUndoRouting {
    static func perform(_ history: EditHistory, redo: Bool) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
           redo ? editor.undoManager?.canRedo == true : editor.undoManager?.canUndo == true
        {
            NSApp.sendAction(NSSelectorFromString(redo ? "redo:" : "undo:"), to: nil, from: nil)
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
            if redo { history.redo() } else { history.undo() }
        }
    }
}

/// Undo and Redo in the Edit menu.
struct CropHistoryCommands: Commands {
    @FocusedValue(\.cropHistory) private var history
    @FocusedValue(\.cropWindowActions) private var actions
    
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if let history { CropUndoRouting.perform(history, redo: false) } }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(actions?.canEdit != true || (!(NSApp.keyWindow?.firstResponder is NSTextView) && history?.canUndo != true))
            Button("Redo") { if let history { CropUndoRouting.perform(history, redo: true) } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(actions?.canEdit != true || (!(NSApp.keyWindow?.firstResponder is NSTextView) && history?.canRedo != true))
        }
    }
}

/// Check crop dimensions and adjust them to valid even pixel counts.
enum CropDimensionValidation {
    static func resolve(_ text: String, current: Int, maximum: Int, multiple: Int = 2) -> (value: Int, rejected: Bool) {
        let maximum = max(multiple, maximum / multiple * multiple)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requested = Int(text) else {
            let overflowing = !text.isEmpty && text.allSatisfy(\.isNumber)
            return (overflowing ? maximum : current, true)
        }
        let bounded = min(maximum, max(multiple, requested))
        return (bounded / multiple * multiple, requested < multiple || requested > maximum)
    }
}

/// A width or height field. Apply the number on Return or when leaving the field.
struct CropDimensionField: NSViewRepresentable {
    @Binding var value: Int
    let maximum: Int
    let label: String
    let history: EditHistory
    var showsPlaceholder = false
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSView(context: Context) -> CropDimensionTextField {
        let field = CropDimensionTextField()
        field.delegate = context.coordinator
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.wantsLayer = true
        field.layer?.borderWidth = 1.5
        field.layer?.cornerRadius = 5
        field.layer?.borderColor = NSColor.clear.cgColor
        field.setAccessibilityLabel("Crop \(label.lowercased()) in pixels")
        field.toolTip = "Pixels"
        return field
    }
    
    func updateNSView(_ field: CropDimensionTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        field.placeholderString = "—"
        if field.currentEditor() == nil { field.stringValue = showsPlaceholder ? "" : String(value) }
    }
    
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        
        var parent: CropDimensionField
        
        init(_ parent: CropDimensionField) {
            self.parent = parent
        }
        
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.history.begin()
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView
            {
                editor.allowsUndo = true
            }
        }
        
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? CropDimensionTextField {
                commit(field)
                if let editor = field.window?.fieldEditor(false, for: field) as? NSTextView { editor.allowsUndo = true }
            }
            parent.history.end()
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? CropDimensionTextField else { return false }
            switch NSStringFromSelector(selector) {
            case "insertNewline:":
                commit(field)
                parent.history.end()
                parent.history.begin()
            case "moveUp:", "moveDown:", "moveUpAndModifySelection:", "moveDownAndModifySelection:":
                commit(field)
                let command = NSStringFromSelector(selector)
                let shifted = command.contains("AndModifySelection") || NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                let step = shifted ? 10 : parent.history.pixelStep
                let requested = parent.value + (command.hasPrefix("moveUp") ? step : -step)
                apply(String(requested), to: field)
            default: return false
            }
            textView.string = String(parent.value)
            textView.selectAll(nil)
            return true
        }
        
        private func commit(_ field: CropDimensionTextField) { apply(field.stringValue, to: field) }
        
        private func apply(_ text: String, to field: CropDimensionTextField) {
            let result = CropDimensionValidation.resolve(text, current: parent.value, maximum: parent.maximum, multiple: parent.history.pixelStep)
            parent.value = result.value
            field.stringValue = String(parent.value)
            if let editor = field.currentEditor() { editor.string = field.stringValue }
            if result.rejected { field.flashValidation() }
        }
        
    }
}

/// Flash the field red when the entered size is invalid.
final class CropDimensionTextField: SelectingNumberField {
    
    func flashValidation() {
        let flash = CABasicAnimation(keyPath: "borderColor")
        flash.fromValue = NSColor.systemRed.cgColor
        flash.toValue = NSColor.clear.cgColor
        flash.duration = 0.7
        layer?.add(flash, forKey: "validation")
    }
    
}

/// A crop margin field with Up and Down arrow support.
struct CropNumberField: NSViewRepresentable {
    @Binding var value: Int
    let label: String
    let history: EditHistory
    var showsPlaceholder = false
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSView(context: Context) -> SelectingNumberField {
        let field = SelectingNumberField()
        field.delegate = context.coordinator
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.setAccessibilityLabel("\(label) crop margin in pixels")
        field.toolTip = "Pixels"
        return field
    }
    
    func updateNSView(_ field: SelectingNumberField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        field.placeholderString = "—"
        if field.currentEditor() == nil { field.stringValue = showsPlaceholder ? "" : String(value) }
    }
    
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        
        var parent: CropNumberField
        
        init(_ parent: CropNumberField) {
            self.parent = parent
        }
        
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.history.begin()
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView
            {
                editor.allowsUndo = true
            }
        }
        
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField, let number = Int(field.stringValue) {
                parent.value = number
            }
        }
        
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                if let number = Int(field.stringValue) { parent.value = number }
                field.stringValue = String(parent.value)
                if let editor = field.window?.fieldEditor(false, for: field) as? NSTextView { editor.allowsUndo = true }
            }
            parent.history.end()
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command = NSStringFromSelector(selector)
            guard ["moveUp:", "moveDown:", "moveUpAndModifySelection:", "moveDownAndModifySelection:"].contains(command) else { return false }
            /// Recognize Shift-Up and Shift-Down as ten-pixel adjustments.
            let shifted = command.contains("AndModifySelection") || NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            let step = shifted ? 10 : parent.history.pixelStep
            parent.value += command.hasPrefix("moveUp") ? step : -step
            control.stringValue = String(parent.value)
            textView.string = control.stringValue
            textView.selectAll(nil)
            return true
        }
        
    }
}

class SelectingNumberField: NSTextField {
    
    private var selectOnFirstClick = false
    
    /// AppKit may focus the field before passing it the click that started editing.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        selectOnFirstClick = accepted && NSApp.currentEvent?.type == .leftMouseDown
        return accepted
    }
    
    /// The first click selects the number. Later clicks place the caret for editing.
    override func mouseDown(with event: NSEvent) {
        if isEnabled && isEditable && (selectOnFirstClick || currentEditor() == nil) {
            selectText(nil)
            selectOnFirstClick = false
        } else {
            super.mouseDown(with: event)
        }
    }
    
}

// MARK: Crop Geometry

/// How many pixels to remove from each side of the video.
struct CropMargins: Equatable {
    enum Edge: CaseIterable { case left, top, right, bottom }
    var left = 0
    var top = 0
    var right = 0
    var bottom = 0
    
    subscript(edge: Edge) -> Int {
        get {
            switch edge {
            case .left: left
            case .top: top
            case .right: right
            case .bottom: bottom
            }
        }
        set {
            switch edge {
            case .left: left = newValue
            case .top: top = newValue
            case .right: right = newValue
            case .bottom: bottom = newValue
            }
        }
    }
    
    /// Start with the full image. Video dimensions must be multiples of two.
    static func fullImage(_ size: CGSize, multiple: Int = 2) -> CropMargins {
        CropMargins(right: Int(size.width) % multiple, bottom: Int(size.height) % multiple)
    }
    
    func rectangle(in size: CGSize) -> CGRect {
        CGRect(x: left, y: top, width: max(0, Int(size.width) - left - right), height: max(0, Int(size.height) - top - bottom))
    }
    
    /// Keep the crop inside the image and use the pixel step required by its format.
    mutating func set(_ edge: Edge, to requested: Int, in size: CGSize, multiple: Int = 2) {
        let horizontal = edge == .left || edge == .right
        let opposite: Edge =
        switch edge {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
        let extent = Int(horizontal ? size.width : size.height)
        let maximum = max(0, extent - self[opposite] - multiple)
        var margin = min(maximum, max(0, requested))
        if (extent - self[opposite] - margin) % multiple != 0 {
            margin = margin < maximum ? margin + 1 : max(0, margin - 1)
        }
        self[edge] = margin
    }
    
    /// Resize around the crop center and keep the crop inside the image or video.
    func resized(width: Int, height: Int, in size: CGSize, multiple: Int = 2, center: CGPoint? = nil) -> CropMargins {
        let maximumWidth = max(multiple, Int(size.width) / multiple * multiple)
        let maximumHeight = max(multiple, Int(size.height) / multiple * multiple)
        let retainedWidth = min(maximumWidth, max(multiple, width / multiple * multiple))
        let retainedHeight = min(maximumHeight, max(multiple, height / multiple * multiple))
        let current = rectangle(in: size)
        let center = center ?? CGPoint(x: current.midX, y: current.midY)
        let left = min(max(0, Int((center.x - Double(retainedWidth) / 2).rounded())), max(0, Int(size.width) - retainedWidth))
        let top = min(max(0, Int((center.y - Double(retainedHeight) / 2).rounded())), max(0, Int(size.height) - retainedHeight))
        return CropMargins(
            left: left, top: top, right: max(0, Int(size.width) - left - retainedWidth),
            bottom: max(0, Int(size.height) - top - retainedHeight))
    }
    
    /// Keep the starting crop ratio while dragging a corner. The opposite corner stays in place.
    func resizedKeepingRatio(horizontal: CGFloat, vertical: CGFloat, edges: [Edge], in size: CGSize, multiple: Int) -> CropMargins {
        let rectangle = rectangle(in: size)
        guard rectangle.width > 0, rectangle.height > 0 else { return self }
        let movesLeft = edges.contains(.left)
        let movesTop = edges.contains(.top)
        let anchorX = movesLeft ? rectangle.maxX : rectangle.minX
        let anchorY = movesTop ? rectangle.maxY : rectangle.minY
        let availableWidth = movesLeft ? anchorX : size.width - anchorX
        let availableHeight = movesTop ? anchorY : size.height - anchorY
        let requestedWidth = rectangle.width + (movesLeft ? -horizontal : horizontal)
        let requestedHeight = rectangle.height + (movesTop ? -vertical : vertical)
        let requestedScale = (requestedWidth * rectangle.width + requestedHeight * rectangle.height)
        / (rectangle.width * rectangle.width + rectangle.height * rectangle.height)
        let pixelStep = CGFloat(multiple)
        let minimumScale = max(pixelStep / rectangle.width, pixelStep / rectangle.height)
        let maximumScale = min(availableWidth / rectangle.width, availableHeight / rectangle.height)
        guard maximumScale >= minimumScale else { return self }
        let scale = min(maximumScale, max(minimumScale, requestedScale))
        
        /// Round to whole pixels for images and even pixels for videos.
        let width = min(Int(availableWidth) / multiple * multiple, max(multiple, Int((rectangle.width * scale / pixelStep).rounded()) * multiple))
        let height = min(Int(availableHeight) / multiple * multiple, max(multiple, Int((rectangle.height * scale / pixelStep).rounded()) * multiple))
        let left = Int(anchorX) - (movesLeft ? width : 0)
        let top = Int(anchorY) - (movesTop ? height : 0)
        return CropMargins(left: left, top: top, right: Int(size.width) - left - width, bottom: Int(size.height) - top - height)
    }
    
    /// Move the crop rectangle without changing its size or letting it leave the video.
    func translated(horizontal: Int, vertical: Int) -> CropMargins {
        let horizontal = min(right, max(-left, horizontal))
        let vertical = min(bottom, max(-top, vertical))
        return CropMargins(left: left + horizontal, top: top + vertical, right: right - horizontal, bottom: bottom - vertical)
    }
}

// MARK: Playback

/// The presentation time of every video frame, including variable-frame-rate recordings.
struct VideoFrameIndex: Sendable {
    let times: [CMTime]
    
    /// Read frame positions without decoding the video pixels.
    static func load(asset: AVAsset, track: AVAssetTrack, duration: Double) throws -> VideoFrameIndex {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImageError.unreadableFrame }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ImageError.unreadableFrame }
        defer { reader.cancelReading() }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            for sampleIndex in 0..<CMSampleBufferGetNumSamples(sample) {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sample, at: sampleIndex, timingInfoOut: &timing) == noErr else {
                    throw ImageError.unreadableFrame
                }
                let time = timing.presentationTimeStamp
                if time.isNumeric, time.seconds >= 0, time.seconds < duration { times.append(time) }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? ImageError.unreadableFrame }
        times.sort { CMTimeCompare($0, $1) < 0 }
        var uniqueTimes: [CMTime] = []
        for time in times where uniqueTimes.last.map({ CMTimeCompare($0, time) != 0 }) ?? true {
            uniqueTimes.append(time)
        }
        guard !uniqueTimes.isEmpty else { throw ImageError.unreadableFrame }
        return VideoFrameIndex(times: uniqueTimes)
    }
    
    /// Find the frame visible at this playback time.
    func frame(at time: CMTime) -> Int {
        var lowerBound = 0
        var upperBound = times.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if CMTimeCompare(times[middle], time) <= 0 {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return max(0, lowerBound - 1)
    }
}

/// Read the selected frame at full resolution with its original colors and HDR.
enum VideoFrameExporter {
    static func image(from url: URL, at time: CMTime) async throws -> ImageSource {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        /// Keep the displayed proportions, including videos with non-square pixels.
        generator.apertureMode = .cleanAperture
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.dynamicRangePolicy = .matchSource
        let result = try await withTaskCancellationHandler {
            try await generator.image(at: time)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        try Task.checkCancellation()
        let image = result.image
        let profile = image.colorSpace.flatMap { NSColorSpace(cgColorSpace: $0)?.localizedName }
        return ImageSource(image: image, type: .png, bytes: 0, colorProfileName: profile)
    }
}

/// Track playback position and whether the video is playing.
/// Remove playback observers when the video is closed or replaced.
@MainActor @Observable
final class PlaybackState {
    private(set) var position = 0.0
    private(set) var selectedFrame = 0
    private(set) var isPlaying = false
    private(set) var isMuted = false
    private(set) var duration = 0.0
    private(set) var frames = VideoFrameIndex(times: [])
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    @ObservationIgnored private var muteObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var seekTarget: Int?
    @ObservationIgnored private var seekInProgress = false
    @ObservationIgnored private var playbackRateAfterSeek: Float = 0
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var reverseTimer: Timer?
    @ObservationIgnored private var heldDirection: Int?
    private var scrubbing = false
    private var resumeAfterScrubbing = false
    private var reachedEnd = false
    private var operation = UUID()
    
    var frameCount: Int { frames.times.count }
    var framePosition: Double {
        get { Double(selectedFrame) }
        set {
            let requested = min(max(0, Int(newValue.rounded())), max(0, frameCount - 1))
            if requested != selectedFrame { seek(to: requested) }
        }
    }
    
    func connect(to player: AVPlayer, frames: VideoFrameIndex, duration: Double) {
        disconnect()
        self.player = player
        self.frames = frames
        self.duration = duration
        updatePosition(player.currentTime())
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing, self.reverseTimer == nil, self.seekTarget == nil else { return }
                self.updatePosition(time)
            }
        }
        rateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                self.isPlaying = observed.rate != 0 || self.playbackRateAfterSeek != 0 || self.reverseTimer != nil
            }
        }
        statusObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.performPendingSeek() }
        }
        isMuted = player.isMuted
        muteObserver = player.observe(\.isMuted, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                self.isMuted = observed.isMuted
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let endedBackward = self.heldDirection == -1
                self.pause()
                self.reachedEnd = !endedBackward
                self.position = endedBackward ? 0 : self.duration
                self.selectedFrame = endedBackward ? 0 : max(0, self.frameCount - 1)
            }
        }
    }
    
    /// Silence the canvas video while checking the crop.
    func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
        isMuted = player.isMuted
    }
    
    func pause() {
        clearFrameHold()
        playbackRateAfterSeek = 0
        player?.pause()
        isPlaying = false
        resumeAfterScrubbing = false
    }
    
    /// Freeze the selected frame when Export is clicked.
    func pauseForExport() -> CMTime? {
        let wasSeeking = seekTarget != nil
        pause()
        if !wasSeeking, let player { updatePosition(player.currentTime()) }
        guard frames.times.indices.contains(selectedFrame) else { return nil }
        return frames.times[selectedFrame]
    }
    
    func togglePlayback() {
        guard player != nil else { return }
        if isPlaying {
            pause()
        } else {
            seek(to: reachedEnd ? 0 : selectedFrame, rate: 1)
        }
    }
    
    /// Step one frame and leave playback paused.
    func step(by amount: Int) {
        if seekTarget == nil, let player { updatePosition(player.currentTime()) }
        pause()
        seek(to: selectedFrame + amount)
    }
    
    /// A tap steps once. Holding the key starts normal-speed playback.
    func beginFrameHold(direction: Int) {
        guard player != nil, frameCount > 0 else { return }
        step(by: direction)
        heldDirection = direction
        holdTask = Task { @MainActor [weak self] in
            /// Distinguish a quick frame tap from a held key.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.startHeldPlayback()
        }
    }
    
    /// Stop on an exact frame when the key is released or the window loses focus.
    func endFrameHold() {
        guard heldDirection != nil else { return }
        pause()
        if seekTarget == nil, let player { updatePosition(player.currentTime()) }
        seek(to: selectedFrame)
    }
    
    private func clearFrameHold() {
        holdTask?.cancel()
        holdTask = nil
        reverseTimer?.invalidate()
        reverseTimer = nil
        heldDirection = nil
    }
    
    private func startHeldPlayback() {
        guard player != nil, let heldDirection else { return }
        if heldDirection > 0 {
            seek(to: selectedFrame, rate: 1)
        } else {
            /// Scrub backward at normal speed using the same seeks as the timeline.
            let startTime = position
            let startUptime = ProcessInfo.processInfo.systemUptime
            let interval = min(1.0 / 60, duration / Double(frameCount))
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let seconds = max(0, startTime - (ProcessInfo.processInfo.systemUptime - startUptime))
                    let frame = self.frames.frame(at: CMTime(seconds: seconds, preferredTimescale: 60000))
                    if frame != self.selectedFrame { self.seek(to: frame) }
                    if seconds == 0 { self.endFrameHold() }
                }
            }
            reverseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            isPlaying = true
        }
    }
    
    /// Pause while dragging the timeline. Resume afterward if the video was playing.
    func setScrubbing(_ editing: Bool) {
        scrubbing = editing
        if editing {
            let wasPlaying = isPlaying
            pause()
            resumeAfterScrubbing = wasPlaying
        } else {
            let resume = resumeAfterScrubbing
            resumeAfterScrubbing = false
            seek(to: selectedFrame, rate: resume ? 1 : 0)
        }
    }
    
    /// Keep the latest requested frame while the player finishes its current seek.
    private func seek(to requested: Int, rate: Float = 0) {
        guard player != nil, frameCount > 0 else { return }
        selectedFrame = min(max(0, requested), frameCount - 1)
        position = frames.times[selectedFrame].seconds
        reachedEnd = false
        playbackRateAfterSeek = rate
        isPlaying = rate != 0 || reverseTimer != nil
        seekTarget = selectedFrame
        performPendingSeek()
    }
    
    /// Finish one seek before starting the next, as recommended in Apple's QA1820.
    private func performPendingSeek() {
        guard !seekInProgress, let target = seekTarget, let player,
              player.currentItem?.status == .readyToPlay else { return }
        seekInProgress = true
        let connection = operation
        player.seek(to: frames.times[target], toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, self.operation == connection, self.player === player else { return }
                self.seekInProgress = false
                if self.seekTarget != target {
                    self.performPendingSeek()
                } else {
                    self.seekTarget = nil
                    let rate = self.playbackRateAfterSeek
                    self.playbackRateAfterSeek = 0
                    if finished { player?.rate = rate }
                    self.isPlaying = finished && (rate != 0 || self.reverseTimer != nil)
                }
            }
        }
    }
    
    private func updatePosition(_ time: CMTime) {
        guard time.isNumeric else { return }
        position = min(max(0, time.seconds), duration)
        selectedFrame = frames.frame(at: time)
    }
    
    func disconnect() {
        operation = UUID()
        clearFrameHold()
        seekTarget = nil
        seekInProgress = false
        playbackRateAfterSeek = 0
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        muteObserver?.invalidate()
        muteObserver = nil
        isMuted = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        frames = VideoFrameIndex(times: [])
        selectedFrame = 0
        position = 0
        duration = 0
        scrubbing = false
        resumeAfterScrubbing = false
        reachedEnd = false
        isPlaying = false
    }
    
    deinit {
        holdTask?.cancel()
        reverseTimer?.invalidate()
        statusObserver?.invalidate()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        rateObserver?.invalidate()
        muteObserver?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

/// Reserve room for the full frame count.
struct PlaybackReadout: View {
    let text: String
    let reservation: String
    
    var body: some View {
        Text(verbatim: reservation)
            .hidden()
            .overlay(alignment: .trailing) {
                Text(verbatim: text)
            }
            .font(.caption)
            .monospacedDigit()
            .fixedSize()
    }
}

/// Playback, frame scrubbing, frame stepping, time, and mute.
struct PlaybackControls: View {
    @Bindable var playback: PlaybackState
    
    var body: some View {
        let totalFrames = String(playback.frameCount)
        let totalSeconds = playback.duration.formatted(CropFormatting.seconds)
        let currentSeconds = playback.position.formatted(CropFormatting.seconds)
        
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                FramePlaybackButton(playback: playback, direction: -1)
                    .disabled(playback.selectedFrame == 0)
                    .help("Previous frame ([)")
                Button(action: playback.togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                }
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                .help(playback.isPlaying ? "Pause (⌘↩)" : "Play (⌘↩)")
                FramePlaybackButton(playback: playback, direction: 1)
                    .disabled(playback.selectedFrame >= playback.frameCount - 1)
                    .help("Next frame (])")
            }
            PlaybackTimeline(playback: playback)
                .disabled(playback.frameCount < 2)
            PlaybackReadout(text: "\(playback.selectedFrame + 1)/\(totalFrames)", reservation: "\(totalFrames)/\(totalFrames)")
                .accessibilityLabel("Frame \(playback.selectedFrame + 1) of \(playback.frameCount)")
                .help("\(currentSeconds) / \(totalSeconds) s")
            /// Both speaker icons use the same space so muting cannot resize the timeline.
            Button(action: playback.toggleMute) {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18, height: 18)
            }
            .accessibilityLabel(playback.isMuted ? "Unmute" : "Mute")
            .help(playback.isMuted ? "Unmute" : "Mute")
        }
        .disabled(playback.frameCount == 0)
    }
}

/// Jump to clicked frames and show time above the thumb while hovering or scrubbing.
struct PlaybackTimeline: NSViewRepresentable {
    let playback: PlaybackState
    @Environment(\.isEnabled) private var isEnabled
    
    func makeNSView(context: Context) -> FrameTimelineSlider {
        let slider = FrameTimelineSlider()
        slider.setAccessibilityLabel("Video frame")
        return slider
    }
    
    func updateNSView(_ slider: FrameTimelineSlider, context: Context) {
        slider.playback = playback
        let maximum = Double(max(1, playback.frameCount - 1))
        if slider.maxValue != maximum { slider.maxValue = maximum }
        slider.updatePosition()
        if slider.isEnabled != isEnabled {
            slider.isEnabled = isEnabled
            if !isEnabled { slider.cancelInteraction() }
        }
        slider.updateTimeBubble()
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FrameTimelineSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: nsView.intrinsicContentSize.height)
    }
    
    static func dismantleNSView(_ slider: FrameTimelineSlider, coordinator: ()) {
        slider.cancelInteraction()
    }
}

/// Keep the native slider's appearance and keyboard controls, with instant mouse seeking.
final class FrameTimelineSlider: NSSlider {
    weak var playback: PlaybackState?
    private var scrubbing = false
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private var resignObserver: NSObjectProtocol?
    private let timeBubble = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let timeLabel = NSTextField(labelWithString: "")
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(changeFrame(_:))
        isContinuous = true
        minValue = 0
        numberOfTickMarks = 0
        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        timeLabel.alignment = .center
        /// The time bubble never takes focus from the slider or playback controls.
        timeBubble.isReleasedWhenClosed = false
        timeBubble.isOpaque = false
        timeBubble.backgroundColor = .clear
        timeBubble.hasShadow = true
        timeBubble.animationBehavior = .none
        timeBubble.ignoresMouseEvents = true
        timeBubble.hidesOnDeactivate = true
        timeBubble.isExcludedFromWindowsMenu = true
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        background.addSubview(timeLabel)
        timeBubble.contentView = background
    }
    
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelInteraction()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelInteraction() }
        }
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        hoverArea = area
        addTrackingArea(area)
    }
    
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateTimeBubble()
    }
    
    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateTimeBubble()
    }
    
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let sliderCell = cell as? NSSliderCell else { return }
        scrubbing = true
        playback?.setScrubbing(true)
        
        /// Jump to a clicked frame before AppKit starts dragging the thumb.
        let point = convert(event.locationInWindow, from: nil)
        if !sliderCell.knobRect(flipped: isFlipped).contains(point) {
            let travel = bounds.insetBy(dx: sliderCell.knobThickness / 2, dy: 0)
            let fraction = min(1, max(0, (point.x - travel.minX) / max(1, travel.width)))
            doubleValue = (minValue + Double(fraction) * (maxValue - minValue)).rounded()
            changeFrame(self)
            displayIfNeeded()
        }
        
        /// AppKit tracks the thumb until the mouse button is released.
        super.mouseDown(with: event)
        guard scrubbing else { return }
        scrubbing = false
        playback?.setScrubbing(false)
        updatePosition()
        updateTimeBubble()
    }
    
    /// Let AppKit move the thumb during a drag. Playback uses whole frames.
    func updatePosition() {
        guard !scrubbing, let playback else { return }
        if doubleValue != playback.framePosition { doubleValue = playback.framePosition }
    }
    
    @objc private func changeFrame(_ sender: Any?) {
        if !scrubbing { playback?.pause() }
        playback?.framePosition = doubleValue
        updatePosition()
        updateTimeBubble()
    }
    
    /// Position the time bubble at the selected frame before the slider redraws.
    private var thumbRect: NSRect {
        guard let sliderCell = cell as? NSSliderCell else { return .zero }
        var knob = sliderCell.knobRect(flipped: isFlipped)
        let fraction = min(1, max(0, (doubleValue - minValue) / max(1, maxValue - minValue)))
        let travel = bounds.insetBy(dx: sliderCell.knobThickness / 2, dy: 0)
        knob.origin.x = travel.minX + CGFloat(fraction) * max(0, travel.width) - knob.width / 2
        return knob
    }
    
    func updateTimeBubble() {
        guard isEnabled, hovering || scrubbing, let window,
              let playback else {
            hideTimeBubble()
            return
        }
        timeLabel.stringValue = "\(playback.position.formatted(CropFormatting.seconds)) s"
        let size = timeLabel.fittingSize
        timeLabel.frame = NSRect(x: 8, y: 6, width: size.width, height: size.height)
        let knob = window.convertToScreen(convert(thumbRect, to: nil))
        let frame = NSRect(x: knob.midX - (size.width + 16) / 2, y: knob.maxY + 6, width: size.width + 16, height: size.height + 12)
        if timeBubble.appearance !== window.effectiveAppearance {
            timeBubble.appearance = window.effectiveAppearance
        }
        timeBubble.setFrame(frame, display: true)
        if timeBubble.parent !== window {
            timeBubble.parent?.removeChildWindow(timeBubble)
            window.addChildWindow(timeBubble, ordered: .above)
        }
        if !timeBubble.isVisible { timeBubble.orderFront(nil) }
    }
    
    private func hideTimeBubble() {
        timeBubble.orderOut(nil)
        timeBubble.parent?.removeChildWindow(timeBubble)
    }
    
    /// Stop scrubbing and hide the time when leaving the window or closing the video.
    func cancelInteraction() {
        hovering = false
        if scrubbing {
            scrubbing = false
            playback?.pause()
            playback?.setScrubbing(false)
        }
        hideTimeBubble()
    }
    
    deinit {
        timeBubble.close()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

/// Native frame buttons share the keyboard's tap and hold behavior.
struct FramePlaybackButton: NSViewRepresentable {
    let playback: PlaybackState
    let direction: Int
    @Environment(\.isEnabled) private var isEnabled
    
    func makeNSView(context: Context) -> FrameHoldButton {
        let button = FrameHoldButton()
        button.bezelStyle = .push
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: direction < 0 ? "backward.frame.fill" : "forward.frame.fill", accessibilityDescription: nil)
        button.image?.size = NSSize(width: 18, height: 18)
        button.setAccessibilityLabel(direction < 0 ? "Previous Frame" : "Next Frame")
        return button
    }
    
    func updateNSView(_ button: FrameHoldButton, context: Context) {
        button.playback = playback
        button.direction = direction
        if button.isEnabled != isEnabled {
            button.isEnabled = isEnabled
            if !isEnabled { button.endMouseHold() }
        }
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FrameHoldButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    
    static func dismantleNSView(_ button: FrameHoldButton, coordinator: ()) {
        button.endMouseHold()
    }
}

/// Release stops playback. Keyboard and accessibility clicks still step one frame.
final class FrameHoldButton: NSButton {
    weak var playback: PlaybackState?
    var direction = 1
    private var trackingMouse = false
    private var pointerInside = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(stepOnce(_:))
    }
    
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    
    @objc private func stepOnce(_ sender: Any?) {
        playback?.step(by: direction)
    }
    
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        trackingMouse = true
        pointerInside = true
        highlight(true)
        playback?.beginFrameHold(direction: direction)
    }
    
    /// Leaving the button stops the hold. Dragging back onto it starts it again.
    override func mouseDragged(with event: NSEvent) {
        guard trackingMouse else { return }
        let inside = isEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != pointerInside else { return }
        pointerInside = inside
        highlight(inside)
        if inside { playback?.beginFrameHold(direction: direction) } else { playback?.endFrameHold() }
    }
    
    override func mouseUp(with event: NSEvent) {
        endMouseHold()
    }
    
    func endMouseHold() {
        guard trackingMouse else { return }
        trackingMouse = false
        pointerInside = false
        highlight(false)
        playback?.endFrameHold()
    }
}

// MARK: Canvas Navigation

/// Connect the SwiftUI window to the AppKit video canvas.
struct CropCanvas: NSViewRepresentable {
    let player: AVPlayer?
    let image: CGImage?
    let sourceSize: CGSize
    @Binding var crop: CropMargins
    @Binding var zoom: Double
    @Binding var fit: Bool
    let previewOnly: Bool
    let cameraRequest: Int
    let centerCameraOnRequest: Bool
    let framingInsets: NSEdgeInsets
    let history: EditHistory
    let playback: PlaybackState?
    let windowIdentity: UUID
    let canvasColor: NSColor
    let onFit: () -> Void
    let onExitPreview: () -> Void
    
    func makeNSView(context: Context) -> CanvasScrollView {
        let view = CanvasScrollView()
        view.windowIdentity = windowIdentity
        return view
    }
    
    func updateNSView(_ view: CanvasScrollView, context: Context) {
        view.backgroundColor = canvasColor
        view.onZoom = { value, fitted in
            zoom = value
            fit = fitted
        }
        view.onFit = onFit
        view.onExitPreview = onExitPreview
        view.history = history
        view.playback = playback
        view.update(
            player: player, image: image, size: sourceSize, crop: crop, zoom: zoom, fit: fit,
            previewOnly: previewOnly, request: cameraRequest, insets: framingInsets, centerCameraOnRequest: centerCameraOnRequest
        ) { crop = $0 }
    }
}

final class CanvasScrollView: NSScrollView {
    
    var windowIdentity: UUID?
    private let canvas = VideoCanvasView()
    private var sourceSize = CGSize.zero
    private var zoom = 1.0
    private var fit = true
    private var previewOnly = false
    private var layingOut = false
    private var eventMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var heldFrameKey: UInt16?
    weak var playback: PlaybackState? {
        didSet {
            if oldValue !== playback {
                oldValue?.endFrameHold()
                heldFrameKey = nil
            }
        }
    }
    private var animationTimer: Timer?
    private var scrollCursorReset: DispatchWorkItem?
    private var trackpadPanning = false
    var showingPanCursor: Bool { isPanning || trackpadPanning }
    private var animatedScale: CGFloat?
    private var request = 0
    private var insets = NSEdgeInsets()
    private var publishedZoom = -1.0
    private var lastViewportSize = CGSize.zero
    private var heldHandKey: UInt16?
    var handToolHeld: Bool { heldHandKey != nil }
    private(set) var isPanning = false
    private var panOrigin = CGPoint.zero
    private var panScrollOrigin = CGPoint.zero
    var history: EditHistory?
    var onZoom: ((Double, Bool) -> Void)?
    var onFit: (() -> Void)?
    var onExitPreview: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        backgroundColor = CropAppearance.canvas
        canvas.overlay.wantsLayer = true
        documentView = canvas
    }
    
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    
    func update(
        player: AVPlayer?, image: CGImage?, size: CGSize, crop: CropMargins, zoom: Double, fit: Bool, previewOnly: Bool, request: Int, insets: NSEdgeInsets,
        centerCameraOnRequest: Bool = true, onChange: @escaping (CropMargins) -> Void
    ) {
        let newSource = canvas.videoLayer.player !== player || canvas.image !== image
        let changedPreview = self.previewOnly != previewOnly
        let changedScale = self.zoom != zoom || self.fit != fit || sourceSize != size
        let changedCrop = canvas.overlay.crop != crop
        let animate = self.request != request && !newSource
        self.request = request
        self.insets = insets
        sourceSize = size
        self.zoom = zoom
        self.fit = fit
        if !fit || newSource { publishedZoom = -1 }
        self.previewOnly = previewOnly
        canvas.videoLayer.player = player
        canvas.image = image
        canvas.overlay.history = history
        canvas.overlay.sourceSize = size
        canvas.overlay.crop = crop
        canvas.overlay.onChange = onChange
        canvas.overlay.onEditBegan = { [weak self] in self?.history?.begin() }
        canvas.overlay.onEditEnded = { [weak self] in self?.history?.end() }
        canvas.overlay.onFit = onFit
        canvas.onFit = onFit
        canvas.previewOnly = previewOnly
        canvas.overlay.editingEnabled = !previewOnly
        canvas.overlay.setAccessibilityHidden(previewOnly)
        if newSource || (changedScale && !animate) { stopAnimation() }
        if animate {
            animateCamera(centerSource: centerCameraOnRequest)
        } else if changedScale || newSource || changedPreview || (previewOnly && changedCrop) {
            layoutCanvas(centerSource: newSource)
        }
        if changedCrop || newSource || changedScale || changedPreview {
            canvas.overlay.updateFields()
            canvas.overlay.needsDisplay = true
            window?.invalidateCursorRects(for: canvas.overlay)
        }
    }
    
    /// Handle mouse-wheel zoom, trackpad zoom, and canvas keyboard shortcuts.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        stopCanvasKeys()
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        guard let window else {
            stopAnimation()
            return
        }
        
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopCanvasKeys() }
        }
        if let windowIdentity { CropWindowRegistry.shared.attach(window, identity: windowIdentity) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
            guard let self, event.window === self.window || self.window?.isKeyWindow == true else { return event }
            /// Key-up ends the hold even if focus or modifier keys changed meanwhile.
            if event.type == .keyUp, self.heldFrameKey == event.keyCode {
                self.stopFrameKey()
                return nil
            }
            if event.type == .keyDown, self.window?.isKeyWindow == true,
               !(self.window?.firstResponder is NSTextView),
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               let playback = self.playback, playback.frameCount > 0,
               let character = event.charactersIgnoringModifiers, character == "[" || character == "]" {
                if !event.isARepeat {
                    self.stopFrameKey()
                    self.heldFrameKey = event.keyCode
                    playback.beginFrameHold(direction: character == "[" ? -1 : 1)
                }
                return nil
            }
            let command = event.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.command)
            if event.type == .scrollWheel && command {
                self.commandScroll(event)
                return nil
            }
            if event.type == .smartMagnify {
                self.onFit?()
                return nil
            }
            if event.type == .magnify {
                self.zoomAroundPointer(event, factor: max(0.1, 1 + event.magnification))
                return nil
            }
            /// Hold H to pan the canvas.
            if event.type == .keyUp, self.heldHandKey == event.keyCode {
                self.setHandToolKey(nil)
                return nil
            }
            if event.type == .keyDown, self.window?.isKeyWindow == true,
               !(self.window?.firstResponder is NSTextView),
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               event.charactersIgnoringModifiers?.lowercased() == "h" {
                self.setHandToolKey(event.keyCode)
                return nil
            }
            if event.type == .keyDown {
                if self.previewOnly && event.keyCode == 53 {
                    self.onExitPreview?()
                    return nil
                }
            }
            return event
        }
    }
    
    private func setHandToolKey(_ keyCode: UInt16?) {
        guard heldHandKey != keyCode else { return }
        heldHandKey = keyCode
        window?.invalidateCursorRects(for: self)
        window?.invalidateCursorRects(for: canvas.overlay)
    }
    
    /// Release held controls when leaving the canvas window.
    private func stopCanvasKeys() {
        stopFrameKey()
        setHandToolKey(nil)
        endPan()
    }
    
    private func stopFrameKey() {
        heldFrameKey = nil
        playback?.endFrameHold()
    }
    
    deinit {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        animationTimer?.invalidate()
        scrollCursorReset?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
    
    override func resetCursorRects() {
        super.resetCursorRects()
        if showingPanCursor || handToolHeld { addCursorRect(bounds, cursor: showingPanCursor ? .closedHand : .openHand) }
    }
    
    override func layout() {
        super.layout()
        /// Center a fitted image or video when opening the inspector changes the canvas size.
        let resized = lastViewportSize != contentView.bounds.size
        lastViewportSize = contentView.bounds.size
        layoutCanvas(centerSource: fit && resized && animationTimer == nil)
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutCanvas(centerSource: false)
    }
    
    private var framing: CGRect {
        CGRect(origin: .zero, size: sourceSize)
    }
    
    private var anchor: CGPoint {
        let size = contentView.bounds.size
        return CGPoint(
            x: insets.left + max(1, size.width - insets.left - insets.right) / 2, y: insets.top + max(1, size.height - insets.top - insets.bottom) / 2)
    }
    
    private var fittedScale: CGFloat {
        min(
            max(1, contentView.bounds.width - insets.left - insets.right - 240) / max(1, framing.width),
            max(1, contentView.bounds.height - insets.top - insets.bottom - 192) / max(1, framing.height))
    }
    
    /// Size and position the video on the canvas.
    private func layoutCanvas(centerSource: Bool, centerOverride: CGPoint? = nil) {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let oldImage = canvas.overlay.imageFrame
        let visibleAnchor = CGPoint(x: contentView.bounds.minX + anchor.x, y: contentView.bounds.minY + anchor.y)
        let relative =
        centerOverride
        ?? CGPoint(
            x: centerSource || oldImage.width == 0 ? framing.midX / max(1, sourceSize.width) : (visibleAnchor.x - oldImage.minX) / oldImage.width,
            y: centerSource || oldImage.height == 0 ? framing.midY / max(1, sourceSize.height) : (visibleAnchor.y - oldImage.minY) / oldImage.height)
        let scale = animatedScale ?? (fit ? fittedScale : zoom / (window?.backingScaleFactor ?? 1))
        let framedSize = CGSize(width: framing.width * scale, height: framing.height * scale)
        let documentSize = CGSize(
            width: max(viewport.width, framedSize.width + viewport.width),
            height: max(viewport.height, framedSize.height + viewport.height))
        let origin = CGPoint(
            x: insets.left + (documentSize.width - insets.left - insets.right - framedSize.width) / 2,
            y: insets.top + (documentSize.height - insets.top - insets.bottom - framedSize.height) / 2)
        let imageFrame = CGRect(
            x: origin.x - framing.minX * scale, y: origin.y - framing.minY * scale,
            width: sourceSize.width * scale, height: sourceSize.height * scale)
        canvas.frame = CGRect(origin: .zero, size: documentSize)
        canvas.positionVideo(in: imageFrame, retained: canvas.overlay.crop.rectangle(in: sourceSize), scale: scale)
        scrollDocument(
            to: CGPoint(
                x: imageFrame.minX + relative.x * imageFrame.width - anchor.x,
                y: imageFrame.minY + relative.y * imageFrame.height - anchor.y))
        /// Update the zoom slider and percentage after fitting the video.
        if fit && animationTimer == nil && sourceSize.width > 0 {
            let actualZoom = scale * (window?.backingScaleFactor ?? 1)
            if abs(actualZoom - publishedZoom) > 0.0001 {
                publishedZoom = actualZoom
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.fit, self.animationTimer == nil else { return }
                    self.onZoom?(actualZoom, true)
                }
            }
        }
    }
    
    private func scrollDocument(to point: CGPoint) {
        contentView.scroll(
            to: CGPoint(
                x: min(max(0, point.x), max(0, canvas.bounds.width - contentView.bounds.width)),
                y: min(max(0, point.y), max(0, canvas.bounds.height - contentView.bounds.height))))
        reflectScrolledClipView(contentView)
    }
    
    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animatedScale = nil
    }
    
    /// Animate zooming and fitting the video.
    private func animateCamera(centerSource: Bool) {
        let oldImage = canvas.overlay.imageFrame
        guard oldImage.width > 0, sourceSize.width > 0 else {
            layoutCanvas(centerSource: true)
            return
        }
        let startScale = oldImage.width / sourceSize.width
        let startCenter = CGPoint(
            x: (contentView.bounds.minX + anchor.x - oldImage.minX) / oldImage.width,
            y: (contentView.bounds.minY + anchor.y - oldImage.minY) / oldImage.height)
        let targetCenter = centerSource ? CGPoint(x: framing.midX / sourceSize.width, y: framing.midY / sourceSize.height) : startCenter
        let targetScale = fit ? fittedScale : zoom / (window?.backingScaleFactor ?? 1)
        stopAnimation()
        let began = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let fraction = min(1, (Date.timeIntervalSinceReferenceDate - began) / 0.25)
            let eased = fraction * fraction * (3 - 2 * fraction)
            self.animatedScale = startScale + (targetScale - startScale) * eased
            let center = CGPoint(
                x: startCenter.x + (targetCenter.x - startCenter.x) * eased,
                y: startCenter.y + (targetCenter.y - startCenter.y) * eased)
            self.layoutCanvas(centerSource: false, centerOverride: center)
            if fraction >= 1 {
                self.stopAnimation()
                self.layoutCanvas(centerSource: false, centerOverride: targetCenter)
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    private func commandScroll(_ event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        let amount = delta == 0 ? event.scrollingDeltaY : delta
        zoomAroundPointer(event, factor: exp(amount * (event.hasPreciseScrollingDeltas ? 0.008 : 0.12)))
    }
    
    /// Zoom toward the mouse pointer.
    private func zoomAroundPointer(_ event: NSEvent, factor: Double) {
        let oldImage = canvas.overlay.imageFrame
        guard oldImage.width > 0, sourceSize.width > 0 else { return }
        stopAnimation()
        let pointer = canvas.convert(event.locationInWindow, from: nil)
        let relative = CGPoint(x: (pointer.x - oldImage.minX) / oldImage.width, y: (pointer.y - oldImage.minY) / oldImage.height)
        let viewportPoint = CGPoint(x: pointer.x - contentView.bounds.minX, y: pointer.y - contentView.bounds.minY)
        zoom = min(CropZoomStops.maximum, max(CropZoomStops.minimum, oldImage.width / sourceSize.width * (window?.backingScaleFactor ?? 1) * factor))
        fit = false
        layoutCanvas(centerSource: false)
        let image = canvas.overlay.imageFrame
        scrollDocument(
            to: CGPoint(
                x: image.minX + relative.x * image.width - viewportPoint.x,
                y: image.minY + relative.y * image.height - viewportPoint.y))
        onZoom?(zoom, false)
    }
    
    /// Start panning the canvas.
    func beginPan(with event: NSEvent) {
        guard event.buttonNumber == 2 || event.buttonNumber == 1 || handToolHeld else { return }
        stopAnimation()
        isPanning = true
        panOrigin = event.locationInWindow
        panScrollOrigin = contentView.bounds.origin
        window?.makeFirstResponder(self)
        NSCursor.closedHand.set()
    }
    
    func dragPan(with event: NSEvent) {
        guard isPanning else { return }
        scrollDocument(
            to: CGPoint(
                x: panScrollOrigin.x - event.locationInWindow.x + panOrigin.x,
                y: panScrollOrigin.y + event.locationInWindow.y - panOrigin.y))
    }
    
    func endPan() {
        isPanning = false
        window?.invalidateCursorRects(for: self)
        window?.invalidateCursorRects(for: canvas.overlay)
    }
    
    /// Pan with the right mouse button.
    override func rightMouseDown(with event: NSEvent) { beginPan(with: event) }
    override func rightMouseDragged(with event: NSEvent) { dragPan(with: event) }
    override func rightMouseUp(with event: NSEvent) { endPan() }
    override func otherMouseDown(with event: NSEvent) { beginPan(with: event) }
    override func otherMouseDragged(with event: NSEvent) { dragPan(with: event) }
    override func otherMouseUp(with event: NSEvent) { endPan() }
    
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.command) {
            commandScroll(event)
        } else {
            super.scrollWheel(with: event)
            guard event.hasPreciseScrollingDeltas else { return }
            trackpadPanning = true
            NSCursor.closedHand.set()
            scrollCursorReset?.cancel()
            let reset = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.trackpadPanning = false
                self.window?.invalidateCursorRects(for: self)
                self.window?.invalidateCursorRects(for: self.canvas.overlay)
                NSCursor.arrow.set()
                self.window?.resetCursorRects()
            }
            scrollCursorReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: reset)
        }
    }
    
    override func magnify(with event: NSEvent) { zoomAroundPointer(event, factor: max(0.1, 1 + event.magnification)) }
    
    override func smartMagnify(with event: NSEvent) { onFit?() }
    
}

// MARK: Video and Crop Overlay

/// Display the video with the crop rectangle and its controls.
final class VideoCanvasView: NSView {
    
    let videoLayer = AVPlayerLayer()
    private let mediaLayer = CALayer()
    private let imageLayer = CALayer()
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = image
            imageLayer.isHidden = image == nil
            videoLayer.isHidden = image != nil
            CATransaction.commit()
        }
    }
    let overlay = CropOverlayView()
    private let videoSurface = NSView()
    private let cropMask = CALayer()
    private let retainedMask = CALayer()
    private var displayedPreview = false
    var previewOnly = false
    var onFit: (() -> Void)?
    override var isFlipped: Bool { true }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        videoSurface.wantsLayer = true
        videoLayer.videoGravity = .resize
        videoSurface.layer?.addSublayer(mediaLayer)
        mediaLayer.addSublayer(videoLayer)
        mediaLayer.addSublayer(imageLayer)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.isHidden = true
        cropMask.backgroundColor = NSColor.white.cgColor
        cropMask.masksToBounds = true
        retainedMask.backgroundColor = NSColor.white.cgColor
        cropMask.addSublayer(retainedMask)
        mediaLayer.mask = cropMask
        addSubview(videoSurface)
        addSubview(overlay)
    }
    
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    
    func positionVideo(in imageFrame: CGRect, retained: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoSurface.frame = imageFrame
        mediaLayer.frame = videoSurface.bounds
        videoLayer.frame = mediaLayer.bounds
        imageLayer.frame = mediaLayer.bounds
        /// The media layers measure from the bottom. Crop fields measure from the top.
        let retainedFrame = CGRect(
            x: retained.minX * scale, y: imageFrame.height - retained.maxY * scale,
            width: retained.width * scale, height: retained.height * scale)
        cropMask.frame = mediaLayer.bounds
        retainedMask.frame = retainedFrame
        CATransaction.commit()
        if displayedPreview != previewOnly {
            /// Fade the crop controls and outside video together. Allow reversing the fade mid-animation.
            let startTime = CACurrentMediaTime()
            let targetOpacity: Float = previewOnly ? 0 : 1
            let currentOpacity = overlay.layer?.presentation()?.opacity ?? overlay.layer?.opacity ?? 1
            let currentColor = cropMask.presentation()?.backgroundColor ?? cropMask.backgroundColor
            let targetColor = NSColor.white.withAlphaComponent(CGFloat(targetOpacity)).cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.layer?.opacity = targetOpacity
            cropMask.backgroundColor = targetColor
            CATransaction.commit()
            let controlsFade = CABasicAnimation(keyPath: "opacity")
            controlsFade.fromValue = currentOpacity
            controlsFade.toValue = targetOpacity
            let maskFade = CABasicAnimation(keyPath: "backgroundColor")
            maskFade.fromValue = currentColor
            maskFade.toValue = targetColor
            for (targetLayer, fade) in [(overlay.layer, controlsFade), (Optional(cropMask), maskFade)] {
                guard let targetLayer else { continue }
                fade.beginTime = targetLayer.convertTime(startTime, from: nil)
                fade.duration = 0.22
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                targetLayer.add(fade, forKey: "previewFade")
            }
            displayedPreview = previewOnly
        }
        overlay.frame = bounds
        overlay.imageFrame = imageFrame
        overlay.updateFields()
        overlay.needsDisplay = true
        window?.invalidateCursorRects(for: overlay)
    }
    
    override func mouseDown(with event: NSEvent) {
        if let scroll = enclosingScrollView as? CanvasScrollView, scroll.handToolHeld {
            scroll.beginPan(with: event)
            return
        }
        if event.clickCount == 2 {
            onFit?()
            return
        }
        if previewOnly { window?.makeFirstResponder(enclosingScrollView) } else { super.mouseDown(with: event) }
    }
    
    override func mouseDragged(with event: NSEvent) { (enclosingScrollView as? CanvasScrollView)?.dragPan(with: event) }
    
    override func mouseUp(with event: NSEvent) { (enclosingScrollView as? CanvasScrollView)?.endPan() }
    
}

/// A floating crop margin field beside the crop rectangle.
struct CropCanvasField: View {
    let title: String
    @Binding var value: Int
    let history: EditHistory
    
    init(title: String, value: Binding<Int>, history: EditHistory) {
        self.title = title
        _value = value
        self.history = history
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            CropNumberField(value: $value, label: title, history: history)
                .frame(width: 62, height: 22)
        }
        .cropPanel()
    }
}

/// Remember the crop field positions so they only update when needed.
private struct CropFieldState: Equatable {
    let crop: CropMargins
    let size: CGSize
    let imageFrame: CGRect
}

/// Draw the crop rectangle, resize handles, and darkened area outside the crop.
final class CropOverlayView: NSView {
    
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        
        var cursor: NSCursor {
            let position: NSCursor.FrameResizePosition =
            switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return .frameResize(position: position, directions: .all)
        }
        
        var edges: [CropMargins.Edge] {
            switch self {
            case .topLeft: [.top, .left]
            case .top: [.top]
            case .topRight: [.top, .right]
            case .right: [.right]
            case .bottomRight: [.bottom, .right]
            case .bottom: [.bottom]
            case .bottomLeft: [.bottom, .left]
            case .left: [.left]
            }
        }
    }
    var sourceSize = CGSize.zero
    var imageFrame = CGRect.zero
    var crop = CropMargins()
    var onChange: ((CropMargins) -> Void)?
    var onEditBegan: (() -> Void)?
    var onEditEnded: (() -> Void)?
    var onFit: (() -> Void)?
    private var dragOrigin = CGPoint.zero
    private var dragCrop = CropMargins()
    private var activeHandle: Handle?
    private var moving = false
    var editingEnabled = true
    var history: EditHistory?
    private var fields: [CropMargins.Edge: NSHostingView<CropCanvasField>] = [:]
    private var displayedFieldState: CropFieldState?
    
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var scale: CGFloat { imageFrame.width / max(1, sourceSize.width) }
    private var selection: CGRect {
        let rectangle = crop.rectangle(in: sourceSize)
        return CGRect(
            x: imageFrame.minX + rectangle.minX * scale, y: imageFrame.minY + rectangle.minY * scale,
            width: rectangle.width * scale, height: rectangle.height * scale)
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? { editingEnabled ? super.hitTest(point) : nil }
    
    /// Position the four margin fields around the crop rectangle.
    func updateFields() {
        guard let history else { return }
        let state = CropFieldState(crop: crop, size: sourceSize, imageFrame: imageFrame)
        guard displayedFieldState != state else { return }
        displayedFieldState = state
        for edge in CropMargins.Edge.allCases {
            let title = String(describing: edge).capitalized
            let value = Binding<Int>(
                get: { [weak self] in self?.crop[edge] ?? 0 },
                set: { [weak self] value in
                    guard let self else { return }
                    var updated = self.crop
                    updated.set(edge, to: value, in: self.sourceSize, multiple: history.pixelStep)
                    self.crop = updated
                    self.onChange?(updated)
                    self.updateFields()
                    self.needsDisplay = true
                })
            let content = CropCanvasField(title: title, value: value, history: history)
            let field: NSHostingView<CropCanvasField>
            if let existing = fields[edge] {
                field = existing
                field.rootView = content
            } else {
                field = NSHostingView(rootView: content)
                fields[edge] = field
                addSubview(field)
            }
            let rectangle = selection
            let origin: CGPoint =
            switch edge {
            case .left: CGPoint(x: rectangle.minX - 108, y: rectangle.midY - 31)
            case .right: CGPoint(x: rectangle.maxX + 22, y: rectangle.midY - 31)
            case .top: CGPoint(x: rectangle.midX - 43, y: rectangle.minY - 80)
            case .bottom: CGPoint(x: rectangle.midX - 43, y: rectangle.maxY + 18)
            }
            field.frame = CGRect(origin: origin, size: CGSize(width: 86, height: 62))
            field.isHidden = sourceSize.width == 0
        }
    }
    
    /// Place resize handles outside the crop rectangle.
    private func handleRect(_ handle: Handle) -> CGRect {
        let rectangle = selection
        switch handle {
        case .topLeft: return CGRect(x: rectangle.minX - 12, y: rectangle.minY - 12, width: 12, height: 12)
        case .top: return CGRect(x: rectangle.midX - 12, y: rectangle.minY - 8, width: 24, height: 8)
        case .topRight: return CGRect(x: rectangle.maxX, y: rectangle.minY - 12, width: 12, height: 12)
        case .right: return CGRect(x: rectangle.maxX, y: rectangle.midY - 12, width: 8, height: 24)
        case .bottomRight: return CGRect(x: rectangle.maxX, y: rectangle.maxY, width: 12, height: 12)
        case .bottom: return CGRect(x: rectangle.midX - 12, y: rectangle.maxY, width: 24, height: 8)
        case .bottomLeft: return CGRect(x: rectangle.minX - 12, y: rectangle.maxY, width: 12, height: 12)
        case .left: return CGRect(x: rectangle.minX - 8, y: rectangle.midY - 12, width: 8, height: 24)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        /// Clear the previous drawing so old crop outlines do not remain on screen.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let rectangle = selection
        /// Protect the inside of the crop from the border, handles, and dark overlay.
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds)
        outside.appendRect(rectangle)
        outside.windingRule = .evenOdd
        outside.addClip()
        CropAppearance.excludedArea.setFill()
        imageFrame.fill()
        CropAppearance.cropBorder.setFill()
        rectangle.insetBy(dx: -2, dy: -2).fill()
        CropAppearance.cropHandles.setFill()
        for handle in Handle.allCases { handleRect(handle).fill() }
        NSGraphicsContext.restoreGraphicsState()
    }
    
    override func resetCursorRects() {
        guard editingEnabled, sourceSize.width > 0 else { return }
        if let scroll = enclosingScrollView as? CanvasScrollView, scroll.handToolHeld || scroll.showingPanCursor {
            addCursorRect(bounds, cursor: scroll.showingPanCursor ? .closedHand : .openHand)
            return
        }
        addCursorRect(selection, cursor: CropCursors.moveCrop)
        let rectangle = selection
        addCursorRect(CGRect(x: rectangle.minX, y: rectangle.minY - 6, width: rectangle.width, height: 9), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: rectangle.minX, y: rectangle.maxY - 3, width: rectangle.width, height: 9), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: rectangle.minX - 6, y: rectangle.minY, width: 9, height: rectangle.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: rectangle.maxX - 3, y: rectangle.minY, width: 9, height: rectangle.height), cursor: .resizeLeftRight)
        for handle in Handle.allCases {
            addCursorRect(handleRect(handle).insetBy(dx: -3, dy: -3), cursor: handle.cursor)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        guard sourceSize.width > 0 else { return }
        if let scroll = enclosingScrollView as? CanvasScrollView, scroll.handToolHeld {
            scroll.beginPan(with: event)
            return
        }
        if event.clickCount == 2 {
            onFit?()
            return
        }
        window?.makeFirstResponder(self)
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragCrop = crop
        activeHandle = Handle.allCases.first { handleRect($0).insetBy(dx: -4, dy: -4).contains(dragOrigin) }
        if activeHandle == nil {
            let rectangle = selection
            if CGRect(x: rectangle.minX, y: rectangle.minY - 6, width: rectangle.width, height: 9).contains(dragOrigin) {
                activeHandle = .top
            } else if CGRect(x: rectangle.minX, y: rectangle.maxY - 3, width: rectangle.width, height: 9).contains(dragOrigin) {
                activeHandle = .bottom
            } else if CGRect(x: rectangle.minX - 6, y: rectangle.minY, width: 9, height: rectangle.height).contains(dragOrigin) {
                activeHandle = .left
            } else if CGRect(x: rectangle.maxX - 3, y: rectangle.minY, width: 9, height: rectangle.height).contains(dragOrigin) {
                activeHandle = .right
            }
        }
        moving = activeHandle == nil && selection.contains(dragOrigin)
        if activeHandle != nil || moving { onEditBegan?() }
        if moving { CropCursors.moveCrop.set() }
    }
    
    /// Convert a drag distance into video pixels to move or resize the crop.
    override func mouseDragged(with event: NSEvent) {
        if let scroll = enclosingScrollView as? CanvasScrollView, scroll.isPanning {
            scroll.dragPan(with: event)
            return
        }
        guard scale > 0, activeHandle != nil || moving else { return }
        let point = convert(event.locationInWindow, from: nil)
        let horizontal = Int(((point.x - dragOrigin.x) / scale).rounded())
        let vertical = Int(((point.y - dragOrigin.y) / scale).rounded())
        var updated = dragCrop
        if let activeHandle, activeHandle.edges.count == 2, event.modifierFlags.contains(.shift) {
            updated = dragCrop.resizedKeepingRatio(
                horizontal: (point.x - dragOrigin.x) / scale, vertical: (point.y - dragOrigin.y) / scale,
                edges: activeHandle.edges, in: sourceSize, multiple: history?.pixelStep ?? 2)
        } else if let activeHandle {
            for edge in activeHandle.edges {
                let delta =
                switch edge {
                case .left: horizontal
                case .right: -horizontal
                case .top: vertical
                case .bottom: -vertical
                }
                updated.set(edge, to: dragCrop[edge] + delta, in: sourceSize, multiple: history?.pixelStep ?? 2)
            }
        } else {
            updated = dragCrop.translated(horizontal: horizontal, vertical: vertical)
        }
        crop = updated
        updateFields()
        needsDisplay = true
        onChange?(updated)
    }
    
    override func mouseUp(with event: NSEvent) {
        if let scroll = enclosingScrollView as? CanvasScrollView, scroll.isPanning {
            scroll.endPan()
            return
        }
        onEditEnded?()
        activeHandle = nil
        moving = false
        window?.invalidateCursorRects(for: self)
    }
    
    /// Move the crop with arrow keys. Hold Shift to move ten pixels at a time.
    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        let updated: CropMargins
        switch event.keyCode {
        case 123: updated = crop.translated(horizontal: -step, vertical: 0)
        case 124: updated = crop.translated(horizontal: step, vertical: 0)
        case 125: updated = crop.translated(horizontal: 0, vertical: step)
        case 126: updated = crop.translated(horizontal: 0, vertical: -step)
        default:
            super.keyDown(with: event)
            return
        }
        crop = updated
        updateFields()
        needsDisplay = true
        onChange?(updated)
    }
    
}

// MARK: Images

/// PNG keeps transparency. JPEG uses a background color and a quality setting.
struct ImageEncodingSettings: Equatable, Sendable {
    enum Format: String, CaseIterable, Sendable {
        case png = "PNG"
        case jpeg = "JPEG"
        var contentType: UTType { self == .png ? .png : .jpeg }
        var fileExtension: String { self == .png ? "png" : "jpg" }
    }
    
    var format: Format = .png
    var quality = 0.9
    var background = ImageBackground()
}

/// Fill transparent areas with this color when exporting JPEG.
struct ImageBackground: Equatable, Sendable {
    var red = 1.0
    var green = 1.0
    var blue = 1.0
    
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    
    init() {}
    
    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .white
        red = converted.redComponent
        green = converted.greenComponent
        blue = converted.blueComponent
    }
}

/// The full-resolution image used by the crop canvas and export.
struct ImageSource: @unchecked Sendable {
    static let supportedTypes: [UTType] = [.png, .jpeg, .heic, .heif, .tiff]
    let image: CGImage
    let type: UTType
    let bytes: Int64
    let colorProfileName: String?
    
    var isHDR: Bool {
        image.contentHeadroom > 1 || image.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } == true
    }
    
    var hasTransparency: Bool {
        [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
    }
    
    var formatName: String {
        if type == .jpeg { return "JPEG" }
        if type == .png { return "PNG" }
        if type == .tiff { return "TIFF" }
        return type.preferredFilenameExtension?.uppercased() ?? "Image"
    }
    
    /// Apply the file's orientation so the crop fields match the upright image.
    static func load(_ url: URL) throws -> ImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              supportedTypes.contains(where: { type.conforms(to: $0) }) else {
            throw ImageError.unsupported
        }
        guard CGImageSourceGetCount(source) == 1 else { throw ImageError.multipleImages }
        guard let original = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary) else {
            throw ImageError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage
        if orientation == 1 {
            image = original
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(original.width, original.height),
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ImageError.unreadable
            }
            image = upright
        }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let embeddedProfile = properties?[kCGImagePropertyProfileName] as? String
        let colorProfile = embeddedProfile ?? original.colorSpace.flatMap { NSColorSpace(cgColorSpace: $0)?.localizedName }
        return ImageSource(image: image, type: type, bytes: Int64(bytes), colorProfileName: colorProfile)
    }
}

/// Errors shown when an image or video frame cannot be read or exported.
enum ImageError: LocalizedError {
    case unsupported, multipleImages, unreadable, invalidCrop, encodingFailed, unreadableFrame
    
    var errorDescription: String? {
        switch self {
        case .unsupported: "Open a PNG, JPEG, HEIC, or TIFF image."
        case .multipleImages: "Animated images and images with multiple pages are not supported."
        case .unreadable: "This image could not be read."
        case .invalidCrop: "The crop must stay inside the image and contain at least one pixel."
        case .encodingFailed: "The cropped image could not be exported."
        case .unreadableFrame: "This video frame could not be read."
        }
    }
}

/// Crop at the original pixel size and save only the image and its color profile.
enum ImageExporter {
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    
    static func export(source: ImageSource, destination: URL, crop: CGRect, settings: ImageEncodingSettings) throws {
        try Task.checkCancellation()
        let bounds = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        guard crop.width >= 1, crop.height >= 1, crop == crop.integral, bounds.contains(crop),
              let cropped = source.image.cropping(to: crop) else { throw ImageError.invalidCrop }
        guard let destination = CGImageDestinationCreateWithURL(destination as CFURL, settings.format.contentType.identifier as CFString, 1, nil) else {
            throw ImageError.encodingFailed
        }
        var properties: [CFString: Any] = [kCGImageDestinationOptimizeColorForSharing: false]
        if source.isHDR {
            /// PNG stores the HDR pixels. JPEG includes an HDR gain map and an SDR image.
            properties[kCGImageDestinationEncodeRequest] = settings.format == .png
            ? kCGImageDestinationEncodeToISOHDR : kCGImageDestinationEncodeToISOGainmap
        }
        if settings.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, settings.quality))
            if source.hasTransparency {
                /// JPEG fills transparent pixels with the selected color.
                let background = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [settings.background.red, settings.background.green, settings.background.blue, 1])!
                properties[kCGImageDestinationBackgroundColor] = background
            }
        }
        let output: CGImage
        if source.isHDR && settings.format == .png && cropped.colorSpace.map({ CGColorSpaceUsesITUR_2100TF($0) }) != true {
            /// PNG needs a nonlinear HDR profile to store floating-point HDR pixels.
            let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
            guard let rendered = imageContext.createCGImage(
                CIImage(cgImage: cropped), from: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height),
                format: .RGBA16, colorSpace: colorSpace) else { throw ImageError.encodingFailed }
            output = rendered
        } else {
            output = cropped
        }
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encodingFailed }
        try Task.checkCancellation()
    }
}

/// Choose PNG or JPEG, with JPEG quality and a background for transparent images.
struct ImageEncodingSection: View {
    @Bindable var history: EditHistory
    let hasTransparency: Bool
    
    var body: some View {
        CropInspectorSection("Encoding") {
            HStack {
                Text("Format")
                Spacer()
                Picker("Format", selection: $history.imageEncoding.format) {
                    Text("PNG")
                        .tag(ImageEncodingSettings.Format.png)
                    Text("JPEG")
                        .tag(ImageEncodingSettings.Format.jpeg)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ImageQualityControls(history: history, hasTransparency: hasTransparency)
        }
    }
}

/// JPEG quality and the fill color for transparent pixels.
struct ImageQualityControls: View {
    @Bindable var history: EditHistory
    let hasTransparency: Bool
    
    var body: some View {
        if history.imageEncoding.format == .jpeg {
            HStack {
                Text("Quality")
                Spacer()
                Text("\(Int((history.imageEncoding.quality * 100).rounded()))%")
                    .monospacedDigit()
                CropResetButton("Reset Quality") { history.imageEncoding.quality = ImageEncodingSettings().quality }
            }
            Slider(value: $history.imageEncoding.quality, in: 0...1, step: 0.01) { editing in
                if editing { history.begin() } else { history.end() }
            }
            .accessibilityLabel("JPEG quality")
            .help("Higher quality produces larger files")
            if hasTransparency {
                HStack(alignment: .center) {
                    Text("Fill Color")
                    Spacer()
                    ColorPicker("Fill Color", selection: Binding(
                        get: { history.imageEncoding.background.color },
                        set: { history.imageEncoding.background = ImageBackground($0) }), supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
                    .help("Fill transparent areas")
                    CropResetButton("Reset JPEG Background") { history.imageEncoding.background = ImageBackground() }
                }
            }
        }
    }
}

/// Show the exported image and its file information before saving.
struct ExportImageView: View {
    let image: NSImage
    let summary: ExportSummary
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            Image(nsImage: image)
                .allowedDynamicRange(.high)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ExportInformation(summary: summary)
                .padding(12)
        }
        .frame(minWidth: 300, minHeight: 200)
    }
}

// MARK: Video Encoding

/// The codec and bitrate used for export.
struct EncodingSettings: Sendable, Equatable {
    enum Codec: String, CaseIterable, Identifiable, Sendable {
        case h264 = "H.264"
        case hevc = "HEVC"
        
        var id: String { rawValue }
        var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
    }
    
    var codec: Codec = .hevc
    var megabitsPerSecond = 2.5
    
    /// The menu and slider use the same bitrate limits for the opened video.
    static func bitrateRange(for sourceMbps: Double) -> ClosedRange<Double> {
        min(0.5, max(0.01, sourceMbps))...max(40, ceil(sourceMbps))
    }
    
    var isValid: Bool { megabitsPerSecond.isFinite && (0.01...10000).contains(megabitsPerSecond) }
}

/// The video’s color information, including whether it uses HDR.
struct CropVideoColor: Sendable {
    let primaries: String?
    let transferFunction: String?
    let matrix: String?
    var isHDR: Bool {
        transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        || transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    }
}

/// Crop and encode the video, then copy its original audio into the MOV file.
enum VideoExporter {
    /// Read the video’s size and rotation so the crop matches what you see.
    static func geometry(for asset: AVAsset) async throws -> (track: AVAssetTrack, bounds: CGRect, transform: CGAffineTransform) {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw failure("This file has no readable video track.")
        }
        let size = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(preferredTransform).standardized
        let normalizedTransform = preferredTransform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        return (track, CGRect(origin: .zero, size: bounds.size), normalizedTransform)
    }
    
    /// Read the video’s color information and check for HDR.
    static func colorInfo(for track: AVAssetTrack) async throws -> CropVideoColor {
        let formats = try await track.load(.formatDescriptions)
        let colors = formats.map { format in
            CropVideoColor(
                primaries: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
                transferFunction: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
                matrix: CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String)
        }
        return colors.first(where: \.isHDR) ?? colors.first ?? CropVideoColor(primaries: nil, transferFunction: nil, matrix: nil)
    }
    
    /// Export the selected crop with the chosen codec and bitrate.
    static func export(
        source: URL, destination: URL, crop: CGRect, settings: EncodingSettings, fileSize: @escaping @Sendable (Int64) -> Void = { _ in },
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: source)
        let geometry = try await geometry(for: asset)
        guard geometry.bounds.contains(crop), crop.width >= 2, crop.height >= 2,
              Int(crop.width).isMultiple(of: 2), Int(crop.height).isMultiple(of: 2)
                else {
            throw failure("The crop must fit inside the video and have even dimensions of at least two pixels.")
        }
        let color = try await colorInfo(for: geometry.track)
        guard !color.isHDR || settings.codec == .hevc else {
            throw failure("HDR video requires HEVC. Select HEVC to preserve the video's dynamic range.")
        }
        let duration = try await asset.load(.duration)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: geometry.track)
        let cropTransform = geometry.transform.concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        layer.setTransform(cropTransform, at: .zero)
        instruction.layerInstructions = [layer]
        
        /// Use the original frame rate and colors when rendering the crop.
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.instructions = [instruction]
        composition.renderSize = crop.size
        if color.isHDR {
            /// Keep the video in HDR.
            composition.colorPrimaries = color.primaries ?? AVVideoColorPrimaries_ITU_R_2020
            composition.colorTransferFunction = color.transferFunction
            composition.colorYCbCrMatrix = color.matrix ?? AVVideoYCbCrMatrix_ITU_R_2020
        }
        guard settings.isValid else { throw failure("Choose a positive supported video bitrate.") }
        
        /// Store files created during this export in a temporary folder.
        let stagingDirectory = destination.deletingLastPathComponent().appendingPathComponent("GoodFrame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let temporaryURL = stagingDirectory.appendingPathComponent("Export.mov")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
        /// Measure the file size while exporting.
        let sizeMonitor = Task {
            while !Task.isCancelled {
                /// The encoder may write to another file in this folder before finishing.
                let files = (try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                let bytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.max() ?? 0
                fileSize(Int64(bytes))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { sizeMonitor.cancel() }
        writer.shouldOptimizeForNetworkUse = true
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [geometry.track],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: color.isHDR
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(settings.megabitsPerSecond * 1_000_000),
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if color.isHDR {
            /// Use 10-bit HEVC for HDR and regenerate Dolby Vision metadata for the edited video.
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto
            compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = false
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: Int(crop.width),
            AVVideoHeightKey: Int(crop.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: composition.colorPrimaries ?? AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: composition.colorTransferFunction ?? AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: composition.colorYCbCrMatrix ?? AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw failure("This codec or encoding configuration is unavailable on this Mac.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.metadata = try await displayDensity(from: geometry.track, croppedSize: crop.size)
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw failure("Cannot configure the video pipeline.")
        }
        reader.add(videoOutput)
        writer.add(videoInput)
        
        /// Copy each original audio track without decoding or recompressing it.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioTransfers: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for track in audioTracks {
            guard let format = try await track.load(.formatDescriptions).first else {
                throw failure("Cannot read the original audio format.")
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.languageCode = try await track.load(.languageCode)
            input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
            input.metadata = try await track.load(.metadata)
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw failure("The original audio cannot be copied into a MOV file.")
            }
            reader.add(output)
            writer.add(input)
            audioTransfers.append((output: output, input: input))
        }
        guard writer.startWriting() else { throw writer.error ?? failure("Cannot start encoding.") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? failure("Cannot start decoding.")
        }
        do {
            try Task.checkCancellation()
            /// Process audio and video concurrently.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await transfer(videoOutput, to: videoInput, reader: reader, writer: writer, duration: duration.seconds, progress: progress)
                }
                for audio in audioTransfers {
                    group.addTask { try await transfer(audio.output, to: audio.input, reader: reader, writer: writer) }
                }
                try await group.waitForAll()
            }
            try Task.checkCancellation()
            guard reader.status == .completed else {
                throw reader.error ?? failure("Decoding did not complete.")
            }
            progress(0.99)
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? failure("Encoding did not complete.")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        try Task.checkCancellation()
        /// Make the exported file visible in Finder.
        var visibility = URLResourceValues()
        visibility.isHidden = false
        var visibleTemporaryURL = temporaryURL
        try visibleTemporaryURL.setResourceValues(visibility)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        }
        let completedAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        fileSize((completedAttributes[.size] as? NSNumber)?.int64Value ?? 0)
        progress(1)
    }
    
    /// Keep Retina display sizing when the exported video is opened.
    private static func displayDensity(from track: AVAssetTrack, croppedSize: CGSize) async throws -> [AVMetadataItem] {
        for item in try await track.load(.metadata) where item.identifier?.rawValue == "mdta/com.apple.quicktime.pixeldensity" {
            guard let density = try await item.load(.value) as? [String: NSNumber],
                  let widthPixels = density["widthPixels"]?.doubleValue,
                  let heightPixels = density["heightPixels"]?.doubleValue,
                  let widthPoints = density["widthPoints"]?.doubleValue,
                  let heightPoints = density["heightPoints"]?.doubleValue,
                  widthPixels > 0, heightPixels > 0, widthPoints > 0, heightPoints > 0
                    else { continue }
            let updated = AVMutableMetadataItem()
            updated.identifier = item.identifier
            updated.dataType = item.dataType
            updated.value =
            [
                "widthPixels": NSNumber(value: Int(croppedSize.width)),
                "heightPixels": NSNumber(value: Int(croppedSize.height)),
                "widthPoints": NSNumber(value: max(1, Int((croppedSize.width * widthPoints / widthPixels).rounded()))),
                "heightPoints": NSNumber(value: max(1, Int((croppedSize.height * heightPoints / heightPixels).rounded()))),
            ] as NSDictionary
            return [updated]
        }
        return []
    }
    
    /// Write video frames or original audio samples to the file. Allow cancellation while waiting.
    private static func transfer(
        _ output: AVAssetReaderOutput, to input: AVAssetWriterInput, reader: AVAssetReader, writer: AVAssetWriter, duration: Double = 0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var reportedProgress = 0.0
        while true {
            try Task.checkCancellation()
            guard reader.status != .failed, reader.status != .cancelled else {
                throw reader.error ?? failure("Reading was interrupted.")
            }
            guard writer.status == .writing else {
                throw writer.error ?? failure("Encoding was interrupted.")
            }
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return
            }
            guard input.append(sample) else {
                throw writer.error ?? failure("Cannot append an encoded sample.")
            }
            /// Update progress in one-percent steps. Leave the last percent for finishing the file.
            if let progress, duration > 0 {
                let timestamp = sample.presentationTimeStamp.seconds
                let fraction = timestamp.isFinite ? min(0.99, max(0, timestamp / duration)) : 0
                if fraction - reportedProgress >= 0.01 {
                    reportedProgress = fraction
                    progress(fraction)
                }
            }
        }
    }
    
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "GoodFrame", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: Export Windows and Storage

/// File information shown in the export window.
struct ExportSummary {
    let codec: String
    let bitrate: Double
    let bytes: Int64
    let elapsed: TimeInterval
    let isHDR: Bool
    let resolution: CGSize
    var imageFormat: String? = nil
}

/// Show image file information, or video encoding information.
struct ExportInformation: View {
    let summary: ExportSummary
    
    private var description: String {
        if let format = summary.imageFormat {
            return "\(format)\(summary.isHDR ? " · HDR" : "") · \(Int(summary.resolution.width)) × \(Int(summary.resolution.height)) px · \(summary.bytes.formatted(.byteCount(style: .file).locale(CropFormatting.locale)))"
        }
        return "\(summary.codec) · \(summary.isHDR ? "HDR" : "SDR") · \(Int(summary.resolution.width)) × \(Int(summary.resolution.height)) · \(summary.bitrate.formatted(.number.precision(.fractionLength(2)).locale(CropFormatting.locale))) Mbps · \(summary.bytes.formatted(.byteCount(style: .file).locale(CropFormatting.locale))) · exported in \(summary.elapsed.formatted(.number.precision(.fractionLength(1)).locale(CropFormatting.locale))) s"
    }
    
    var body: some View {
        Text(description)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
    }
}

/// The export window and its Save and Discard behavior.
final class ExportDocument: NSDocument {
    
    private let temporaryExportURL: URL
    private let temporaryDirectory: URL
    private weak var parentWindow: NSWindow?
    private let contentType: UTType
    private var exportPlayer: AVPlayer?
    private let summary: ExportSummary
    private var loopEnabled = false
    private var endObserver: NSObjectProtocol?
    
    init(exportURL: URL, title: String, summary: ExportSummary, contentType: UTType = .quickTimeMovie, parentWindow: NSWindow? = nil) throws {
        /// Give the dragged file the same name as the export window.
        let directory = exportURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let namedExport = directory.appendingPathComponent(title).appendingPathExtension(exportURL.pathExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: exportURL, to: namedExport)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        temporaryDirectory = directory
        temporaryExportURL = namedExport
        self.parentWindow = parentWindow
        self.contentType = contentType
        self.summary = summary
        super.init()
        displayName = title
        fileType = contentType.identifier
        updateChangeCount(.changeDone)
    }
    
    override class var writableTypes: [String] { [UTType.quickTimeMovie.identifier, UTType.png.identifier, UTType.jpeg.identifier] }
    
    override class var autosavesInPlace: Bool { false }
    
    override var autosavingFileType: String? { nil }
    
    /// Images get a still preview. Videos use the standard playback controls.
    override func makeWindowControllers() {
        if contentType.conforms(to: .image), let source = try? ImageSource.load(temporaryExportURL) {
            let image = NSImage(cgImage: source.image, size: .zero)
            addExportWindow(content: NSHostingView(rootView: ExportImageView(image: image, summary: summary)))
            return
        }
        let playerView = AVPlayerView()
        let player = AVPlayer(url: temporaryExportURL)
        exportPlayer = player
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        let playbackMenu = NSMenu()
        let loopItem = NSMenuItem(title: String(localized: "Loop"), action: #selector(toggleLoop(_:)), keyEquivalent: "")
        loopItem.target = self
        playbackMenu.addItem(loopItem)
        playerView.actionPopUpButtonMenu = playbackMenu
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard self?.loopEnabled == true else { return }
                player?.seek(to: .zero) { [weak player] finished in if finished { player?.play() } }
            }
        }
        if let overlay = playerView.contentOverlayView {
            let information = NSHostingView(rootView: ExportInformation(summary: summary))
            information.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(information)
            NSLayoutConstraint.activate([
                information.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
                information.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 12),
                information.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -12),
            ])
        }
        addExportWindow(content: playerView)
    }
    
    /// Images and videos use the same export window and file icon.
    private func addExportWindow(content: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = content
        let controller = ExportWindowController(window: window)
        addWindowController(controller)
        window.delegate = controller
        controller.synchronizeWindowTitleWithDocumentName()
        positionExportWindow(window)
    }
    
    /// The file represented by the title-bar icon, before or after saving.
    var exportFileURL: URL { fileURL ?? temporaryExportURL }
    
    /// Copy the full image, including its original PNG or JPEG data.
    @objc func copy(_ sender: Any?) {
        guard contentType.conforms(to: .image),
              let data = try? Data(contentsOf: temporaryExportURL) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(contentType.identifier))
        /// TIFF lets apps that do not read PNG or JPEG from the clipboard paste the image too.
        if let tiff = NSImage(data: data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
    
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return contentType.conforms(to: .image) }
        return super.validateUserInterfaceItem(item)
    }
    
    /// Center the export window over the exporting window and keep it on screen.
    private func positionExportWindow(_ window: NSWindow) {
        guard let screen = parentWindow?.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let parentFrame = parentWindow?.frame ?? visibleFrame
        var exportWindowFrame = window.frame
        exportWindowFrame.size.width = min(exportWindowFrame.width, visibleFrame.width)
        exportWindowFrame.size.height = min(exportWindowFrame.height, visibleFrame.height)
        exportWindowFrame.origin.x = min(max(parentFrame.midX - exportWindowFrame.width / 2, visibleFrame.minX), visibleFrame.maxX - exportWindowFrame.width)
        exportWindowFrame.origin.y = min(max(parentFrame.midY - exportWindowFrame.height / 2, visibleFrame.minY), visibleFrame.maxY - exportWindowFrame.height)
        window.setFrame(exportWindowFrame, display: false)
    }
    
    /// Turn looping on or off in the player menu.
    @objc private func toggleLoop(_ sender: NSMenuItem) {
        loopEnabled.toggle()
        sender.state = loopEnabled ? .on : .off
    }
    
    /// Save with the extension that matches the exported format.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [contentType]
        let fileExtension = contentType == .jpeg ? "jpg" : (contentType.preferredFilenameExtension ?? "mov")
        savePanel.nameFieldStringValue = displayName.hasSuffix("." + fileExtension) ? displayName : displayName + "." + fileExtension
        savePanel.isExtensionHidden = false
        return true
    }
    
    /// Save a copy of the export.
    override func write(to url: URL, ofType typeName: String) throws {
        try FileManager.default.copyItem(at: temporaryExportURL, to: url)
    }
    
    /// Close the export window and delete its temporary export after saving or discarding it.
    override func close() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        exportPlayer?.pause()
        exportPlayer?.replaceCurrentItem(with: nil)
        exportPlayer = nil
        super.close()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    
    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    
}

/// Keep the export window's file icon in sync with Save and allow dragging the export.
final class ExportWindowController: NSWindowController, NSWindowDelegate, NSDraggingSource {
    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        window?.representedURL = (document as? ExportDocument)?.exportFileURL
    }
    
    /// Drag a copy of the file while keeping the export window available.
    func window(_ window: NSWindow, shouldDragDocumentWith event: NSEvent, from dragImageLocation: NSPoint, with pasteboard: NSPasteboard) -> Bool {
        guard let url = (document as? ExportDocument)?.exportFileURL,
              let content = window.contentView else { return false }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let frame = content.convert(NSRect(origin: dragImageLocation, size: NSSize(width: 16, height: 16)), from: nil)
        item.setDraggingFrame(frame, contents: icon)
        content.beginDraggingSession(with: [item], event: event, source: self)
        return false
    }
    
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Store temporary exports and clean up files left by a previous app crash.
final class ExportTemporaryStorage {
    
    static let shared = ExportTemporaryStorage()
    let directory: URL
    private let lockDescriptor: Int32
    private var terminationObserver: NSObjectProtocol?
    
    private init() {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("GoodFrame-Exports", isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        let recoveryLock = open(root.appendingPathComponent("recovery.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if recoveryLock >= 0 { flock(recoveryLock, LOCK_EX) }
        defer { if recoveryLock >= 0 { Darwin.close(recoveryLock) } }
        for candidate in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let descriptor = open(candidate.appendingPathComponent("session.lock").path, O_RDWR)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try? manager.removeItem(at: candidate)
            }
            Darwin.close(descriptor)
        }
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        lockDescriptor = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_EX | LOCK_NB) }
        let sessionDirectory = directory
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
    }
    
    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }
    
}
