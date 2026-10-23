import SwiftUI
import UIKit
import CoreImage

/// The photo editor for one photo from the device's library.
///
/// Three tools, each of which really works:
///
/// * **Crop** — aspect presets (plus the original framing), with a
///   drag to reposition the crop inside the photo.
/// * **Rotate** — quarter turns, left and right.
/// * **Adjust** — brightness, contrast and saturation, rendered
///   through `CIColorControls`.
///
/// Saving writes a **new** photo to the library
/// (`PhotoKitService.saveEditedImage`); the original is never modified.
/// The Photos change observer then refreshes the gallery, so the edited
/// copy appears next to the original on its own.
///
/// Photos only: the viewer does not offer this screen for a video, and
/// says so instead of presenting tools that cannot work.
struct PhotoKitPhotoEditorView: View {
    let asset: PhotoKitAsset

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The tool panel currently shown under the preview.
    private enum Mode: String, CaseIterable, Identifiable {
        case crop = "Crop"
        case rotate = "Rotate"
        case adjust = "Adjust"
        var id: String { rawValue }
    }

    @State private var source: UIImage?
    @State private var preview: UIImage?
    @State private var loadFailed = false

    @State private var mode: Mode = .crop
    /// Clockwise quarter turns applied to the photo.
    @State private var rotationSteps = 0
    @State private var aspect: PhotoCropAspect = .original
    /// Crop window shift from centre, as a fraction of the slack on
    /// each axis, in -0.5...0.5. Zero is a centre crop.
    @State private var cropShift = CGSize.zero
    @State private var dragStartShift: CGSize?

    @State private var brightness = 0.0
    @State private var contrast = 1.0
    @State private var saturation = 1.0

