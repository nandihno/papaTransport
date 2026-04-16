//
//  PapaTransportApp.swift
//  PapaTransport
//
//  Created by Fernando De Leon on 14/4/2026.
//

import SwiftUI

@main
struct PapaTransportApp: App {
    @StateObject private var favouriteBusStopStore = FavouriteBusStopStore.shared
    private var drivingDestinationStore: DrivingDestinationStore { DrivingDestinationStore.shared }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favouriteBusStopStore)
                .environment(drivingDestinationStore)
        }
    }
}
