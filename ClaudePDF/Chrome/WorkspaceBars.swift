import SwiftUI
import PDFKit

// MARK: - Top bar

/// The one bar across the top: the document, where you are in it, how big it is,
/// find, and the assistant. The traffic lights sit in its leading inset.
struct TopBar: View {
    let title: String
    @ObservedObject var viewer: PDFViewerController
    @ObservedObject var canvas: CanvasState
    @Binding var navigationOpen: Bool
    @Binding var assistantOpen: Bool
    @Binding var darkPages: Bool
    var searchFocused: FocusState<Bool>.Binding
    var onSnapshot: () -> Void

    @State private var pageField = "1"

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 76)   // traffic lights
            ChromeIconButton(systemImage: "sidebar.left", help: "Navigation panel (⌃⌘S)",
                             isOn: navigationOpen) { navigationOpen.toggle() }
            VDivider().padding(.horizontal, 8)
            documentTitle
            Spacer(minLength: 12)
            pageControls
            VDivider().padding(.horizontal, 10)
            zoomControls
            Spacer(minLength: 12)
            searchField
            ChromeIconButton(systemImage: "viewfinder", help: "Snapshot a region and ask (⇧⌘A)",
                             action: onSnapshot)
                .padding(.leading, 6)
            ChromeIconButton(systemImage: "moon", help: "Dark pages (⇧⌘D)", isOn: darkPages) {
                darkPages.toggle()
            }
            ChromeIconButton(systemImage: "square.and.arrow.up", help: "Share") {}
            VDivider().padding(.horizontal, 8)
            Button {
                assistantOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    Text("AI Assistant")
                }
            }
            .buttonStyle(AssistantToggleStyle(isOn: assistantOpen))
            .help("Ask about this document (⌥⌘I)")
            .padding(.trailing, 10)
        }
        .frame(height: ChromeInk.barHeight)
        .background(WindowDragArea())
        .background(ChromeInk.bar)
        .overlay(alignment: .bottom) { HDivider() }
        .onChange(of: viewer.currentPageNumber) { _, page in pageField = String(page) }
    }

    private var documentTitle: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChromeInk.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 280, alignment: .leading)
        .allowsHitTesting(false)
    }

    private var pageControls: some View {
        HStack(spacing: 2) {
            ChromeIconButton(systemImage: "chevron.up", help: "Previous page", iconSize: 11) {
                viewer.scroll(toPage: viewer.currentPageNumber - 1)
            }
            ChromeIconButton(systemImage: "chevron.down", help: "Next page", iconSize: 11) {
                viewer.scroll(toPage: viewer.currentPageNumber + 1)
            }
            TextField("", text: $pageField)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 34, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(ChromeInk.well))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ChromeInk.divider))
                .onSubmit {
                    if let page = Int(pageField) { viewer.scroll(toPage: page) }
                    pageField = String(viewer.currentPageNumber)
                }
                .padding(.leading, 4)
            Text("/ \(viewer.pageCount)")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(ChromeInk.secondary)
                .padding(.leading, 5)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            ChromeIconButton(systemImage: "minus", help: "Zoom out (⌘−)", iconSize: 11) { viewer.zoomOut() }
            Menu {
                ForEach(CanvasState.presets, id: \.self) { scale in
                    Button("\(Int(scale * 100))%") { canvas.setZoom(scale) }
                }
                Divider()
                Button("Fit Width") { canvas.fitWidth() }
                Button("Fit Page") { canvas.fitPage() }
            } label: {
                HStack(spacing: 3) {
                    Text("\(Int((canvas.zoom * 100).rounded()))%")
                        .monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(ChromeInk.tertiary)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(ChromeInk.text)
                .frame(width: 58, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(ChromeInk.well))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ChromeInk.divider))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            ChromeIconButton(systemImage: "plus", help: "Zoom in (⌘=)", iconSize: 11) { viewer.zoomIn() }
            ChromeIconButton(systemImage: "arrow.left.and.right.square", help: "Fit width (⌘0)", iconSize: 12) {
                canvas.fitWidth()
            }
            .padding(.leading, 2)
            ChromeIconButton(systemImage: "arrow.up.and.down.square", help: "Fit page", iconSize: 12) {
                canvas.fitPage()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(ChromeInk.tertiary)
            TextField("", text: $viewer.searchQuery, prompt: Text("Find in document").foregroundStyle(ChromeInk.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused(searchFocused)
                .onSubmit { viewer.nextMatch() }
                .onExitCommand {
                    viewer.searchQuery = ""
                    searchFocused.wrappedValue = false
                }
            if !viewer.matches.isEmpty {
                Text("\(viewer.currentMatchIndex + 1)/\(viewer.matches.count)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(ChromeInk.secondary)
                    .fixedSize()
                Button { viewer.previousMatch() } label: {
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                Button { viewer.nextMatch() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘F")
                    .font(.system(size: 10))
                    .foregroundStyle(ChromeInk.tertiary)
            }
        }
        .foregroundStyle(ChromeInk.secondary)
        .padding(.horizontal, 8)
        .frame(width: 210, height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(ChromeInk.well))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(searchFocused.wrappedValue ? ChromeInk.accent : ChromeInk.divider,
                              lineWidth: searchFocused.wrappedValue ? 1.5 : 1)
        )
    }
}

private struct AssistantToggleStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isOn ? ChromeInk.accent : .white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? ChromeInk.accentSoft : ChromeInk.accent)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Quick tools

/// The floating tool palette at the canvas's left edge.
struct QuickToolPalette: View {
    @ObservedObject var canvas: CanvasState
    @Binding var cropMode: Bool
    var onAsk: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            tool(.select)
            tool(.hand)
            separator
            tool(.highlight)
            tool(.comment)
            tool(.draw)
            separator
            ChromeIconButton(systemImage: "viewfinder", help: "Snapshot a region and ask (⇧⌘A)",
                             isOn: cropMode, size: 30, iconSize: 14) { cropMode.toggle() }
            ChromeIconButton(systemImage: "sparkles", help: "Ask about the selection (⌘L)",
                             size: 30, iconSize: 14, action: onAsk)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 9).fill(ChromeInk.raised))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ChromeInk.divider))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func tool(_ tool: CanvasTool) -> some View {
        ChromeIconButton(systemImage: tool.symbol, help: tool.title,
                         isOn: canvas.tool == tool && !cropMode, size: 30, iconSize: 14) {
            cropMode = false
            canvas.tool = tool
        }
    }

    private var separator: some View {
        Rectangle().fill(ChromeInk.divider).frame(width: 20, height: 1).padding(.vertical, 3)
    }
}

