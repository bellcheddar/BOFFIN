//  StructureTabView.swift
//  BOFFIN
//
//  Phase 7: the structure viewer.
//
//  The demo the build plan calls the most compelling thing in the app is
//  painting a ResidueTrack onto the structure, so that is what the controls lead
//  with. Everything else here exists to make that possible: load a structure,
//  choose how it is drawn, and map BOFFIN's own analysis onto the residues a
//  crystallographer numbers.

import BoffinCharts
import BoffinCore
import BoffinStructure
import BoffinUI
import BoffinViewer
import SwiftUI

struct StructureTabView: View {
    @Bindable var store: SequenceStore
    @State private var model: StructureViewerModel?
    @State private var setupError: String?
    @State private var paintedTrack: TrackID?
    @State private var identifier: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if let setupError {
                    ContentUnavailableView(
                        "Viewer unavailable", systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else if let model {
                    viewer(model)
                } else {
                    ProgressView().task { start() }
                }
            }
            .navigationTitle("Structure")
        }
    }

    private func start() {
        do {
            model = try StructureViewerModel()
        } catch {
            setupError = String(describing: error)
        }
    }

    @ViewBuilder
    private func viewer(_ model: StructureViewerModel) -> some View {
        VStack(spacing: 0) {
            StructureViewerView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .accessibilityIdentifier("boffin.structure-viewer")

            controls(model)
                .padding(Spacing.s)
                .background(.bar)
        }
    }

    @ViewBuilder
    private func controls(_ model: StructureViewerModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                stateLabel(model.state)
                Spacer()
                Button {
                    Task { await loadFixture(into: model) }
                } label: {
                    Label("Load 1UBQ", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .accessibilityIdentifier("boffin.load-structure")
            }

            fetchControls(model)

            // A predicted model is not a structure, and the difference has to
            // be on screen rather than in a tooltip: the confidence column of an
            // AlphaFold model is pLDDT, which is the same field as a B-factor
            // meaning the opposite thing.
            if let caveat = model.source?.caveat {
                Label(caveat, systemImage: "wand.and.stars")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("boffin.prediction-caveat")
            }

            if let notice = model.guardrailNotice {
                Label(notice, systemImage: "speedometer")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Representation", selection: representationBinding(model)) {
                ForEach(ViewerRepresentation.allCases, id: \.rawValue) { option in
                    Text(option.name).tag(option)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)

            Picker("Colour", selection: themeBinding(model)) {
                ForEach(ViewerColourTheme.allCases, id: \.rawValue) { option in
                    Text(option.name).tag(option)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)

            trackPainting(model)
            if let selection = model.selection { inspector(selection) }
        }
    }

    /// What was tapped, and what BOFFIN knows about it.
    ///
    /// The structure reports an AUTHOR number. Turning that into a position in
    /// the user's own sequence needs the alignment, and for the bundled 1UBQ
    /// fixture the two coincide, so this says which claim it is making rather
    /// than quietly presenting one as the other.
    @ViewBuilder
    private func inspector(_ selection: (chain: String, authorNumber: Int)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Selected").font(.caption.weight(.semibold))
                Text("chain \(selection.chain), residue \(selection.authorNumber)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.accent)
                Spacer()
            }
            if let sequence = store.sequence,
                selection.authorNumber >= 1,
                selection.authorNumber <= sequence.count
            {
                let residue = sequence.residues[selection.authorNumber - 1]
                Text(
                    "Position \(selection.authorNumber) of the loaded sequence is "
                        + "\(String(residue.code)). This assumes the structure's author "
                        + "numbering matches the sequence, which holds for the bundled "
                        + "fixture and not in general."
                )
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("boffin.structure-selection")
    }

    /// Fetching, which is additive: everything above works offline.
    @ViewBuilder
    private func fetchControls(_ model: StructureViewerModel) -> some View {
        HStack(spacing: Spacing.xs) {
            TextField("PDB ID or UniProt", text: $identifier)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.caption, design: .monospaced))
                .accessibilityIdentifier("boffin.structure-identifier")
            Button("RCSB") {
                let wanted = identifier
                Task { await model.fetch { try await StructureFetcher().rcsb(wanted) } }
            }
            .buttonStyle(.bordered).font(.caption2)
            .disabled(identifier.count != 4)
            Button("AlphaFold") {
                let wanted = identifier
                Task { await model.fetch { try await StructureFetcher().alphaFold(wanted) } }
            }
            .buttonStyle(.bordered).font(.caption2)
            .disabled(identifier.count < 6)
        }
    }

    /// The point of the whole tab.
    @ViewBuilder
    private func trackPainting(_ model: StructureViewerModel) -> some View {
        let tracks = store.allTracks.filter { $0.kind == .continuous }
        if tracks.isEmpty {
            Text(
                "Load a sequence in the Order tab to paint one of its tracks onto the "
                    + "structure."
            )
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Paint a track").font(.caption.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(tracks, id: \.id) { track in
                        Button(track.title) {
                            Task { await paint(track, into: model) }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption2)
                        .tint(paintedTrack == track.id ? Brand.accent : .secondary)
                    }
                }
            }
            Text(
                "Residue numbering is mapped through the structure's author numbers, "
                    + "which is what a paper quotes. Residues the track says nothing "
                    + "about stay grey rather than taking a colour that means zero."
            )
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stateLabel(_ state: ViewerState) -> some View {
        switch state {
        case .idle, .starting:
            AnyView(Text("Starting").font(.caption).foregroundStyle(.secondary))
        case .ready:
            AnyView(Text("Ready").font(.caption).foregroundStyle(.secondary))
        case .loading:
            AnyView(
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Loading").font(.caption)
                })
        case .loaded(let count):
            AnyView(
                Text("\(count.formatted()) atoms")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.accent))
        case .failed(let message):
            AnyView(
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .lineLimit(2))
        }
    }

    private func representationBinding(
        _ model: StructureViewerModel
    ) -> Binding<ViewerRepresentation> {
        Binding(
            get: { model.representation },
            set: { value in Task { await model.set(representation: value) } })
    }

    private func themeBinding(
        _ model: StructureViewerModel
    ) -> Binding<ViewerColourTheme> {
        Binding(
            get: { model.colourTheme },
            set: { value in Task { await model.set(colourTheme: value) } })
    }

    // MARK: - Actions

    private func loadFixture(into model: StructureViewerModel) async {
        guard let url = Self.fixture(named: "1ubq.bcif"),
            let data = try? Data(contentsOf: url)
        else { return }
        await model.load(data, format: .binaryCIF, source: .bundled("1ubq.bcif"))
    }

    /// Map a track onto author numbering and send it.
    ///
    /// 1UBQ is ubiquitin numbered 1 to 76 with no gaps, so a track index plus
    /// one is its author number. That is true of this fixture and NOT true in
    /// general, which is why the mapping is written out here rather than assumed
    /// inside the viewer: a structure with an expression tag or a disordered
    /// loop needs the SIFTS mapping instead, and Phase 5 built it.
    private func paint(_ track: AnyResidueTrack, into model: StructureViewerModel) async {
        guard case .continuous(let values) = track.values else { return }

        let finite = values.compactMap { $0 }
        guard let lowest = finite.min(), let highest = finite.max(), highest > lowest
        else { return }

        var residues: [PaintTrackCommand.Residue] = []
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            let fraction = (value - lowest) / (highest - lowest)
            residues.append(
                .init(chain: "A", number: index + 1, colour: Self.colour(fraction)))
        }

        try? await model.paint(title: track.title, residues: residues)
        paintedTrack = track.id
    }

    /// A blue to white to red ramp, matching the app's diverging scale.
    static func colour(_ fraction: Double) -> Int {
        let clamped = min(max(fraction, 0), 1)
        let low = (r: 0x46, g: 0x7F, b: 0xF7)
        let mid = (r: 0xF5, g: 0xF5, b: 0xF5)
        let high = (r: 0xD3, g: 0x2F, b: 0x2F)
        func blend(_ a: Int, _ b: Int, _ t: Double) -> Int {
            Int((Double(a) + (Double(b) - Double(a)) * t).rounded())
        }
        let (from, to, t) =
            clamped < 0.5
            ? (low, mid, clamped * 2) : (mid, high, (clamped - 0.5) * 2)
        return blend(from.r, to.r, t) << 16 | blend(from.g, to.g, t) << 8
            | blend(from.b, to.b, t)
    }

    static func fixture(named name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) {
            return bundled
        }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/structures/\(name)")
        if FileManager.default.fileExists(atPath: development.path) { return development }
        #endif
        return nil
    }
}
