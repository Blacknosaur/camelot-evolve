import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Form sheet that creates or edits a squad player. Nothing is written until Save.
struct SquadPlayerEditor: View {
    let target: SquadEditorTarget
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SquadPlayer.name) private var players: [SquadPlayer]

    @State private var playerID = UUID()
    @State private var name = ""
    @State private var numberText = ""
    @State private var position: SquadPosition = .midfielder
    @State private var role = ""
    @State private var team = ""
    @State private var foot: SquadFoot?
    @State private var birthYearText = ""
    @State private var heightText = ""
    @State private var colorHex: String?
    @State private var notes = ""
    @State private var photoVersion = 0

    /// Processed JPEG waiting to be saved; `removesPhoto` deletes the stored one on save.
    @State private var pendingPhoto: Data?
    @State private var pendingPreview: CGImage?
    @State private var removesPhoto = false
    @State private var hasStoredPhoto = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingLibrary = false
    @State private var showingCamera = false
    @State private var isProcessingPhoto = false
    @State private var photoError: String?
    @State private var addingTeam = false
    @State private var saveError: String?
    /// Set once the record is stored: a second tap on Save must not insert the same id twice.
    @State private var didSave = false
    @State private var newTeamName = ""
    @State private var loaded = false

    private var isNew: Bool { if case .new = target { true } else { false } }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("squad-editor-name")
                    LabeledContent("Number") {
                        TextField("None", text: $numberText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .accessibilityIdentifier("squad-editor-number")
                    }
                    if let clash = numberClash {
                        Label("\(clash.name) already wears \(clash.number ?? 0) in \(team.isEmpty ? "this group" : team).", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("squad-editor-number-warning")
                    }
                    teamPicker
                }

                Section("Position") {
                    Picker("Position", selection: $position) {
                        ForEach(SquadPosition.allCases) { Text($0.shortTitle).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    LabeledContent("Role") {
                        TextField(position.suggestedRoles.first ?? "Role", text: $role)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    if position.suggestedRoles.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: Theme.Space.sm) {
                                ForEach(position.suggestedRoles, id: \.self) { suggestion in
                                    SquadFilterChip(title: suggestion, isOn: role == suggestion) { role = role == suggestion ? "" : suggestion }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                Section("Details") {
                    Picker("Preferred foot", selection: $foot) {
                        Text("Not set").tag(SquadFoot?.none)
                        ForEach(SquadFoot.allCases) { Text($0.title).tag(SquadFoot?.some($0)) }
                    }
                    LabeledContent("Birth year") {
                        TextField("Not set", text: $birthYearText).keyboardType(.numberPad).multilineTextAlignment(.trailing).monospacedDigit()
                    }
                    LabeledContent("Height") {
                        HStack(spacing: 4) {
                            TextField("Not set", text: $heightText).keyboardType(.numberPad).multilineTextAlignment(.trailing).monospacedDigit()
                            if !heightText.isEmpty { Text("cm").foregroundStyle(.secondary) }
                        }
                    }
                    kitColorRow
                }

                Section("Notes") {
                    TextField("Strengths, reminders…", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(isNew ? "New player" : "Edit player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty || isProcessingPhoto || didSave)
                        .accessibilityIdentifier("squad-editor-save")
                }
            }
            .photosPicker(isPresented: $showingLibrary, selection: $pickerItem, matching: .images)
            .fullScreenCover(isPresented: $showingCamera) {
                SquadCameraPicker { data in Task { await usePhoto(data) } }
                    .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    pickerItem = nil
                    if let data { await usePhoto(data) } else { photoError = "That photo could not be loaded." }
                }
            }
            .alert("New team", isPresented: $addingTeam) {
                TextField("Team name", text: $newTeamName)
                Button("Add") {
                    let trimmed = newTeamName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { team = trimmed }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("For example “U12” or “First team”.")
            }
            .alert("Photo", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(photoError ?? "")
            }
            .alert("Could not save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var photoSection: some View {
        Section {
            VStack(spacing: Theme.Space.md) {
                ZStack(alignment: .bottomTrailing) {
                    SquadAvatar(id: playerID, name: trimmedName.isEmpty ? "?" : trimmedName, photoVersion: photoVersion,
                                tint: kitTint, size: 116, override: pendingPreview, loadsStoredPhoto: !removesPhoto)
                        .overlay {
                            if isProcessingPhoto { ProgressView().controlSize(.large).frame(width: 116, height: 116).background(.ultraThinMaterial, in: .circle) }
                        }
                    Menu {
                        photoMenu
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Theme.brand, in: .circle)
                            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 3))
                            // A full target around the badge, which also lifts it off the avatar's edge.
                            .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Photo options")
                    .accessibilityIdentifier("squad-editor-photo")
                }
                Menu { photoMenu } label: {
                    Text(showsPhoto ? "Change photo" : "Add photo").font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.sm)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var photoMenu: some View {
        Button("Choose from library", systemImage: "photo.on.rectangle") { showingLibrary = true }
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button("Take photo", systemImage: "camera") { showingCamera = true }
        }
        if showsPhoto {
            Button("Remove photo", systemImage: "trash", role: .destructive) {
                pendingPhoto = nil; pendingPreview = nil; removesPhoto = true
            }
        }
    }

    private var teamPicker: some View {
        Picker("Team", selection: Binding(get: { team }, set: { value in
            if value == Self.newTeamTag { newTeamName = ""; addingTeam = true } else { team = value }
        })) {
            Text("None").tag("")
            ForEach(teamOptions, id: \.self) { Text($0).tag($0) }
            Divider()
            Text("New team…").tag(Self.newTeamTag)
        }
        .accessibilityIdentifier("squad-editor-team")
    }

    private static let newTeamTag = "\u{0}new-team"

    private var kitColorRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Kit colour")
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.sm) {
                    swatch(nil)
                    ForEach(BoardPalette.swatches, id: \.self) { swatch($0) }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            Text("Used for this player on boards. Automatic uses the board's team colour.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func swatch(_ hex: String?) -> some View {
        let isOn = colorHex == hex
        return Button { colorHex = hex } label: {
            ZStack {
                if let hex {
                    Circle().fill(BoardPalette.color(hex))
                } else {
                    Circle().fill(.fill.tertiary)
                    Text("A").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
            .padding(3)
            .overlay(Circle().strokeBorder(isOn ? Theme.brand : .clear, lineWidth: 2))
            .frame(minWidth: Theme.tapTarget, minHeight: Theme.tapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex == nil ? "Automatic colour" : "Colour \(hex!)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: State

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var number: Int? { Int(numberText.trimmingCharacters(in: .whitespaces)) }
    private var showsPhoto: Bool { pendingPreview != nil || (hasStoredPhoto && !removesPhoto) }
    private var kitTint: Color {
        if let colorHex { return BoardPalette.color(colorHex) }
        return SquadPlayer(name: "", position: position).kitColor
    }

    private var teamOptions: [String] {
        var names = Set(players.map(\.team).filter { !$0.isEmpty })
        if !team.isEmpty { names.insert(team) }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var numberClash: SquadPlayer? {
        guard let number else { return nil }
        return players.first { $0.id != playerID && $0.team == team && $0.number == number }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new(let team):
            self.team = team ?? ""
        case .edit(let player):
            playerID = player.id
            name = player.name
            numberText = player.number.map(String.init) ?? ""
            position = player.squadPosition
            role = player.role
            team = player.team
            foot = player.foot
            birthYearText = player.birthYear.map(String.init) ?? ""
            heightText = player.heightCm.map(String.init) ?? ""
            colorHex = player.colorHex
            notes = player.notes
            photoVersion = player.photoVersion
            let id = player.id
            Task { hasStoredPhoto = await Task.detached { SquadPhotoStore.hasPhoto(for: id) }.value }
        }
    }

    private func usePhoto(_ data: Data) async {
        isProcessingPhoto = true
        defer { isProcessingPhoto = false }
        do {
            let (jpeg, preview) = try await Task.detached(priority: .userInitiated) {
                let jpeg = try SquadPhotoStore.squareJPEG(from: data)
                return (jpeg, SquadPhotoStore.decodeJPEG(jpeg))
            }.value
            pendingPhoto = jpeg
            pendingPreview = preview
            removesPhoto = false
        } catch {
            photoError = "That image could not be read. Try a different photo."
        }
    }

    /// Stores the record first and only then touches the photo file, so a failed save never leaves
    /// an orphan JPEG on disk, and the sheet stays open with the reason.
    private func save() {
        guard !didSave else { return }
        let player: SquadPlayer
        switch target {
        case .new:
            player = SquadPlayer(id: playerID, name: trimmedName)
            modelContext.insert(player)
        case .edit(let existing):
            player = existing
        }
        let previousVersion = player.photoVersion
        player.name = trimmedName
        player.number = number
        player.squadPosition = position
        player.role = role.trimmingCharacters(in: .whitespaces)
        player.team = team.trimmingCharacters(in: .whitespaces)
        player.foot = foot
        player.birthYear = Int(birthYearText.trimmingCharacters(in: .whitespaces))
        player.heightCm = Int(heightText.trimmingCharacters(in: .whitespaces))
        player.colorHex = colorHex
        player.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingPhoto != nil || removesPhoto { player.photoVersion += 1 }
        player.updatedAt = .now
        do {
            try modelContext.save()
        } catch {
            if case .new = target { modelContext.delete(player) }
            player.photoVersion = previousVersion
            saveError = error.localizedDescription
            return
        }
        didSave = true
        if let pendingPhoto {
            do {
                try SquadPhotoStore.store(pendingPhoto, for: player.id)
            } catch {
                player.photoVersion = previousVersion
                try? modelContext.save()
                didSave = false
                saveError = "The player was saved, but the photo could not be stored."
                return
            }
        } else if removesPhoto {
            SquadPhotoStore.delete(for: player.id)
        }
        dismiss()
    }
}

/// Camera capture through `UIImagePickerController`, returning JPEG data.
struct SquadCameraPicker: UIViewControllerRepresentable {
    let onPick: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SquadCameraPicker
        init(parent: SquadCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) { parent.onPick(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
