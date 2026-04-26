//
//  PapaTransportApp.swift
//  PapaTransport
//
//  Created by Fernando De Leon on 14/4/2026.
//

import SwiftUI
import UIKit

final class PapaTransportAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        TrainStatusNotificationService.shared.configure()
        return true
    }
}

@main
struct PapaTransportApp: App {
    @UIApplicationDelegateAdaptor(PapaTransportAppDelegate.self) private var appDelegate
    @StateObject private var favouriteBusStopStore = FavouriteBusStopStore.shared
    @Environment(\.scenePhase) private var scenePhase
    private var drivingDestinationStore: DrivingDestinationStore { DrivingDestinationStore.shared }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favouriteBusStopStore)
                .environment(drivingDestinationStore)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                TrainStatusNotificationService.shared.applicationDidEnterBackground()
            }
        }
    }
}
