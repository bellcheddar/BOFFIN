//  boffin-bridge.js
//  BoffinViewer
//
//  The JavaScript half of the typed command envelope.
//
//  Everything Swift asks of Mol* arrives here as one JSON object with a `name`
//  and a `payload`, dispatched by a table. Nothing is built by string
//  concatenation and no Swift value is ever interpolated into source, which is
//  the failure mode hard rule 3 exists to prevent: a chain identifier with a
//  quote in it should be a chain that does not exist, not an injection.
//
//  This shim is also the seam. A native Metal renderer would implement the same
//  envelope and the SwiftUI layer above would not change, so the mapping from
//  BOFFIN's vocabulary to Mol*'s plugin API lives here and only here.

'use strict';

(function () {
  const state = {
    plugin: null,
    structure: null,
    // Residue keys the app has painted, so a repaint can clear the previous one
    // without tearing down the representation.
    overlay: null,
  };

  function post(event) {
    // One handler, a tagged union on the Swift side. Adding a second handler is
    // how a bridge acquires two ways to say the same thing.
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.boffin) {
      window.webkit.messageHandlers.boffin.postMessage(event);
    }
  }

  // Read chain and author number out of a Mol* location.
  //
  // The hierarchy indirection is the awkward part and it is not decoration: an
  // element index addresses an ATOM, and the chain and residue it belongs to are
  // found by walking the segment maps. Reading auth_asym_id at the element index
  // directly returns whatever chain happens to sit at that ordinal, which is
  // usually the right answer for a single-chain structure and wrong for every
  // other one.
  function describe(location) {
    const unit = location.unit;
    const element = location.element;
    const hierarchy = unit.model.atomicHierarchy;
    const chainIndex = hierarchy.chainAtomSegments.index[element];
    const residueIndex = hierarchy.residueAtomSegments.index[element];
    return {
      chain: hierarchy.chains.auth_asym_id.value(chainIndex),
      number: hierarchy.residues.auth_seq_id.value(residueIndex),
      residue: hierarchy.atoms.label_comp_id
        ? hierarchy.atoms.label_comp_id.value(element)
        : '',
    };
  }

  function watchInteractions(viewer) {
    const plugin = viewer.plugin;
    // Clicks and hovers both arrive as behaviour events. Subscribing rather than
    // polling means a pick costs nothing until one happens.
    plugin.behaviors.interaction.click.subscribe((event) => {
      try {
        const loci = event.current && event.current.loci;
        if (!loci || !loci.elements || !loci.elements.length) return;
        const first = loci.elements[0];
        const location = {
          unit: first.unit,
          element: first.unit.elements[molstar.OrderedSet
            ? molstar.OrderedSet.start(first.indices)
            : 0],
        };
        const info = describe(location);
        post({ kind: 'picked', chain: info.chain, number: info.number });
      } catch (error) {
        // A pick that cannot be described is not worth an error banner: the
        // user tapped the background or a water. Say nothing.
      }
    });
  }

  async function ensurePlugin() {
    if (state.plugin) return state.plugin;
    state.plugin = await molstar.Viewer.create('viewer', {
      layoutIsExpanded: false,
      layoutShowControls: false,
      layoutShowSequence: false,
      layoutShowLog: false,
      layoutShowLeftPanel: false,
      viewportShowExpand: false,
      viewportShowSelectionMode: false,
      viewportShowAnimation: false,
      pdbProvider: 'rcsb',
      emdbProvider: 'rcsb',
    });
    watchInteractions(state.plugin);
    return state.plugin;
  }

  // Commands. Each returns a plain object, which becomes the Swift reply.
  const commands = {
    async ping() {
      await ensurePlugin();
      return { ok: true, molstar: molstar.PluginConfig ? 'ready' : 'unknown' };
    },

    // Structures arrive as base64 rather than by URL. The app has already read
    // the bytes, from the bundle or from a downloaded asset, and handing the web
    // view a file URL would mean granting it read access to a directory.
    async loadStructure(payload) {
      const viewer = await ensurePlugin();
      const binary = atob(payload.base64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);

      // BinaryCIF is NOT a separate format name to Mol*: it is mmCIF with the
      // binary flag set. Passing 'bcif' returns "unknown data format name",
      // which is at least a clear error and was the first thing this bridge got
      // wrong.
      const isBinary = payload.format === 'bcif';
      await viewer.loadStructureFromData(
        isBinary ? bytes.buffer : binary,
        'mmcif',
        isBinary
      );
      state.structure = viewer.plugin.managers.structure.hierarchy.current.structures[0];
      const count = state.structure
        ? state.structure.cell.obj.data.elementCount
        : 0;
      post({ kind: 'loaded', atomCount: count });
      return { atomCount: count };
    },

    async setRepresentation(payload) {
      const viewer = await ensurePlugin();
      await viewer.plugin.managers.structure.component.updateRepresentationsTheme(
        viewer.plugin.managers.structure.hierarchy.current.structures[0].components,
        { type: payload.representation }
      );
      return { ok: true };
    },

    async setColourTheme(payload) {
      const viewer = await ensurePlugin();
      await viewer.plugin.managers.structure.component.updateRepresentationsTheme(
        viewer.plugin.managers.structure.hierarchy.current.structures[0].components,
        { color: payload.theme }
      );
      return { ok: true };
    },

    // Painting a ResidueTrack onto the structure: the single most compelling
    // thing the viewer does, and the reason the bridge carries colours per
    // residue rather than a theme name.
    async paintTrack(payload) {
      const viewer = await ensurePlugin();
      const plugin = viewer.plugin;
      const structures = plugin.managers.structure.hierarchy.current.structures;
      if (!structures.length) return { painted: 0 };

      const lookup = new Map();
      for (const entry of payload.residues) {
        lookup.set(entry.chain + ':' + entry.number, entry.colour);
      }

      const themeName = 'boffin-track';
      const provider = {
        name: themeName,
        label: payload.title || 'BOFFIN track',
        category: 'Custom',
        factory: (ctx) => {
          const fallback = payload.fallbackColour >>> 0;
          return {
            factory: provider.factory,
            granularity: 'group',
            color: (location) => {
              try {
                const unit = location.unit;
                const element = location.element;
                const chain = unit.model.atomicHierarchy.chains.auth_asym_id.value(
                  unit.model.atomicHierarchy.chainAtomSegments.index[element]
                );
                const number = unit.model.atomicHierarchy.residues.auth_seq_id.value(
                  unit.model.atomicHierarchy.residueAtomSegments.index[element]
                );
                const found = lookup.get(chain + ':' + number);
                return found === undefined ? fallback : found >>> 0;
              } catch (error) {
                return payload.fallbackColour >>> 0;
              }
            },
            props: {},
            description: payload.title || '',
          };
        },
        getParams: () => ({}),
        defaultValues: {},
        isApplicable: () => true,
      };

      if (!plugin.representation.structure.themes.colorThemeRegistry.has(provider)) {
        plugin.representation.structure.themes.colorThemeRegistry.add(provider);
      }
      await plugin.managers.structure.component.updateRepresentationsTheme(
        structures[0].components, { color: themeName }
      );
      state.overlay = themeName;
      return { painted: payload.residues.length };
    },

    // Biological assemblies, symmetry mates and NMR models.
    //
    // The deposited coordinates are the ASYMMETRIC UNIT, which is a
    // crystallographic convenience and frequently not the molecule. A dimer
    // deposited with one chain in the asymmetric unit looks like a monomer until
    // the assembly is built, and that is a picture of the wrong protein rather
    // than an incomplete one.
    async listAssemblies() {
      const viewer = await ensurePlugin();
      const structures = viewer.plugin.managers.structure.hierarchy.current.structures;
      if (!structures.length) return { assemblies: [], models: 1 };
      const model = structures[0].cell.obj.data.models[0];
      const symmetry = model && molstar.ModelSymmetry
        ? molstar.ModelSymmetry.Provider.get(model)
        : null;
      const assemblies = symmetry && symmetry.assemblies
        ? symmetry.assemblies.map((a) => ({
            id: a.id,
            details: a.details || '',
          }))
        : [];
      const trajectory = viewer.plugin.managers.structure.hierarchy.current.models;
      return { assemblies: assemblies, models: trajectory.length || 1 };
    },

    async setAssembly(payload) {
      const viewer = await ensurePlugin();
      const structures = viewer.plugin.managers.structure.hierarchy.current.structures;
      if (!structures.length) return { ok: false };
      await viewer.plugin.managers.structure.hierarchy.updateStructure(
        structures[0],
        {
          type: payload.assemblyId
            ? { name: 'assembly', params: { id: payload.assemblyId } }
            : { name: 'model', params: {} },
        }
      );
      const count = viewer.plugin.managers.structure.hierarchy.current.structures[0]
        .cell.obj.data.elementCount;
      post({ kind: 'loaded', atomCount: count });
      return { atomCount: count };
    },

    async resetCamera() {
      const viewer = await ensurePlugin();
      viewer.plugin.managers.camera.reset();
      return { ok: true };
    },

    async clear() {
      const viewer = await ensurePlugin();
      await viewer.plugin.clear();
      state.structure = null;
      return { ok: true };
    },
  };

  // The single entry point Swift calls. Unknown commands are an error with a
  // name in it, not a silent no-op: a bridge that ignores what it does not
  // understand is a bridge that appears to work while doing nothing.
  window.boffinDispatch = async function (envelope) {
    try {
      const handler = commands[envelope.name];
      if (!handler) {
        return { error: 'unknown command: ' + envelope.name };
      }
      const result = await handler(envelope.payload || {});
      return { result: result === undefined ? null : result };
    } catch (error) {
      post({ kind: 'failed', message: String(error && error.message ? error.message : error) });
      return { error: String(error && error.message ? error.message : error) };
    }
  };

  post({ kind: 'ready' });
})();
