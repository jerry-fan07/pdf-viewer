import SwiftUI
import PDFKit
import CoreImage

enum NavigationPane: String, CaseIterable, Identifiable {
    case pages, bookmarks, search, conversations, attachments

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pages: "square.grid.2x2"
        case .bookmarks: "bookmark"
        case .search: "magnifyingglass"
        case .conversations: "bubble.left.and.bubble.right"
        case .attachments: "paperclip"
        }
    }

    var title: String {
        switch self {
        case .pages: "Pages"
        case .bookmarks: "Bookmarks"
        case .search: "Search"
        case .conversations: "Conversations"
        case .attachments: "Attachments"
        }
    }
}

/// The icon rail down the window's left edge. Clicking the open pane's icon folds it.
struct NavigationRail: View {
    @Binding var pane: NavigationPane?
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(NavigationPane.allCases) { item in
                ChromeIconButton(systemImage: item.symbol, help: item.title,
                                 isOn: pane == item, size: 30, iconSize: 14) {
                    pane = pane == item ? nil : item
                }
            }
            Spacer()
            ChromeIconButton(systemImage: "gearshape", help: "Settings (⌘,)", size: 30, iconSize: 14,
                             action: openSettings)
        }
        .padding(.vertical, 8)
        .frame(width: ChromeInk.railWidth)
        .frame(maxHeight: .infinity)
        .background(ChromeInk.bar)
    }
}

/// Whichever pane the rail has open.
struct NavigationPanel: View {
    let pane: NavigationPane
    let document: PDFDocument
    @ObservedObject var viewer: PDFViewerController
    @ObservedObject var engine: ChatEngine
    var darkPages: Bool
    /// Changes whenever a note is put on a page or taken off one — the thumbnails show them.
    var notesRevision = 0
    var onClose: () -> Void
    var onOpenConversation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeading(title: pane.title) {
                ChromeIconButton(systemImage: "ellipsis", help: "Options", size: 22, iconSize: 11) {}
                ChromeIconButton(systemImage: "xmark", help: "Close", size: 22, iconSize: 10, action: onClose)
            }
            HDivider()
            switch pane {
            case .pages:
                ThumbnailList(document: document, viewer: viewer, darkPages: darkPages, revision: notesRevision)
            case .bookmarks:
                OutlineList(document: document, viewer: viewer)
            case .search:
                SearchResultsList(viewer: viewer)
            case .conversations:
                ConversationList(engine: engine, viewer: viewer, onOpen: onOpenConversation)
            case .attachments:
                PanelEmptyState(symbol: "paperclip", title: "No attachments",
                                detail: "Files embedded in this PDF appear here.")
            }
        }
        .background(ChromeInk.panel)
    }
}

struct PanelEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(ChromeInk.tertiary)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ChromeInk.secondary)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(ChromeInk.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pages

@MainActor
private final class ThumbnailCache: ObservableObject {
    private var images: [String: NSImage] = [:]

    func image(for page: PDFPage, index: Int, dark: Bool, revision: Int) -> NSImage {
        let key = "\(index)|\(dark)|\(revision)"
        if let cached = images[key] { return cached }
        var image = page.thumbnail(of: CGSize(width: 260, height: 340), for: .cropBox)
        if dark { image = PageImageDarkening.darken(image) ?? image }
        images[key] = image
        return image
    }
}

/// The page filter, approximately, for a page drawn as an image outside PDFKit:
/// inverted, hues kept, paper down to near-black rather than black.
enum PageImageDarkening {
    static func darken(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) else { return nil }
        let output = input.applyingFilter("CIColorInvert")
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.73, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.73, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.73, w: 0),
                "inputBiasVector": CIVector(x: 0.06, y: 0.06, z: 0.065, w: 0),
            ])
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: image.size)
    }
}

