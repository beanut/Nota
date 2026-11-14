import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The Pen Case's Insert menu (the photo icon, after the tools): pictures from Photos, the camera or Files,
/// pictures copied in another app, and the sticker collection. Whatever it inserts lands in the middle of
/// the visible part of the page, selected with the lasso.
struct InsertMenu: View {
    @ObservedObject var controller: CanvasController
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var showStickers = false

    /// The camera is there on an iPad, never in the simulator.
    private var hasCamera: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        Menu {
            Button { showPhotos = true } label: {
                Label("Photos…", systemImage: "photo.on.rectangle")
            }
            Button { showCamera = true } label: {
                Label("Take Photo…", systemImage: "camera")
            }
            .disabled(!hasCamera)
            Button { showFiles = true } label: {
                Label("Files…", systemImage: "folder")
            }
            Button { controller.pasteImages() } label: {
                Label("Paste Image", systemImage: "doc.on.clipboard")
            }
            .disabled(!controller.canPasteImages)
            Divider()
            Button { showStickers = true } label: {
                Label("Stickers…", systemImage: "star.square.on.square")
            }
        } label: {
            InkIconView(.photo)
        }
        .menuStyle(.button)
        .buttonStyle(.inkIcon(selected: showStickers))
        .accessibilityLabel("Insert")
        .accessibilityHint("Adds a photo, an image file or a sticker to the page.")
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { @MainActor in
                var images: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        images.append(data)
                    }
                }
                controller.insertImages(images)
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            let images = urls.compactMap { url -> Data? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return try? Data(contentsOf: url)
            }
            controller.insertImages(images)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image {
                    controller.insertImage(image)
                }
            }
            .ignoresSafeArea()
        }
        .popover(isPresented: $showStickers, arrowEdge: .top) {
            StickerPicker(controller: controller, stickers: controller.stickers) { showStickers = false }
        }
    }
}

/// The camera, for Take Photo. Calls `onFinish` with the photo, or nil if it was cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

/// The sticker collection: tap a sticker to place it on the page; touch and hold to rename or delete it.
/// Stickers are made from the lasso selection's Save as Sticker.
struct StickerPicker: View {
    @ObservedObject var controller: CanvasController
    @ObservedObject var stickers: StickerStore
    let dismiss: () -> Void
    @State private var renaming: Sticker?
    @State private var draftName = ""
    @Environment(\.inkTheme) private var theme

    private static let tile = InkMetrics.stickerTile

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpacing.m) {
            Text("Stickers")
                .font(theme.headlineFont)
                .foregroundStyle(theme.color(\.textPrimary))
                .padding(.top, InkSpacing.s)
            if stickers.stickers.isEmpty {
                Text("Select ink or pictures with the lasso and choose Save as Sticker to use them again on any page.")
                    .font(theme.footnoteFont)
                    .foregroundStyle(theme.color(\.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tile), spacing: InkSpacing.s), count: 3),
                              spacing: InkSpacing.s) {
                        ForEach(stickers.stickers) { sticker in
                            tile(sticker)
                        }
                    }
                }
                .frame(maxHeight: InkMetrics.stickerGridHeight)
            }
        }
        .padding(.horizontal, InkSpacing.l)
        .padding(.bottom, InkSpacing.l)
        .frame(width: 3 * Self.tile + 2 * InkSpacing.s + 2 * InkSpacing.l)
        .inkPopoverContent()
        .alert("Rename Sticker", isPresented: Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming {
                    stickers.rename(renaming.id, to: draftName)
                }
                renaming = nil
            }
        }
    }

    private func tile(_ sticker: Sticker) -> some View {
        Button {
            controller.insertSticker(sticker)
            dismiss()
        } label: {
            VStack(spacing: InkSpacing.xxs) {
                Group {
                    if let image = UIImage(data: sticker.preview) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .padding(InkSpacing.s)
                .frame(width: Self.tile, height: Self.tile)
                .background(theme.color(\.paper), in: RoundedRectangle(cornerRadius: InkMetrics.paperRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: InkMetrics.paperRadius, style: .continuous)
                    .strokeBorder(theme.color(\.border)))
                Text(sticker.name)
                    .font(theme.footnoteFont)
                    .foregroundStyle(theme.color(\.textSecondary))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sticker.name)
        .accessibilityHint("Places the sticker on the page.")
        .contextMenu {
            Button {
                draftName = sticker.name
                renaming = sticker
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive) { stickers.delete(sticker.id) } label: {
                Label("Delete Sticker", systemImage: "trash")
            }
        }
    }
}

/// The floating bar over the page while a picture is cropped: Rectangle or Freehand, Reset, Cancel and Done.
struct ImageCropBar: View {
    @ObservedObject var controller: CanvasController
    let state: ImageCropState
    @Environment(\.inkTheme) private var theme

    var body: some View {
        HStack(spacing: InkSpacing.s) {
            Picker("Crop", selection: Binding(get: { state.mode }, set: { controller.setImageCropMode($0) })) {
                Text("Rectangle").tag(ImageCropMode.rectangle)
                Text("Freehand").tag(ImageCropMode.freehand)
            }
            .pickerStyle(.segmented)
            .frame(width: InkMetrics.cropModeWidth)
            Text(state.mode == .rectangle ? "Drag the corners and edges." : "Draw around what to keep.")
                .font(theme.footnoteFont)
                .foregroundStyle(theme.color(\.textSecondary))
                .lineLimit(1)
            InkBarDivider(axis: .horizontal)
            Button("Reset") { controller.resetImageCrop() }
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(state.isCropped ? \.textPrimary : \.textTertiary))
                .disabled(!state.isCropped)
            Button("Cancel") { controller.finishImageCrop(commit: false) }
                .font(theme.bodyFont)
                .foregroundStyle(theme.color(\.textPrimary))
            Button("Done") { controller.finishImageCrop(commit: true) }
                .font(theme.bodyEmphasizedFont)
                .foregroundStyle(theme.color(\.textSelected))
                .accessibilityHint("Keeps the crop.")
        }
        .padding(.horizontal, InkSpacing.m)
        .frame(height: InkMetrics.barHeight)
        .inkFloatingBar()
    }
}
