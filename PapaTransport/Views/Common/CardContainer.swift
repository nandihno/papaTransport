//
//  CardContainer.swift
//  myLatest
//

import SwiftUI

// MARK: - Card Container

struct CardContainer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .transitCardStyle()
    }
}