    @State private var isSaving = false
    @State private var alertMessage: String?
    @State private var dismissAfterAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .navigationTitle("Edit Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.accentColor)
                    .disabled(source == nil || isSaving)
                }
            }
            .task { await load() }
            .task(id: settingsKey) { renderPreview() }
            .alert("Edit Photo", isPresented: alertBinding) {
                Button("OK") {
                    if dismissAfterAlert { dismiss() }
                }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loadFailed {
            ContentUnavailableView(
                "Couldn't Load Photo",
                systemImage: "photo.badge.exclamationmark",
                description: Text("This photo couldn't be loaded for editing. It may still be downloading from iCloud.")
            )
            .foregroundStyle(.white)
        } else if source == nil {
            ProgressView("Loading…")
                .foregroundStyle(.white)
        } else {
            VStack(spacing: 0) {
                previewArea
                modePicker
                controls
            }
        }
    }

    private var previewArea: some View {
        GeometryReader { geo in
            ZStack {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .gesture(cropDragGesture(in: geo.size))
                        .onTapGesture(count: 2) {
                            cropShift = .zero
                        }
                } else {
                    ProgressView()
                        .foregroundStyle(.white)
                }
                if isSaving {
                    ProgressView("Saving…")
                        .padding(12)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modePicker: some View {
        Picker("Tool", selection: $mode) {
            ForEach(Mode.allCases) { tool in
                Text(tool.rawValue).tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 12) {
            switch mode {
            case .crop:
                cropControls
            case .rotate:
                rotateControls
            case .adjust:
                adjustControls
            }

            if hasEdits {
                Button("Reset All Edits", role: .destructive) {
                    resetAll()
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
    }

    private var cropControls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PhotoCropAspect.allCases) { option in
                        Button(option.label) {
                            aspect = option
                            cropShift = .zero
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            aspect == option ? Design.accentColor : Color(white: 0.2),
                            in: Capsule()
                        )
                        .foregroundStyle(aspect == option ? Color.black : Color.white)
                    }
                }
            }
            Text(aspect == .original
                 ? "The original framing is kept."
                 : "Drag the photo to reposition the crop. Double-tap to centre it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var rotateControls: some View {
        HStack(spacing: 16) {
            Button {
                rotationSteps = (rotationSteps + 3) % 4
                cropShift = .zero
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            Button {
                rotationSteps = (rotationSteps + 1) % 4
                cropShift = .zero
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .foregroundStyle(.white)
    }

    private var adjustControls: some View {
        VStack(spacing: 10) {
            sliderRow("Brightness", value: $brightness, range: -0.4...0.4)
            sliderRow("Contrast", value: $contrast, range: 0.6...1.4)
            sliderRow("Saturation", value: $saturation, range: 0...2)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
                .tint(Design.accentColor)
        }
    }

    // MARK: - Gestures

    /// Dragging moves the *photo* under the crop window, the way the
    /// system editor behaves: the shift stored is the crop's, so the
    /// drag delta is subtracted.
    private func cropDragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard aspect != .original else { return }
                if dragStartShift == nil { dragStartShift = cropShift }
                let start = dragStartShift ?? .zero
                let dx = value.translation.width / max(size.width, 1)
                let dy = value.translation.height / max(size.height, 1)
                cropShift = CGSize(
                    width: min(max(start.width - dx, -0.5), 0.5),
                    height: min(max(start.height - dy, -0.5), 0.5)
                )
            }
            .onEnded { _ in
                dragStartShift = nil
            }
    }

    // MARK: - State

    private var hasEdits: Bool {
        rotationSteps != 0
            || aspect != .original
            || brightness != 0
            || contrast != 1
            || saturation != 1
    }

    private func resetAll() {
        rotationSteps = 0
        aspect = .original
        cropShift = .zero
        brightness = 0
        contrast = 1
        saturation = 1
    }

    /// Everything the preview depends on, as one key: the preview task
    /// re-runs (and the previous one is cancelled) whenever an edit
    /// changes, so a slider drag renders the latest values, not a queue
    /// of stale ones.
    private var settingsKey: String {
        [
            "\(rotationSteps)",
            aspect.rawValue,
            "\(Int(cropShift.width * 200))",
            "\(Int(cropShift.height * 200))",
            "\(Int(brightness * 100))",
            "\(Int(contrast * 100))",
            "\(Int(saturation * 100))",
            source == nil ? "none" : "loaded",
        ].joined(separator: "|")
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { presented in
                if !presented { alertMessage = nil }
            }
        )
    }

    // MARK: - Load, render, save

    private func load() async {
        guard source == nil else { return }
        if let image = await store.photoKit.fullImage(for: asset.id, maxPixelSize: 4096) {
            source = image
        } else {
            loadFailed = true
        }
    }

    private func renderPreview() {
        guard let source else { return }
        preview = Self.render(
            source: source,
            rotationSteps: rotationSteps,
            aspect: aspect,
            shift: cropShift,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            maxDimension: 1000
        )
    }

    private func save() async {
        guard let source, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        guard let rendered = Self.render(
            source: source,
            rotationSteps: rotationSteps,
            aspect: aspect,
            shift: cropShift,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            maxDimension: 4096
        ) else {
            alertMessage = "The edited photo couldn't be rendered."
            return
        }
        let saved = await store.photoKit.saveEditedImage(rendered)
        if saved {
            dismissAfterAlert = true
            alertMessage = "Saved as a new photo in your library. The original was not changed."
        } else {
            alertMessage = "The edited photo couldn't be saved. Check that Pixel Pic is still allowed to add photos, in Settings → Privacy → Photos."
        }
    }

    // MARK: - Rendering

    /// The edit pipeline, as one pure function of the source image and
    /// the edit settings: downscale to the working size, normalise the
    /// orientation, rotate, crop, then colour-adjust. The preview and
    /// the save run the *same* pipeline at different working sizes, so
    /// what the user sees is what gets saved.
    static func render(
        source: UIImage,
        rotationSteps: Int,
        aspect: PhotoCropAspect,
        shift: CGSize,
        brightness: Double,
        contrast: Double,
        saturation: Double,
        maxDimension: CGFloat
    ) -> UIImage? {
        var image = downscaled(source, maxDimension: maxDimension)
        image = upright(image)
        let turns = ((rotationSteps % 4) + 4) % 4
        if turns != 0 {
            image = rotated(image, clockwiseTurns: turns)
        }
        image = cropped(image, aspect: aspect, shift: shift)
        if brightness != 0 || contrast != 1 || saturation != 1 {
            if let adjusted = colorAdjusted(
                image,
                brightness: brightness,
                contrast: contrast,
                saturation: saturation
            ) {
                image = adjusted
            }
        }
        return image
    }

    /// Scale down so the longest side is at most `maxDimension`.
    /// Anything already smaller is returned untouched.
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let factor = maxDimension / longest
        let size = CGSize(
            width: (image.size.width * factor).rounded(),
            height: (image.size.height * factor).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Bake the EXIF orientation into the pixels, so every later step
    /// can work in plain `.up` space.
    private static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Rotate by whole quarter turns, clockwise.
    private static func rotated(_ image: UIImage, clockwiseTurns: Int) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let swapsAxes = clockwiseTurns % 2 == 1
        let size = swapsAxes
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            cgContext.rotate(by: CGFloat(clockwiseTurns) * .pi / 2)
            image.draw(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        }
    }

    /// Crop to the chosen aspect, positioned by `shift` (a fraction of
    /// the slack on each axis, -0.5...0.5 around centre). The original
    /// aspect — and a crop that would not change anything — returns the
    /// image untouched.
    private static func cropped(_ image: UIImage, aspect: PhotoCropAspect, shift: CGSize) -> UIImage {
        guard let cg = image.cgImage,
              let ratio = aspect.ratio else { return image }
        let fullWidth = CGFloat(cg.width)
        let fullHeight = CGFloat(cg.height)
        guard fullWidth > 0, fullHeight > 0 else { return image }

        var cropWidth = fullWidth
        var cropHeight = fullHeight
        if fullWidth / fullHeight > ratio {
            cropWidth = fullHeight * ratio
        } else {
            cropHeight = fullWidth / ratio
        }
        let slackX = fullWidth - cropWidth
        let slackY = fullHeight - cropHeight
        guard slackX > 1 || slackY > 1 else { return image }

        let clampedX = min(max(shift.width, -0.5), 0.5)
        let clampedY = min(max(shift.height, -0.5), 0.5)
        let rect = CGRect(
            x: (slackX * (0.5 + clampedX)).rounded(),
            y: (slackY * (0.5 + clampedY)).rounded(),
            width: cropWidth.rounded(),
            height: cropHeight.rounded()
        )
        guard let croppedCG = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: croppedCG, scale: 1, orientation: .up)
    }

    /// Brightness / contrast / saturation through `CIColorControls`.
    private static func colorAdjusted(
        _ image: UIImage,
        brightness: Double,
        contrast: Double,
        saturation: Double
    ) -> UIImage? {
        guard let cg = image.cgImage,
              let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: brightness), forKey: kCIInputBrightnessKey)
        filter.setValue(NSNumber(value: contrast), forKey: kCIInputContrastKey)
        filter.setValue(NSNumber(value: saturation), forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let rendered = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }
}

/// A crop aspect preset. `original` keeps the photo's own framing.
enum PhotoCropAspect: String, CaseIterable, Identifiable {
    case original
    case square
    case fourThree
    case threeFour
    case threeTwo
    case twoThree
    case sixteenNine
    case nineSixteen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .threeTwo: return "3:2"
        case .twoThree: return "2:3"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    /// Width / height of the crop, or `nil` for no crop.
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .threeTwo: return 3.0 / 2.0
        case .twoThree: return 2.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}
