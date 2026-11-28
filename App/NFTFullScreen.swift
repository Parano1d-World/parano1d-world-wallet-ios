import SwiftUI
import CoreImage
import Photos

/// Full-screen NFT artwork with zoom. An owner can save it to Photos, save a
/// lock-screen-sized wallpaper version, or share it. iOS only lets the person set a
/// wallpaper themselves (Photos → Share → Use as Wallpaper); apps cannot set it.
struct NFTFullScreenView: View {
    let item: NativeItem
    let canSave: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var status: String?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var saving = false
    private var title: String { item.text("serial").isEmpty ? "NFT" : "NFT #" + item.text("serial") }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnificationGesture()
                        .onChanged { scale = max(1, min(lastScale * $0, 5)) }
                        .onEnded { _ in lastScale = scale })
                    .onTapGesture(count: 2) { withAnimation(.snappy) { scale = scale > 1 ? 1 : 2.5; lastScale = scale } }
                    .accessibilityLabel(title)
                    .modifier(MacDragOut(image: canSave ? image : nil))
            } else if let failure {
                Text(failure).font(Theme.subheadline).foregroundStyle(.orange).multilineTextAlignment(.center).padding(30)
            } else {
                ProgressView("Loading full artwork").tint(Theme.mint).foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                    }.accessibilityLabel("Close")
                    Spacer()
                    if canSave, let image {
                        Menu {
                            Button("Save to Photos", systemImage: "square.and.arrow.down") { save(image) }
                            if !AppSidebar.enabled {
                                Button("Save as wallpaper", systemImage: "iphone") { save(NFTWallpaper.render(image)) }
                            }
                            ShareLink(item: Image(uiImage: image), preview: SharePreview(title, image: Image(uiImage: image))) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Image(systemName: saving ? "hourglass" : "square.and.arrow.down").font(.headline)
                                .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                        }.disabled(saving).accessibilityLabel("Save or share artwork")
                    }
                }.foregroundStyle(.white).padding(.horizontal, 16)
                Spacer()
                if let status {
                    Text(status).font(Theme.caption).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(20)
                }
            }
        }
        .statusBarHidden()
        .task {
            do { image = try await AssetMedia.shared.fullImage(hash: item.text("metadata_hash")) }
            catch { failure = error.localizedDescription }
        }
    }
    private func save(_ picture: UIImage) {
        saving = true; status = nil
        Task {
            defer { saving = false }
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else {
                status = "Allow Parano1d to add photos in Settings → Privacy & Security → Photos."; return
            }
            do {
                // Save lossless PNG at full resolution; the UIImage path re-compresses as JPEG.
                let data = picture.pngData()
                try await PHPhotoLibrary.shared().performChanges {
                    if let data { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil) }
                    else { PHAssetChangeRequest.creationRequestForAsset(from: picture) }
                }
                status = picture.size.height > picture.size.width
                    ? "Saved to Photos. To use it, open it in Photos → Share → Use as Wallpaper."
                    : "Saved to Photos."
            } catch { status = "Could not save: \(error.localizedDescription)" }
        }
    }
}

/// Places the NFT art, whole and uncropped, on a phone-shaped canvas (screen resolution, portrait).
/// The space around it is a heavily blurred, darkened wash of the art's own colours, so no
/// cut-off piece of the picture shows behind it, and the art sits clear of the lock-screen clock.
enum NFTWallpaper {
    @MainActor static func render(_ art: UIImage) -> UIImage {
        let screen = UIScreen.main
        let size = CGSize(width: screen.nativeBounds.width, height: screen.nativeBounds.height)
        let wash = backdrop(art, size: size)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
            if let wash { wash.draw(in: CGRect(origin: .zero, size: size)) }
            // Darken the wash so the art and the clock stand out.
            UIColor.black.withAlphaComponent(0.45).setFill(); context.fill(CGRect(origin: .zero, size: size))
            // Foreground: the whole picture, as wide as fits (at most 88% of the screen width and
            // 62% of its height), placed a little below centre under the clock.
            let scale = min(size.width * 0.88 / art.size.width, size.height * 0.62 / art.size.height)
            let width = art.size.width * scale, height = art.size.height * scale
            let rect = CGRect(x: (size.width - width) / 2, y: size.height * 0.57 - height / 2, width: width, height: height)
            context.cgContext.saveGState()
            context.cgContext.interpolationQuality = .high
            context.cgContext.setShadow(offset: .zero, blur: size.width * 0.04, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            // Lanczos resampling keeps edges and text sharp at the screen's full pixel size.
            (sharpScaled(art, to: CGSize(width: rect.width.rounded(), height: rect.height.rounded())) ?? art).draw(in: rect)
            context.cgContext.restoreGState()
        }
    }

    /// The art resampled with Lanczos to exactly the pixels it will cover (no further scaling when drawn).
    private static func sharpScaled(_ art: UIImage, to target: CGSize) -> UIImage? {
        guard let cg = art.cgImage, target.width > 0, cg.width > 0 else { return nil }
        let input = CIImage(cgImage: cg)
        let scale = target.height / CGFloat(cg.height)
        let filter = CIFilter(name: "CILanczosScaleTransform")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(scale, forKey: kCIInputScaleKey)
        filter?.setValue(target.width / (CGFloat(cg.width) * scale), forKey: kCIInputAspectRatioKey)
        guard let output = filter?.outputImage,
              let result = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: CGRect(origin: .zero, size: target)) else { return nil }
        return UIImage(cgImage: result, scale: 1, orientation: art.imageOrientation)
    }

    /// The art's colours, blurred until no shapes remain, stretched to the screen.
    private static func backdrop(_ art: UIImage, size: CGSize) -> UIImage? {
        // Work small: a 64-pixel-wide copy blurred hard is indistinguishable from a full-size blur.
        let small = CGSize(width: 64, height: 64 * size.height / size.width)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let fill = max(small.width / art.size.width, small.height / art.size.height)
        let drawn = UIGraphicsImageRenderer(size: small, format: format).image { _ in
            let w = art.size.width * fill, h = art.size.height * fill
            art.draw(in: CGRect(x: (small.width - w) / 2, y: (small.height - h) / 2, width: w, height: h))
        }
        guard let input = CIImage(image: drawn) else { return nil }
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: input.extent)
        guard let cg = CIContext(options: nil).createCGImage(blurred, from: input.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
