import SwiftUI

/// The nonmodal map and floating sheet shared by the transport tabs.
struct MapSheetScaffold<MapContent: View, HeaderContent: View, SheetContent: View>: View {
    let title: String
    var summary: String? = nil
    let isLoading: Bool
    let onRecenter: () -> Void
    var onRefresh: (() async -> Void)? = nil
    let presentation: MapSheetPresentation
    var departureListFocusID: String? = nil
    var peekDeparture: MapPeekDeparture? = nil
    /// Sheets without a departure preview collapse to this button alone.
    var collapsedTitle: String? = nil

    @ViewBuilder var mapContent: MapContent
    @ViewBuilder var headerContent: HeaderContent
    @ViewBuilder var sheetContent: SheetContent

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false
    @State private var peekContentHeight: CGFloat = 100

    private var detent: MapSheetPresentation.Detent { presentation.detent }

    var body: some View {
        GeometryReader { proxy in
            if #available(iOS 27.1, *) {
                ArrangementView {
                    MapArrangementPanel { isTiled in
                        sheetPanel(proxy: proxy, isTiled: isTiled)
                    }
                    .overlayArrangementEdge(HorizontalEdge.leading)
                    .overlayArrangementEdge(VerticalEdge.bottom)
                } secondary: {
                    mapPane
                }
                .arrangementViewStyle(.overlay)
            } else {
                ZStack(alignment: .bottomLeading) {
                    mapPane
                    sheetPanel(proxy: proxy, isTiled: false)
                }
            }
        }
        .background(palette.backgroundBase)
        .toolbar {
            if #available(iOS 27, *) {
                recenterToolbarItem.visibilityPriority(.high)
            } else {
                recenterToolbarItem
            }
        }
    }

    private var recenterToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Recenter map", systemImage: "location.fill", action: onRecenter)
        }
    }

    private var mapPane: some View {
        mapContent
            .ignoresSafeArea(.container)
            .overlay(alignment: .topLeading) {
                headerContent
                    .frame(maxWidth: 360, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .padding(12)
            }
    }

    // MARK: - Sheet

    private func sheetPanel(proxy: GeometryProxy, isTiled: Bool) -> some View {
        let isCollapsed = !isTiled && detent == .collapsed
        let isWide = proxy.size.width >= 650
        let panelWidth = isWide ? min(400, proxy.size.width * 0.48) : CGFloat.infinity

        return VStack(spacing: 0) {
            if isTiled {
                sheetHeading
                    .padding(.top, 16)
            } else {
                gripHandle
                    .contentShape(Rectangle())
                    .simultaneousGesture(dragGesture(in: proxy))
            }

            ZStack {
                // Keep section expansion and scroll state alive while the peek
                // replaces the visible list.
                ScrollViewReader { reader in
                    sheetScrollView
                    .task(id: presentation.revealID) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        dragTranslation = 0
                        isDragging = false
                        let target = presentation.focusedStopID.map { "stop:\($0)" } ?? "map-sheet-top"
                        withAnimation(sheetAnimation) {
                            reader.scrollTo(target, anchor: .top)
                        }
                    }
                }
                .opacity(isCollapsed ? 0 : 1)
                .allowsHitTesting(!isCollapsed)
                .accessibilityHidden(isCollapsed)

                if isCollapsed && collapsedTitle == nil {
                    ScrollView(showsIndicators: false) {
                        peekContent
                            .padding(.horizontal, 18)
                            .padding(.top, 2)
                            .padding(.bottom, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.height
                            } action: { height in
                                peekContentHeight = height
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: isTiled ? nil : height(in: proxy), alignment: .top)
        .frame(maxHeight: isTiled ? .infinity : nil, alignment: .top)
        .background {
            if isTiled {
                RoundedRectangle(cornerRadius: 30)
                    .fill(palette.screenBackground)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .padding(8)
        .frame(maxWidth: isTiled ? .infinity : panelWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .animation(isTiled ? nil : sheetAnimation, value: detent)
        .transaction { transaction in
            if isDragging { transaction.animation = nil }
        }
    }

    @ViewBuilder
    private var sheetScrollView: some View {
        let scrollView = ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                sheetContent
            }
            .id("map-sheet-top")
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollDismissesKeyboard(.interactively)

        if let onRefresh {
            scrollView.refreshable { await onRefresh() }
        } else {
            scrollView
        }
    }

    private var gripHandle: some View {
        let isCollapsed = detent == .collapsed
        let showsDepartures = collapsedTitle == nil
        let expandTitle = collapsedTitle ?? "Show departures"
        let sheetLabel = showsDepartures ? "Departure sheet" : title
        let expandHint = showsDepartures ? "Expands the departure list." : "Expands the planner."
        let collapseHint = showsDepartures ? "Shows just the next departure." : "Collapses the planner."

        return VStack(spacing: 10) {
            Button {
                if !isCollapsed {
                    setDetent(.collapsed)
                } else if showsDepartures {
                    presentation.showDepartures(at: departureListFocusID)
                } else {
                    setDetent(.medium)
                }
            } label: {
                Group {
                    if isCollapsed {
                        HStack(spacing: 8) {
                            Text(expandTitle)
                                .lineLimit(1)
                            Image(systemName: "chevron.up")
                        }
                        .font(.transitLabel)
                        .foregroundStyle(palette.accentText)
                        .padding(.horizontal, 18)
                    } else {
                        Capsule()
                            .fill(palette.textTertiary.opacity(0.5))
                            .frame(width: 40, height: 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? expandTitle : sheetLabel)
            .accessibilityValue(isCollapsed && !showsDepartures ? "Collapsed" : detent.accessibilityDescription)
            .accessibilityHint(isCollapsed ? expandHint : collapseHint)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    setDetent(detent == .collapsed ? .medium : .expanded)
                case .decrement:
                    setDetent(detent == .expanded ? .medium : .collapsed)
                @unknown default:
                    break
                }
            }

            if !isCollapsed {
                sheetHeading
            }
        }
    }

    private var sheetHeading: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    headingTitle.fixedSize()
                    Spacer(minLength: 8)
                    headingSummary.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    headingTitle
                    headingSummary
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)

            Divider()
                .padding(.horizontal, 18)
        }
    }

    private var headingTitle: some View {
        Text(title)
            .font(.transitHeadline)
            .foregroundStyle(palette.accentText)
            .accessibilityAddTraits(.isHeader)
    }

    private var headingSummary: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if let summary {
                Text(summary)
                    .font(.transitBadge)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(palette.surfaceRaised.opacity(0.8), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var peekContent: some View {
        if let peekDeparture {
            MapPeekDepartureRow(item: peekDeparture) {
                presentation.showDepartures(at: departureListFocusID)
            }
        } else {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                }
                Text(isLoading ? "Loading next departure…" : "No upcoming departures in view")
                    .font(.transitBody)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 44)
        }
    }

    // MARK: - Detents

    private func height(in proxy: GeometryProxy) -> CGFloat {
        let heights = detentHeights(in: proxy)
        let base = heights[detent] ?? heights[.medium] ?? 360
        let adjusted = base - dragTranslation
        return min(
            max(adjusted, heights[.collapsed] ?? adjusted),
            heights[.expanded] ?? adjusted
        )
    }

    private func detentHeights(in proxy: GeometryProxy) -> [MapSheetPresentation.Detent: CGFloat] {
        let availableHeight = max(0, proxy.size.height - 20)
        let expanded = min(availableHeight, proxy.size.height * 0.88)
        let maximumPeekHeight = min(expanded, max(88, expanded * 0.65))
        let collapsed = collapsedTitle == nil
            ? min(max(88, peekContentHeight + 44), maximumPeekHeight)
            : min(expanded, 44)
        let mediumFraction = proxy.size.width >= 650 ? 0.68 : 0.5
        let medium = max(collapsed, min(proxy.size.height * mediumFraction, expanded))

        return [
            .collapsed: collapsed,
            .medium: medium,
            .expanded: expanded,
        ]
    }

    private func dragGesture(in proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                let heights = detentHeights(in: proxy)
                let base = heights[detent] ?? heights[.medium] ?? 360
                let projected = min(
                    max(base - value.predictedEndTranslation.height, heights[.collapsed] ?? base),
                    heights[.expanded] ?? base
                )

                let nearest = MapSheetPresentation.Detent.allCases.min {
                    abs((heights[$0] ?? projected) - projected) <
                    abs((heights[$1] ?? projected) - projected)
                }

                if let nearest {
                    withAnimation(sheetAnimation) {
                        presentation.detent = nearest
                        dragTranslation = 0
                        isDragging = false
                    }
                } else {
                    dragTranslation = 0
                    isDragging = false
                }
            }
    }

    private var sheetAnimation: Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.34, dampingFraction: 0.86)
    }

    private func setDetent(_ newDetent: MapSheetPresentation.Detent) {
        withAnimation(sheetAnimation) {
            presentation.detent = newDetent
            dragTranslation = 0
        }
    }
}

@available(iOS 27.1, *)
private struct MapArrangementPanel<Content: View>: View {
    @Environment(\.overlayArrangementZIndex) private var overlayZIndex
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(overlayZIndex == 0)
    }
}

func formattedStopDistance(_ meters: Int) -> String {
    if meters < 1_000 {
        return "\(meters.formatted()) m away"
    }
    let kilometers = (Double(meters) / 1_000).formatted(.number.precision(.fractionLength(1)))
    return "\(kilometers) km away"
}

/// Status/progress row shown inside a map sheet.
struct MapInfoBanner: View {
    let title: String
    let detail: String?
    let icon: String

    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(palette.accentText)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.transitLabel)
                    .foregroundStyle(palette.textPrimary)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.transitCaption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            palette.surfaceRaised.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}
