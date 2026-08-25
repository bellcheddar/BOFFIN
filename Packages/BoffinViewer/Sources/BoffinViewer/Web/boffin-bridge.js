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

  // Mol*'s own API, reached through the one namespace the viewer build exports.
  //
  // The UMD viewer bundle exports THIRTEEN names, and `Shape`,
  // `StateTransforms`, `Symmetry` and `OrderedSet` are not among them: they live
  // under `molstar.lib`. Code written against the top-level names does not throw,
  // it evaluates to `undefined` and takes the fallback branch, which is how two
  // commands in this file came to be committed doing nothing at all.
  // Resolved LAZILY, inside a function, never at load time.
  //
  // Destructuring these at the top of the file looked tidier and took the whole
  // bridge down: if any name is missing the property access throws while the
  // script is still evaluating, `window.boffinDispatch` is never defined, and
  // EVERY command fails with a message about dispatch rather than about the
  // name that was actually absent.
  function api() {
    const lib = (molstar && molstar.lib) || {};
    const structure = lib.structure || {};
    return {
      StructureElement: structure.StructureElement,
      StructureProperties: structure.StructureProperties,
      Symmetry: structure.Symmetry,
      Shape: (lib.shape || {}).Shape,
    };
  }

  // Read chain and author number out of a picked loci.
  //
  // Through StructureProperties, which is the supported path. Walking
  // `atomicHierarchy` segment maps by hand works and is one refactor of Mol*
  // away from silently reading the wrong column.
  function describeLoci(loci) {
    const { StructureElement, StructureProperties } = api();
    if (!StructureElement || !StructureProperties) return null;
    const location = StructureElement.Loci.firstElement(loci);
    if (!location) return null;
    return {
      chain: StructureProperties.chain.auth_asym_id(location),
      number: StructureProperties.residue.auth_seq_id(location),
      residue: StructureProperties.atom.label_comp_id(location),
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
        const info = describeLoci(loci);
        if (!info) return;
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
    // Reports which parts of Mol*'s API this build actually exposes.
    //
    // The viewer UMD bundle exports thirteen names and the rest live under
    // `molstar.lib`. A command written against a name that is not there does not
    // throw, it takes the fallback branch and returns an empty result, so this
    // exists to make the absence visible rather than inferred from a feature
    // that quietly does nothing.
    async ping() {
      await ensurePlugin();
      const available = api();
      return {
        ok: true,
        version: molstar.version || 'unknown',
        structureElement: !!available.StructureElement,
        structureProperties: !!available.StructureProperties,
        symmetry: !!available.Symmetry,
        shape: !!available.Shape,
      };
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

      const { StructureProperties } = api();
      if (!StructureProperties) {
        return { painted: 0, error: 'StructureProperties is not available' };
      }
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
                const chain = StructureProperties.chain.auth_asym_id(location);
                const number = StructureProperties.residue.auth_seq_id(location);
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
      if (!structures.length) return { assemblies: [], models: 1, note: 'no structure' };
      // Where the assemblies live depends on the build, and guessing throws.
      //
      // `molstar.ModelSymmetry` does not exist in the viewer bundle at all;
      // `molstar.lib.structure.Symmetry` DOES exist and has no `.Provider`, so
      // the obvious `Symmetry.Provider.get(model)` fails with "undefined is not
      // an object" and takes the whole load with it. Each candidate is tried
      // inside its own guard and the reason is reported when none works, so an
      // empty picker is distinguishable from an absent one.
      const model = structures[0].cell.obj.data.models[0];
      const { Symmetry } = api();
      let source = [];
      let note = '';
      let via = 'none';
      try {
        if (model && model.symmetry && model.symmetry.assemblies) {
          source = model.symmetry.assemblies;
          via = 'model.symmetry';
        } else if (Symmetry && Symmetry.Provider && Symmetry.Provider.get) {
          const symmetry = Symmetry.Provider.get(model);
          source = (symmetry && symmetry.assemblies) || [];
          via = 'Symmetry.Provider';
        } else {
          note = 'no symmetry provider in this Mol* build';
        }
      } catch (error) {
        note = String(error && error.message ? error.message : error);
        source = [];
      }
      if (!note && source.length === 0) {
        // Distinguish "asked and the structure declares none" from "could not
        // ask". Both produce an empty picker and only one of them is a fact.
        note = 'read via ' + via + ', none declared';
      }
      const assemblies = source.map((a) => ({
        id: a.id,
        details: a.details || '',
      }));
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
