//
//  QRCodeView.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/11/26.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let url: String

    var body: some View {
        VStack(spacing: 30) {
            Text("Upload VPN Profile")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(Color(red: 0.13, green: 0.69, blue: 0.34))

            if let image = generateQRCode(from: url) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text("Scan this QR code with your phone\nor open the URL in a browser")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up the QR code (it's tiny by default)
        let scale = 10.0
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
