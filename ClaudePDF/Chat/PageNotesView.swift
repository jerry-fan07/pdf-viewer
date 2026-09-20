import SwiftUI
import AppKit

/// What is stuck to one page's right edge: the tabs of the conversations that were
/// started on it, a "+" to start another, and — while one of them is open — its
/// chat sheet, unfolded beside its tab.
///
/// A conversation is a note about a page. Its tab stands on that page, level with
/// the passage it was first asked about, and stays there: this view is laid out in
/// *page points* and drawn at whatever scale the page is (`ScaledHost`), so tabs
/// and sheet grow, shrink, scroll and pan as the paper does. Nothing here knows
/// where the window is.
struct PageNotesView: View {
    /// 1-indexed.
    let page: Int
    let pageHeight: CGFloat
    @ObservedObject var engine: ChatEngine
    @ObservedObject var viewer: PDFViewerController
    @ObservedObject var model: PageNotesModel

    @State private var confirmingDeleteAll = false

    var body: some View {
        let notes = self.notes
        let layout = NoteTab.layout(notes, pageHeight: pageHeight)
        let open = notes.first { $0.id == engine.threadID && model.isOpen }

        ZStack(alignment: .topLeading) {
            if let open, let slot = layout.slots.first(where: { $0.id == open.id }) {
                sheet(besideTabAt: slot.top)
            }
            ForEach(notes) { note in
                if let slot = layout.slots.first(where: { $0.id == note.id }) {
                    tab(for: note, isOpen: note.id == open?.id, titleLength: slot.titleLength)
                        .offset(y: slot.top)
                }
            }
            addButton.offset(y: layout.addTop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Delete all \(engine.threads.count) conversations about this document?",
            isPresented: $confirmingDeleteAll
        ) {
            Button("Delete All", role: .destructive) {
                model.isOpen = false
                engine.clearHistory()
            }
        } message: {
            Text("Their questions and answers are removed from this Mac. The document itself is untouched.")
        }
    }

    /// This page's conversations. The blank one — a note put down and not yet
    /// written on — is only here while it is open: folded away it would be a tab
    /// about nothing, and the "+" already offers that.
    private var notes: [ConversationThread] {
        engine.threads.filter { $0.anchor.page == page && ($0.title != nil || model.isOpen) }
    }

    // MARK: Tabs

    private func tab(for note: ConversationThread, isOpen: Bool, titleLength: CGFloat) -> some View {
        Button {
            select(note.id)
        } label: {
            NoteTab(thread: note, isSelected: note.id == engine.threadID && model.isOpen,
                    isOpen: isOpen, titleLength: titleLength)
        }
        .buttonStyle(.plain)
        .help(help(for: note, isOpen: isOpen))
        .contextMenu {
            Button(isOpen ? "Collapse" : "Open") { select(note.id) }
            Divider()
            Button("Delete Conversation", role: .destructive) { delete(note.id) }
                .disabled(note.isStreaming)
            Button("Delete All Conversations…", role: .destructive) { confirmingDeleteAll = true }
                .disabled(!engine.hasHistory || engine.isStreaming)
        }
    }

    private var addButton: some View {
        Button {
            engine.startNewThread(at: NoteAnchor(page: page))
            model.isOpen = true
            engine.requestComposerFocus()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PanelInk.fainter)
                .frame(width: NoteTab.shutWidth, height: NoteTabLayout.addHeight)
                .background(NoteTab.shape.fill(PanelInk.background.opacity(0.6)))
                .overlay(NoteTab.shape.stroke(PanelInk.hairlineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(engine.isStreaming)
        .help("New conversation on page \(page) — a fresh note about the same document. "
              + "It stays prepared, so nothing is re-uploaded and no cache is re-paid.")
    }

    /// A click on a tab. The open one folds its sheet away; any other opens —
    /// switching conversation on the way if it is not the selected one.
    private func select(_ id: UUID) {
        if id == engine.threadID {
            model.isOpen.toggle()
        } else {
            engine.selectThread(id)
            model.isOpen = true
        }
        if model.isOpen { engine.requestComposerFocus() }
    }

    private func delete(_ id: UUID) {
        // Deleting the open note must not unfold whichever one the engine lands on
        // next, on whatever page that is.
        if id == engine.threadID { model.isOpen = false }
        engine.deleteThread(id)
    }

    private func help(for note: ConversationThread, isOpen: Bool) -> String {
        guard let title = note.title else {
            return "A new conversation — nothing asked yet"
        }
        var facts = [note.answerCount == 1 ? "1 answer" : "\(note.answerCount) answers"]
        if let started = note.startedAt {
            facts.append(started.formatted(date: .abbreviated, time: .shortened))
        }
        if note.costUSD > 0 { facts.append(TokenPricing.format(note.costUSD)) }
        let action = isOpen ? "Click to collapse" : "Click to open"
        return "\(title)\n\(facts.joined(separator: " · "))\n\(action)"
    }

    // MARK: The open note's sheet

    private func sheet(besideTabAt tabTop: CGFloat) -> some View {
        let frame = NoteTabLayout.sheetFrame(tabTop: tabTop, pageHeight: pageHeight, wanted: model.wantedSheetHeight)
        return ChatPanelView(engine: engine, viewer: viewer, onCollapse: { model.isOpen = false })
            .frame(width: model.sheetWidth, height: frame.height)
            .overlay(Rectangle().stroke(PanelInk.hairlineEdge, lineWidth: 1))
            .overlay(alignment: .leading) { SheetWidthHandle(model: model, viewer: viewer) }
            .offset(x: PageNotesModel.tabColumn, y: frame.top)
    }
}

// MARK: - One tab

/// Internal rather than private so the snapshot harness renders the real thing.
///
/// Titles run down the tab the way a book's spine does. The full title is one
/// hover away, and at the head of the sheet once open.
struct NoteTab: View {
    let thread: ConversationThread
    let isSelected: Bool
    /// Selected *and* unfolded: the tab is drawn as part of its sheet.
    let isOpen: Bool
    /// The most of the title there is room for — less on a page crowded with notes.
    var titleLength: CGFloat = NoteTabLayout.maxTitleLength

    var body: some View {
        VStack(spacing: Self.gap) {
            Sideways {
                Text(thread.displayTitle)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .kerning(0.1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(titleInk)
                    .frame(width: titleLength)
                    .rotationEffect(.degrees(90))
            }
            Text(thread.answerCount > 0 ? "\(thread.answerCount)" : " ")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(isSelected ? PanelInk.faint : PanelInk.fainter)
                .frame(height: Self.countHeight)
        }
        .padding(.vertical, Self.padding)
        .frame(width: Self.shutWidth)
        // An open tab reaches across to the sheet it opened; a shut one stops
        // short of where the sheet would be. Both start flush against the page.
        .frame(width: isOpen ? Self.openWidth : Self.shutWidth, alignment: .leading)
        .frame(height: Self.height(titleLength: titleLength), alignment: .top)
        .background(Self.shape.fill(PanelInk.background))
        .overlay(alignment: .top) {
            // In the tab's own top margin, so a tab is as tall answering as not.
            if thread.isStreaming {
                StreamingDot().frame(width: Self.shutWidth).padding(.top, 3)
            }
        }
        .overlay {
            // Paper on a backdrop that may be barely darker than it needs an edge.
            // The open tab has none on the sheet's side: it is one piece with it.
            if !isOpen {
                Self.shape.stroke(PanelInk.hairlineStrong, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }

    /// How far a shut tab sticks out of the page, and an open one: to its sheet.
    static let shutWidth: CGFloat = 25
    static let openWidth: CGFloat = 30

    private static let padding: CGFloat = 10
    private static let gap: CGFloat = 6
    private static let countHeight: CGFloat = 11

    /// A tab's height follows from how much title it shows, so that where the tabs
    /// go can be worked out without laying any of them out (`NoteTabLayout`).
    static func height(titleLength: CGFloat) -> CGFloat {
        padding * 2 + titleLength + gap + countHeight
    }

    /// Where `notes` — one page's — stand along its edge.
    static func layout(_ notes: [ConversationThread], pageHeight: CGFloat) -> NoteTabLayout.Result {
        NoteTabLayout.place(
            notes.map { .init(id: $0.id, y: $0.anchor.y, titleWidth: titleWidth($0.displayTitle)) },
            pageHeight: pageHeight, tabHeight: height(titleLength:)
        )
    }

    /// Measured the way it is drawn: 11pt system, a little kerning, medium at its
    /// widest — so a title that fits shut still fits once its tab is selected.
    private static func titleWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return (title as NSString).size(withAttributes: [.font: font, .kern: 0.1]).width + 2
    }

    /// Square against the page, rounded where it sticks out.
    static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6)
    }

    private var titleInk: Color {
        if isSelected { return PanelInk.ink }
        return thread.title == nil ? PanelInk.fainter : PanelInk.faint
    }
}

/// An answer is arriving in this note. It breathes rather than spins: the reader
/// may be on another page entirely, and this is at the edge of their eye.
private struct StreamingDot: View {
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(PanelInk.ink)
            .frame(width: 5, height: 5)
            .opacity(dimmed ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

// MARK: - Sideways text

/// Lays its one subview out as if turned a quarter — reporting its height as a
/// width and its width as a height — and leaves the turning itself to a
/// `rotationEffect` on the subview. `rotationEffect` alone does not do this: it
/// turns what is drawn and leaves the layout believing the text still lies flat,
/// which on a 25pt tab means a title truncated to three letters.
private struct Sideways: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let flat = subview.sizeThatFits(ProposedViewSize(width: proposal.height, height: proposal.width))
        return CGSize(width: flat.height, height: flat.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: bounds.height, height: bounds.width)
        )
    }
}

// MARK: - The sheet's width

/// The sheet's page-side edge is its handle. Beside a fitted page that edge is the
/// one that moves — the sheet's far edge is the window's, and a wider sheet is a
/// smaller page — so the width is worked out from where the pointer is, and the
/// edge stays under it. Zoomed, the page does not move for the sheet, and the drag
/// is simply measured, at the page's scale.
private struct SheetWidthHandle: View {
    @ObservedObject var model: PageNotesModel
    let viewer: PDFViewerController

    @State private var hovering = false
    @State private var start: (width: CGFloat, pointer: CGFloat, scale: CGFloat)?

    var body: some View {
        Color.clear
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // Folding the sheet away takes the handle from under the pointer, and
            // a handle that is gone never reports the pointer leaving it.
            .onDisappear {
                if hovering { NSCursor.pop() }
                hovering = false
            }
            .gesture(
                // The pointer is asked of AppKit, in the screen: this view is drawn
                // scaled and moves as it is dragged, so a translation measured in
                // its own space would be chasing its own tail.
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in drag(to: NSEvent.mouseLocation.x) }
                    .onEnded { _ in
                        start = nil
                        model.keepSheetWidth()
                    }
            )
    }

    private func drag(to pointer: CGFloat) {
        guard let view = viewer.pdfView, view.scaleFactor > 0 else { return }
        if start == nil { start = (model.sheetWidth, pointer, view.scaleFactor) }
        guard let start else { return }

        guard view.autoScales, let window = view.window else {
            model.sheetWidth = PageNotesModel.clamp(start.width - (pointer - start.pointer) / start.scale)
            return
        }
        // Fitted: page, tabs and sheet fill the viewer between them, so the sheet's
        // share of the three is the pointer's distance from the viewer's far side,
        // and the other two — which the drag does not change — are the rest.
        let viewerFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let rest = viewerFrame.width / start.scale - start.width
        let share = min(max((viewerFrame.maxX - pointer) / max(viewerFrame.width, 1), 0.05), 0.9)
        model.sheetWidth = PageNotesModel.clamp(rest * share / (1 - share))
    }
}
