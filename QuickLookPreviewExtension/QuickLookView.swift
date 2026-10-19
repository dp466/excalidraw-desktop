//
//  QuickLookView.swift
//  QuickLookPreviewExtension
//
//  Created by Dove Zachary on 2024/10/8.
//

import SwiftUI
import WebKit
import Combine

import SwiftyAlert

struct QuickLookView: View {
    @Environment(\.alertToast) var alertToast

    @ObservedObject var state: PreviewState
    var file: ExcalidrawFile? { state.file }
    var error: Error? { state.error }
    
    var body: some View {
        ZStack {
            if let file {
                ExcalidrawRenderer(file: file)
            } else if let error {
                // A file that cannot be parsed must not leave Quick Look spinning.
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                Color.clear
                    .overlay {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
