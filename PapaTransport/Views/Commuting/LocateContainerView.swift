import SwiftUI

enum LocateMode: String, CaseIterable, Identifiable {
    case train
    case bus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .train: return "Train"
        case .bus: return "Bus"
        }
    }
}

/// Container for the Locate tab that lets the user switch between Train and Bus
/// locate modes. Bus locate is currently Victoria-only; for Queensland the
/// segmented control is hidden and Train locate is shown directly.
struct LocateContainerView: View {
    let transportRegion: TransportRegion

    @AppStorage("locateMode") private var locateModeRaw = LocateMode.train.rawValue

    private var locateMode: LocateMode {
        LocateMode(rawValue: locateModeRaw) ?? .train
    }

    private var modeBinding: Binding<LocateMode> {
        Binding(
            get: { locateMode },
            set: { locateModeRaw = $0.rawValue }
        )
    }

    private var showsModePicker: Bool {
        transportRegion == .victorian
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsModePicker {
                Picker("Locate Mode", selection: modeBinding) {
                    ForEach(LocateMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            if !showsModePicker || locateMode == .train {
                TrainLocateMeView()
            } else {
                BusLocateMeView()
            }
        }
    }
}
