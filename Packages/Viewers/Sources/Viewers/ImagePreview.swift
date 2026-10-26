import Localization
import SwiftUI

/// The image scaled down to fit, never up, with its pixel size. The image arrives decoded.
struct ImagePreview: View {
    let image: PreviewImage

    var body: some View {
        VStack(spacing: 6) {
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: CGFloat(image.cgImage.width), maxHeight: CGFloat(image.cgImage.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(
                image.dimensionsDescription()
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}
