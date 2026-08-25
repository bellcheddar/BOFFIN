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
    @State private var setupError: UserFacingError?
    @State private var paintedTrack: TrackID?
    @State private var identifier: String = ""
    @State private var profile: InteractionProfile?
    @State private var loadedStore: AtomStore?
    /// The structure currently shown, parsed by BOFFIN rather than by the
    /// viewer, so geometry questions are answered from our own read of the
    /// bytes.
    @State private var loadedViewerStore: AtomStore?
    @State private var deck = SceneDeckModel()
    /// The last rendered figure, held so it can be shared and described.
    @State private var exported: StructureViewerModel.ExportedImage?
    @State private var exportError: UserFacingError?
    @State private var isExporting = false
    @State private var wantsTransparentBackground = true
    @State private var overlayError: UserFacingError?
    @State private var isBuildingSelection = false
    /// The selection expression, kept as text because that is what travels
    /// into a `.pml` file and opens on a desktop.
    @State private var selectionExpression = ""
    @State private var selectionMatch: Int?
    @State private var symmetryError: UserFacingError?
    /// The unit cell of the loaded entry, read from the file BOFFIN parsed.
    @State private var loadedCell: CrystalSymmetry?

    var body: some View {
        NavigationStack {
            Group {
                if let setupError {
                    ContentUnavailableView {
                        Label("Viewer unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        FailureView(setupError) {
                            self.setupError = nil; start()
                        }
                    }
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
            setupError = UserFacingError(error, whileDoing: "starting the structure viewer")
        }
    }

    @ViewBuilder
    private func viewer(_ model: StructureViewerModel) -> some View {
        VStack(spacing: 0) {
            // A fixed share for the viewer, the rest for the controls.
            //
            // `maxHeight: .infinity` gave the viewer everything and left the
            // panel with whatever its content happened to need, which put the
            // first control row under the tab bar. An ideal height with a
            // layout priority was worse: the viewer won the negotiation and the
            // controls were pushed off the bottom entirely.
            StructureViewerView(model: model)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(.black)
                .accessibilityIdentifier("boffin.structure-viewer")
                // The web view is a separate process and the system terminates
                // it under pressure rather than asking. Releasing the structure
                // ourselves gives most of the memory back and leaves the page
                // alive, so recovery is one command rather than a blank viewer.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification)
                ) { _ in
                    Task { await model.releaseUnderMemoryPressure() }
                }

            // The controls SCROLL, and they have to.
            //
            // This was a plain VStack under a viewer taking all remaining
            // height. That was fine when it held a representation picker and a
            // colour picker; it now carries assemblies, crystal symmetry, the
            // selection builder, figure export and the interaction profile, and
            // on a phone most of that was simply unreachable: laid out, off the
            // bottom, with nothing to scroll. A UI test caught it by failing to
            // tap a control it could see in the hierarchy.
            //
            // The viewer gets a share of the height rather than everything left
            // over, so the panel always has somewhere to be.
            ScrollView {
                controls(model)
                    .padding(Spacing.s)
            }
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

            assemblyControls(model)
            interactionControls(model)
            agreementSection
            SceneDeckView(model: deck, viewer: model)
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

    /// The model's prediction against the structure's own geometry.
    ///
    /// This is the check the app can make that no benchmark can: the secondary
    /// structure head predicts from sequence alone, and the loaded structure
    /// says what the backbone actually does. Agreement is not a score for the
    /// head, it is a statement about THIS protein, which is what a user wants
    /// when deciding whether to trust a track.
    @ViewBuilder
    private var agreementSection: some View {
        if let comparison = structureAgreement {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prediction against geometry").font(.caption.weight(.semibold))
                Text(
                    String(
                        format:
                            "The secondary structure head agrees with the structure at "
                            + "%.0f%% of %d residues (three state).",
                        comparison.agreement * 100, comparison.compared)
                )
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("boffin.structure-agreement")

                Text(
                    "Assignment is computed from the coordinates by BOFFIN's own "
                        + "implementation of Kabsch and Sander, not read from the "
                        + "entry. Residues are matched by position, which holds for "
                        + "the bundled fixture and needs the alignment in general."
                )
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Compare the head's three-state call with the structure's assignment.
    private var structureAgreement: (agreement: Double, compared: Int)? {
        guard let store = viewerStore,
            let predictions = store.0 as AtomStore?,
            let predicted = self.store.predictions?.secondaryStructure,
            !predicted.isEmpty
        else { return nil }
        let assigned = SecondaryStructureAssigner.assign(predictions, chain: store.1)
        guard !assigned.isEmpty else { return nil }

        var compared = 0
        var agreed = 0
        for index in 0..<min(assigned.count, predicted.count) {
            let structural = assigned[index].threeState
            guard structural != "-" else { continue }
            let model: Character
            switch predicted[index] {
            case .alphaHelix, .threeTenHelix, .piHelix: model = "H"
            case .betaStrand, .betaBridge: model = "E"
            default: model = "C"
            }
            compared += 1
            if model == structural { agreed += 1 }
        }
        guard compared > 0 else { return nil }
        return (Double(agreed) / Double(compared), compared)
    }

    /// The structure currently in the viewer, and the chain to compare.
    private var viewerStore: (AtomStore, String)? {
        guard let store = loadedViewerStore, let chain = store.chains.first else {
            return nil
        }
        return (store, chain)
    }

    /// Interaction profiling for the loaded structure.
    ///
    /// The profile is computed by BOFFIN's own parser over the same bytes the
    /// viewer was handed, not by asking the viewer. Two sources of truth about
    /// what an atom index means is one too many.
    @ViewBuilder
    private func interactionControls(_ model: StructureViewerModel) -> some View {
        if case .loaded = model.state {
            symmetryPanel(model)

            selectionPanel

            figureExport(model)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Button("Profile interactions") {
                        Task { await profileInteractions(into: model) }
                    }
                    .buttonStyle(.bordered).font(.caption2)
                    .accessibilityIdentifier("boffin.profile-interactions")
                    Spacer()
                    if let profile, let store = loadedStore {
                        ShareLink(item: profile.csv(in: store, structureName: "structure")) {
                            Label("CSV", systemImage: "tablecells")
                                .font(.caption2)
                        }
                        .accessibilityIdentifier("boffin.share-interactions")
                    }
                }

                // How much of the profile actually reached the structure.
                //
                // Shown, not merely returned. An overlay drawing nothing is
                // pixel-for-pixel identical to one with nothing to draw, and
                // that indistinguishability is how this feature shipped broken
                // twice. The count is the only thing that tells them apart, so
                // it is on screen rather than in a log.
                if let overlay = model.overlay {
                    Text("\(String(overlay.drawn)) of \(String(overlay.requested)) drawn in 3D")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(
                            overlay.isComplete ? .secondary : ScientificPalette.warning
                        )
                        .accessibilityIdentifier("boffin.overlay.count")
                    if let shortfall = overlay.shortfall {
                        Text(shortfall)
                            .font(.caption2)
                            .foregroundStyle(ScientificPalette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(overlay.unresolved, id: \.self) { reason in
                            Text(reason)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let overlayError {
                    FailureView(overlayError)
                }

                if let profile, let store = loadedStore {
                    // The assumptions are shown above the results, not below
                    // them: a reader who stops after the numbers has to have
                    // seen what they rest on.
                    Label(profile.assumptions.statement, systemImage: "questionmark.circle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("boffin.interaction-assumptions")

                    InteractionDiagram(
                        ligandName: ligandName(store),
                        contacts: Self.contacts(from: profile, in: store)
                    )
                    .frame(height: 220)

                    Text(profile.summary(in: store))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Group a profile by contacted residue, for the diagram.
    ///
    /// The kinds are ordered by the enum rather than by discovery, so two
    /// diagrams of the same site put the same connector in the same place.
    static func contacts(
        from profile: InteractionProfile, in store: AtomStore
    ) -> [DiagramContact] {
        var byResidue: [Int: (kinds: Set<Interaction.Kind>, closest: Double, label: String)] = [:]
        for interaction in profile.interactions {
            let number = store.authorNumber[interaction.partnerAtom]
            let label = "\(store.residueName[interaction.partnerAtom])\(number)"
            var entry = byResidue[number] ?? ([], .greatestFiniteMagnitude, label)
            entry.kinds.insert(interaction.kind)
            entry.closest = min(entry.closest, interaction.distance)
            byResidue[number] = entry
        }
        return byResidue.keys.sorted().compactMap { number in
            guard let entry = byResidue[number] else { return nil }
            return DiagramContact(
                label: entry.label,
                kinds: Interaction.Kind.allCases
                    .filter { entry.kinds.contains($0) }
                    .map { Self.diagramKind($0) },
                distance: entry.closest)
        }
    }

    /// Map BoffinStructure's kinds onto BoffinCharts's.
    ///
    /// Two enums rather than one, because BoffinCharts sees BoffinCore and
    /// nothing else. The app is the only place that can see both, which is the
    /// dependency rule working rather than duplication for its own sake.
    static func diagramKind(_ kind: Interaction.Kind) -> DiagramKind {
        switch kind {
        case .hydrophobic: .hydrophobic
        case .hydrogenBond: .hydrogenBond
        case .saltBridge: .saltBridge
        case .metalCoordination: .metalCoordination
        case .halogenBond: .halogenBond
        }
    }

    private func ligandName(_ store: AtomStore) -> String {
        let ligand = SelectionEvaluator.evaluate(.category(.organic), in: store).indices
        guard let first = ligand.first else { return "ligand" }
        return store.residueName[first]
    }

    /// Load the kinase fixture and profile it.
    ///
    /// The structure is loaded into the VIEWER as well as parsed, because
    /// profiling something you are not looking at is a report about a different
    /// molecule. It also means the assembly controls are exercised against a
    /// structure that declares one, which 1UBQ does not.
    private func profileInteractions(into model: StructureViewerModel) async {
        guard let url = Self.fixture(named: "1hck.bcif"),
            let data = try? Data(contentsOf: url),
            let file = try? BinaryCIF.decode(data),
            let store = try? AtomStore.from(file)
        else { return }
        await model.load(data, format: .binaryCIF, source: .bundled("1hck.bcif"))
        loadedCell = CrystalSymmetry.read(from: file)
        loadedStore = store
        loadedViewerStore = store
        // Disulfides are the one construct constraint that cannot be read off
        // a sequence, so the Boundary tab only learns about them once a
        // structure is on screen.
        self.store.noteStructure(store)
        let ligand = SelectionEvaluator.evaluate(.category(.organic), in: store).indices
        let computed = InteractionProfiler.profile(store, ligand: ligand)
        profile = computed
        await drawOverlay(computed, atoms: store, into: model)
    }

    /// Put the profile on the structure, and say how much of it landed.
    ///
    /// Endpoints are named by chain, residue number and atom name rather than
    /// by index. That is the whole design: an index means BOFFIN's atom order
    /// and Mol*'s element order agreeing, and both previous attempts at this
    /// feature assumed exactly that and drew nothing.
    private func drawOverlay(
        _ profile: InteractionProfile, atoms: AtomStore, into model: StructureViewerModel
    ) async {
        let lines = profile.interactions.map { interaction in
            DrawInteractionsCommand.Line(
                a: DrawInteractionsCommand.Endpoint(
                    chain: atoms.chainID[interaction.ligandAtom],
                    number: atoms.authorNumber[interaction.ligandAtom],
                    atom: atoms.atomName[interaction.ligandAtom]),
                b: DrawInteractionsCommand.Endpoint(
                    chain: atoms.chainID[interaction.partnerAtom],
                    number: atoms.authorNumber[interaction.partnerAtom],
                    atom: atoms.atomName[interaction.partnerAtom]),
                kind: interaction.kind.rawValue)
        }
        guard !lines.isEmpty else { return }
        do {
            _ = try await model.drawInteractions(lines)
            overlayError = nil
        } catch {
            overlayError = UserFacingError(error, whileDoing: "drawing the interactions")
        }
    }

    // MARK: - Crystal symmetry

    /// Show the neighbours in the lattice.
    ///
    /// The deposited coordinates are one molecule in a crystal, and a contact
    /// between two chains is either a biological interface or an artefact of
    /// how it packed. Those are indistinguishable without the neighbours.
    @ViewBuilder
    private func symmetryPanel(_ model: StructureViewerModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Crystal packing").font(.headline)

            HStack(spacing: Spacing.s) {
                ForEach([0.0, 5.0, 10.0], id: \.self) { radius in
                    Button(radius == 0 ? "One copy" : "\(Int(radius)) Å") {
                        Task { await applySymmetry(radius, to: model) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                    .disabled(loadedCell.map { !$0.isCrystallographic } ?? false)
                    .accessibilityIdentifier("boffin.symmetry.\(Int(radius))")
                }
            }

            // Whether this entry can have symmetry mates at all is read from
            // the file's own cell, not asked of the viewer. An NMR ensemble and
            // a predicted model have no lattice, so offering to build their
            // neighbours is offering something that cannot exist.
            if let cell = loadedCell, !cell.isCrystallographic, let refusal = cell.refusal {
                Label(refusal, systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("boffin.symmetry.result")
            } else if let symmetry = model.symmetry {
                // The added count is what says something happened. Zero after a
                // successful build is a real answer at 1 Å and a suspicious one
                // at 10.
                Text(
                    "\(symmetry.added.formatted()) atoms from neighbours"
                        + (loadedCell?.spacegroup.map { ", spacegroup \($0)" } ?? "")
                )
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("boffin.symmetry.result")
            }

            if let symmetryError {
                FailureView(symmetryError)
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func applySymmetry(_ radius: Double, to model: StructureViewerModel) async {
        do {
            _ = try await model.setSymmetryMates(radius: radius)
            symmetryError = nil
        } catch {
            symmetryError = UserFacingError(error, whileDoing: "building symmetry mates")
        }
    }

    // MARK: - Selection

    /// The selection expression, and a way to build one without typing it.
    @ViewBuilder
    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Selection").font(.headline)
                Spacer()
                Button("Build", systemImage: "hand.tap") { isBuildingSelection = true }
                    .font(.caption2)
                    .disabled(loadedViewerStore == nil)
                    .accessibilityIdentifier("boffin.selection.build")
            }

            if selectionExpression.isEmpty {
                Text(
                    "`byres (polymer within 5 of organic)` is a fine thing to type on a "
                        + "keyboard and a miserable thing to type on a phone. Build one "
                        + "by tapping instead."
                )
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(selectionExpression)
                    .sequenceFont(size: 11)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("boffin.selection.current")
                if let selectionMatch {
                    Text("\(selectionMatch.formatted()) atoms")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $isBuildingSelection) {
            if let atoms = loadedViewerStore {
                SelectionBuilderView(atoms: atoms, expression: $selectionExpression)
                    .onDisappear { recountSelection(in: atoms) }
            }
        }
    }

    private func recountSelection(in atoms: AtomStore) {
        let trimmed = selectionExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = try? SelectionParser.parse(trimmed) else {
            selectionMatch = nil
            return
        }
        selectionMatch = SelectionEvaluator.evaluate(parsed, in: atoms).indices.count
    }

    // MARK: - Figure export

    /// Render the current view at a size a journal will accept.
    ///
    /// A screenshot of this phone is 1179 pixels across. Mol* renders the same
    /// scene offscreen at an arbitrary size, so the figure that comes off a
    /// phone here is the same one that would come off a workstation.
    ///
    /// Transparent by default. A structure on an opaque white ground cannot be
    /// composited onto a coloured panel without cutting it out by hand, and
    /// cutting out antialiased edges by hand is how a figure acquires a halo.
    @ViewBuilder
    private func figureExport(_ model: StructureViewerModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Figure").font(.headline)
                Spacer()
                if isExporting {
                    ProgressView().controlSize(.small)
                }
            }

            Toggle("Transparent background", isOn: $wantsTransparentBackground)
                .font(.caption)
                .accessibilityIdentifier("boffin.export.transparent")

            HStack(spacing: Spacing.s) {
                ForEach(Self.figureSizes, id: \.label) { size in
                    Button(size.label) {
                        Task { await export(model, width: size.width, height: size.height) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                    .disabled(isExporting)
                    .accessibilityIdentifier("boffin.export.\(size.label)")
                }
            }

            if let exportError {
                FailureView(exportError)
            }

            if let exported {
                // The size is read out of the PNG's own header rather than
                // taken from what was asked for. Those are two different
                // claims, and the one that matters is the one inside the file
                // the user is about to send somewhere: a caption reading 3840
                // over a 1179-pixel image is a figure that comes back from
                // review.
                let declared = exported.declaredSize
                HStack {
                    if let declared {
                        // Not "\(width) x \(height)": interpolating an Int
                        // into a Text localises it, so a 1016-pixel figure
                        // renders as "1,016". A pixel count is not a quantity
                        // that takes a thousands separator, and in a figure
                        // caption it reads as a typo in the app.
                        Text(
                            "\(String(declared.width)) x \(String(declared.height)) PNG"
                        )
                        .font(.system(.caption2, design: .monospaced))
                        .accessibilityIdentifier("boffin.export.size")
                    } else {
                        Text("The exported bytes are not a PNG")
                            .font(.caption2)
                            .foregroundStyle(ScientificPalette.warning)
                            .accessibilityIdentifier("boffin.export.size")
                    }
                    Text("read from the file")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    ShareLink(
                        item: Image(uiImage: uiImage(exported)),
                        preview: SharePreview(
                            "BOFFIN figure", image: Image(uiImage: uiImage(exported)))
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up").font(.caption2)
                    }
                    .accessibilityIdentifier("boffin.export.share")
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The offered sizes.
    ///
    /// Named for what they are for rather than by pixel count, because "2x
    /// column" is a decision a person makes and "1720 x 1000" is arithmetic
    /// they should not have to do. The single-column width is the common
    /// journal measure of 86 mm at 300 dpi, near enough.
    private static let figureSizes: [(label: String, width: Int, height: Int)] = [
        ("1 column", 1016, 762),
        ("2 column", 2126, 1594),
        ("Poster", 4096, 3072),
    ]

    private func uiImage(_ exported: StructureViewerModel.ExportedImage) -> UIImage {
        UIImage(data: exported.data) ?? UIImage()
    }

    private func export(_ model: StructureViewerModel, width: Int, height: Int) async {
        isExporting = true
        defer { isExporting = false }
        do {
            exported = try await model.exportImage(
                width: width, height: height, transparent: wantsTransparentBackground)
            exportError = nil
        } catch {
            exported = nil
            exportError = UserFacingError(error, whileDoing: "rendering the figure")
        }
    }

    /// Biological assembly and NMR model.
    ///
    /// Shown only when the structure declares something to choose, because a
    /// picker with one entry is furniture. The wording matters: the deposited
    /// coordinates are the asymmetric unit, which is a crystallographic
    /// convenience and frequently not the molecule.
    @ViewBuilder
    private func assemblyControls(_ model: StructureViewerModel) -> some View {
        if !model.assemblies.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Picker("Assembly", selection: assemblyBinding(model)) {
                    Text("Deposited coordinates").tag(String?.none)
                    ForEach(model.assemblies) { option in
                        Text(
                            option.details.isEmpty
                                ? "Assembly \(option.id)"
                                : "Assembly \(option.id): \(option.details)"
                        )
                        .tag(String?.some(option.id))
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .accessibilityIdentifier("boffin.assembly-picker")

                Text(
                    "The deposited coordinates are the asymmetric unit, which is a "
                        + "crystallographic convenience and often not the molecule. A "
                        + "dimer with one chain in the asymmetric unit looks like a "
                        + "monomer until the assembly is built."
                )
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let note = model.assemblyNote {
            // An empty list because the structure declares no assembly is a
            // fact. An empty list because the viewer could not look is a defect,
            // and the two must not read the same on screen.
            Label(
                "Biological assemblies could not be read: \(note)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("boffin.assembly-note")
        }
        if model.modelCount > 1 {
            Label(
                "\(model.modelCount) models in this file: an NMR ensemble. One is "
                    + "shown; superimposing all of them renders as a single very badly "
                    + "resolved structure.",
                systemImage: "square.stack.3d.up"
            )
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func assemblyBinding(_ model: StructureViewerModel) -> Binding<String?> {
        Binding(
            get: { model.assembly },
            set: { value in Task { await model.set(assembly: value) } })
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
        let decoded = try? BinaryCIF.decode(data)
        loadedCell = decoded.flatMap { CrystalSymmetry.read(from: $0) }
        let atoms = decoded.flatMap { try? AtomStore.from($0) }
        loadedViewerStore = atoms
        if let atoms { store.noteStructure(atoms) } else { store.forgetStructure() }
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