/// Shown over the canvas while a region is being dragged out.
struct CropHint: View {
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "viewfinder")
            Text("Drag to snapshot a region")
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.75))
            Text("esc").foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color.black.opacity(0.78)))
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var viewer: PDFViewerController
    @ObservedObject var canvas: CanvasState
    @ObservedObject var engine: ChatEngine

    var body: some View {
        HStack(spacing: 10) {
            if let size = canvas.pageSizeLabel {
                Label(size, systemImage: "ruler")
            }
            VDivider(height: 12)
            Text("Page \(viewer.currentPageNumber) of \(viewer.pageCount)")
            if !viewer.matches.isEmpty {
                VDivider(height: 12)
                Text("\(viewer.matches.count) matches")
            }
            Spacer()
            providerStatus
            VDivider(height: 12)
            layoutPicker
            VDivider(height: 12)
            zoomSlider
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(ChromeInk.secondary)
        .labelStyle(StatusLabelStyle())
        .padding(.horizontal, 10)
        .frame(height: ChromeInk.statusHeight)
        .background(ChromeInk.bar)
        .overlay(alignment: .top) { HDivider() }
    }

    private var providerStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(engine.attachError != nil ? Color.red
                      : engine.attachStatus != nil || engine.isStreaming ? Color.orange
                      : Color.green)
                .frame(width: 6, height: 6)
            Text(engine.attachStatus ?? (engine.isStreaming ? "Answering…" : "\(engine.providerName) · Ready"))
                .lineLimit(1)
        }
    }

    private var layoutPicker: some View {
        HStack(spacing: 1) {
            ForEach(CanvasLayout.allCases) { layout in
                ChromeIconButton(systemImage: layout.symbol, help: layout.title,
                                 isOn: canvas.layout == layout, size: 20, iconSize: 10.5) {
                    canvas.layout = layout
                }
            }
        }
    }

    private var zoomSlider: some View {
        HStack(spacing: 6) {
            Button { viewer.zoomOut() } label: { Image(systemName: "minus") }
                .buttonStyle(.plain)
            Slider(value: Binding(
                get: { Double(min(max(canvas.zoom, 0.25), 4)) },
                set: { canvas.setZoom(CGFloat($0)) }
            ), in: 0.25...4)
            .controlSize(.mini)
            .frame(width: 90)
            Button { viewer.zoomIn() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
            Text("\(Int((canvas.zoom * 100).rounded()))%")
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9.5))
            configuration.title
        }
    }
}
