import MapKit
import SwiftUI

/// The map-plus-draggable-sheet layout shared by the train, bus and tram
/// explorers.
///
/// Both explorers previously carried their own byte-identical copies of the
/// detent maths, drag gesture, sheet chrome, grip handle and floating control
/// buttons — about 400 lines duplicated. This owns all of it; callers supply
/// the map, the header pill's contents, and the sheet's contents.
///
/// The sheet is a custom container rather than a real `.sheet` with
/// `presentationDetents`, which would delete the drag maths entirely: a
/// presented sheet covers the tab bar, and all four tabs have to stay reachable.
struct MapSheetScaffold<MapContent: View, HeaderContent: View, SheetContent: View>: View {
    let title: String
    let summary: String
    let isLoading: Bool
    let onOpenSettings: () -> Void
    let onRecenter: () -> Void
    let onRefresh: () async -> Void
    let presentation: MapSheetPresentation
    var departureListFocusID: String? = nil
    var peekDeparture: MapPeekDeparture? = nil

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
            ZStack(alignment: .top) {
                mapContent
                    .ignoresSafeArea()

                headerOverlay(topInset: proxy.safeAreaInsets.top)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bottomSheet(proxy: proxy)
                        .frame(maxWidth: proxy.size.width >= 700 ? 480 : .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(palette.backgroundBase)
    }

    // MARK: - Header

    /// No `#available` gate anywhere in this file: the target's minimum
    /// deployment is iOS 26.4, so Liquid Glass is always present.
    private func headerOverlay(topInset: CGFloat) -> some View {
        // No GlassEffectContainer: the buttons carry their own glass via
        // `.buttonStyle(.glass)`, leaving the pill as the only `.glassEffect()`
        // surface here — and a container around one surface earns nothing while
        // adding a layer between the buttons and their touches.
        HStack(alignment: .top) {
            // Glass carries its own legibility over the map, so the two
            // full-screen scrim gradients the explorers used to draw are gone.
            headerContent
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))

            Spacer()

            VStack(spacing: 12) {
                controlButton(systemName: "gearshape.fill", action: onOpenSettings)
                controlButton(systemName: "location.fill", action: onRecenter)
            }
        }
        .padding(.top, max(topInset, 12))
        .padding(.horizontal, 18)
    }

    /// Uses `.buttonStyle(.glass)` rather than a plain button wrapped in
    /// `.glassEffect(.interactive())`.
    ///
    /// The latter puts an interactive glass layer *outside* the button, and
    /// that layer runs its own press handling — which competed with the
    /// button's and left the control ignoring taps after the first one.
    /// `.glass` is the supported way to make a button out of glass.
    private func controlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 52, height: 52)
                .contentShape(.circle)
        }
        .buttonStyle(.glass)
        .clipShape(.circle)
    }

    // MARK: - Sheet

    private func bottomSheet(proxy: GeometryProxy) -> some View {
        let safeBottom = max(proxy.safeAreaInsets.bottom, 12)

        return VStack(spacing: 0) {
            gripHandle
                .contentShape(Rectangle())
                .simultaneousGesture(dragGesture(in: proxy))

            ZStack {
                // Keep section expansion and scroll state alive while the peek
                // replaces the visible list.
                ScrollViewReader { reader in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            sheetContent
                        }
                        .id("map-sheet-top")
                        .padding(.horizontal, 10)
                        .padding(.bottom, safeBottom + 10)
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .refreshable { await onRefresh() }
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
                .opacity(detent == .collapsed ? 0 : 1)
                .allowsHitTesting(detent != .collapsed)
                .accessibilityHidden(detent == .collapsed)

                if detent == .collapsed {
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
        .frame(height: height(in: proxy), alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(sheetAnimation, value: detent)
        .transaction { transaction in
            if isDragging { transaction.animation = nil }
        }
    }

    private var gripHandle: some View {
        VStack(spacing: 10) {
            Button {
                if detent == .collapsed { presentation.showDepartures(at: departureListFocusID) }
                else { setDetent(.collapsed) }
            } label: {
                Group {
                    if detent == .collapsed {
                        HStack(spacing: 8) {
                            Text("Show departures")
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
            .accessibilityLabel(detent == .collapsed ? "Show departures" : "Departure sheet")
            .accessibilityValue(detent.accessibilityDescription)
            .accessibilityHint(detent == .collapsed ? "Expands the departure list." : "Shows just the next departure.")
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

            if detent != .collapsed {
                sheetHeading
            }
        }
    }

    private var sheetHeading: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.transitBody)
                    .foregroundStyle(palette.accentText)

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                Text(summary)
                    .font(.transitBadge)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(palette.surfaceRaised.opacity(0.8), in: Capsule())
            }
            .padding(.horizontal, 18)

            Divider()
                .padding(.horizontal, 18)
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
        let safeTop = max(proxy.safeAreaInsets.top, 12)
        let availableHeight = max(0, proxy.size.height - safeTop - 18)
        let expanded = min(availableHeight, proxy.size.height * 0.88)
        let maximumPeekHeight = min(expanded, max(88, expanded * 0.65))
        let collapsed = min(max(88, peekContentHeight + 44), maximumPeekHeight)
        let medium = min(max(collapsed, max(360, proxy.size.height * 0.47)), expanded)

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