private struct ThumbnailList: View {
    let document: PDFDocument
    @ObservedObject var viewer: PDFViewerController
    var darkPages: Bool
    var revision: Int
    @StateObject private var cache = ThumbnailCache()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        if let page = document.page(at: index) {
                            thumbnail(page: page, index: index)
                                .id(index + 1)
                        }
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewer.currentPageNumber) { _, page in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(page, anchor: .center) }
            }
        }
    }

    private func thumbnail(page: PDFPage, index: Int) -> some View {
        let number = index + 1
        let current = viewer.currentPageNumber == number
        return Button {
            viewer.scroll(toPage: number)
        } label: {
            VStack(spacing: 5) {
                Image(nsImage: cache.image(for: page, index: index, dark: darkPages, revision: revision))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 104)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(current ? ChromeInk.accent : .clear, lineWidth: 2)
                    )
                Text(page.label ?? "\(number)")
                    .font(.system(size: 10.5, weight: current ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(current ? ChromeInk.accent : ChromeInk.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bookmarks

private struct OutlineRow: Identifiable {
    let id: Int
    let title: String
    let depth: Int
    let destination: PDFDestination?
    let pageNumber: Int?
}

private struct OutlineList: View {
    let document: PDFDocument
    @ObservedObject var viewer: PDFViewerController

    var body: some View {
        let rows = flatten()
        if rows.isEmpty {
            PanelEmptyState(symbol: "bookmark", title: "No bookmarks",
                            detail: "This document has no outline.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        OutlineRowView(row: row, isCurrent: row.pageNumber == viewer.currentPageNumber) {
                            if let destination = row.destination { viewer.pdfView?.go(to: destination) }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func flatten() -> [OutlineRow] {
        guard let root = document.outlineRoot else { return [] }
        var rows: [OutlineRow] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let page = child.destination?.page.map { document.index(for: $0) + 1 }
                rows.append(OutlineRow(id: rows.count, title: child.label ?? "Untitled",
                                       depth: depth, destination: child.destination, pageNumber: page))
                if depth < 2 { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return rows
    }
}

private struct OutlineRowView: View {
    let row: OutlineRow
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.system(size: 11.5, weight: row.depth == 0 ? .medium : .regular))
                    .foregroundStyle(ChromeInk.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let page = row.pageNumber {
                    Text("\(page)")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(ChromeInk.tertiary)
                }
            }
            .padding(.leading, 12 + CGFloat(row.depth) * 12)
            .padding(.trailing, 10)
            .frame(height: 24)
            .background(isCurrent ? ChromeInk.accentSoft : hovering ? ChromeInk.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Search

private struct SearchResultsList: View {
    @ObservedObject var viewer: PDFViewerController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeInk.tertiary)
                TextField("Search document", text: $viewer.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(ChromeInk.well))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ChromeInk.divider))
            .padding(10)

            if !viewer.matches.isEmpty {
                HStack {
                    Text("\(viewer.matches.count) results")
                    Spacer()
                    Text("Whole words · Match case").foregroundStyle(ChromeInk.tertiary)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(ChromeInk.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                HDivider()
            }

            if viewer.matches.isEmpty {
                PanelEmptyState(
                    symbol: "text.magnifyingglass",
                    title: viewer.searchQuery.count >= 2 ? "No results" : "Search this document",
                    detail: "Results are listed by page."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewer.matches.prefix(200).enumerated()), id: \.offset) { index, match in
                            SearchResultRow(match: match, isCurrent: index == viewer.currentMatchIndex) {
                                viewer.pdfView?.go(to: match)
                                viewer.pdfView?.setCurrentSelection(match, animate: true)
                            }
                            HDivider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }
}

private struct SearchResultRow: View {
    let match: PDFSelection
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pageLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ChromeInk.secondary)
                Text(context)
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeInk.text)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isCurrent ? ChromeInk.accentSoft : hovering ? ChromeInk.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var pageLabel: String {
        guard let page = match.pages.first, let document = page.document else { return "" }
        return "PAGE \(document.index(for: page) + 1)"
    }

    private var context: AttributedString {
        let hit = match.string ?? ""
        guard let wider = match.copy() as? PDFSelection else { return AttributedString(hit) }
        wider.extend(atStart: 28)
        wider.extend(atEnd: 48)
        let text = (wider.string ?? hit).replacingOccurrences(of: "\n", with: " ")
        var attributed = AttributedString(text)
        if let range = attributed.range(of: hit, options: .caseInsensitive) {
            attributed[range].font = .system(size: 11, weight: .bold)
            attributed[range].backgroundColor = Color.yellow.opacity(0.35)
        }
        return attributed
    }
}

// MARK: - Conversations

private struct ConversationList: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var viewer: PDFViewerController
    let onOpen: () -> Void

    var body: some View {
        let threads = engine.threads.filter { $0.title != nil }
        VStack(spacing: 0) {
            Button {
                engine.startNewThread(at: viewer.currentPageAnchor)
                onOpen()
                engine.requestComposerFocus()
            } label: {
                Label("New conversation", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChromeTextButtonStyle())
            .padding(6)
            HDivider()
            if threads.isEmpty {
                PanelEmptyState(symbol: "bubble.left.and.bubble.right", title: "No conversations",
                                detail: "Questions you ask about this document are kept here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(threads) { thread in
                            ConversationRow(thread: thread, isSelected: thread.id == engine.threadID) {
                                engine.selectThread(thread.id)
                                viewer.scroll(toPage: thread.anchor.page)
                                onOpen()
                            }
                            HDivider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let thread: ConversationThread
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.displayTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ChromeInk.text)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if thread.isStreaming {
                        Circle().fill(ChromeInk.accent).frame(width: 5, height: 5)
                    }
                    Text(meta)
                }
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(ChromeInk.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? ChromeInk.accentSoft : hovering ? ChromeInk.hover : .clear)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(ChromeInk.accent).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var meta: String {
        var parts = ["p. \(thread.anchor.page)",
                     thread.answerCount == 1 ? "1 answer" : "\(thread.answerCount) answers"]
        if thread.costUSD > 0 { parts.append(TokenPricing.format(thread.costUSD)) }
        if let date = thread.startedAt {
            parts.append(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        }
        return parts.joined(separator: " · ")
    }
}
