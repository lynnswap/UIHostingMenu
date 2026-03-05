//
//  ContentView.swift
//  MiniApp
//
//  Created by Kazuki Nakashima on 2026/03/05.
//

import SwiftUI
import UIHostingMenu

struct ContentView: View {
    var body: some View {
        UIHostingMenuDemoView()
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
