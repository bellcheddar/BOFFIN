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
      // Replace, do not accumulate.
      //
      // `loadStructureFromData` ADDS a structure to the hierarchy; it does not
      // clear what is already there. Every read below indexes `structures[0]`,
      // which stays the FIRST structure ever loaded, so after a second load the
      // viewer showed the new molecule while every query answered about the
      // old one.
      //
      // That is the real cause of the 3D interaction overlay failing twice. It
      // was diagnosed as a selection-language problem, and the selection
      // language was innocent: the endpoints were being resolved against
      // ubiquitin while the profile had been computed on a kinase, so of course
      // nothing matched. It also meant the reported atom count after a second
      // load was the first structure's.
      await viewer.plugin.clear();
      state.structure = null;

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

    // Draw the interaction profile as dashed lines in 3D.
    //
    // Built twice before this and removed twice. Both attempts failed at the
    // same place: resolving which ATOM each end of a line refers to.
    //
    // The first assembled a list of shapes and did nothing with them. The
    // second used the measurement manager, which is the right manager, with
    // endpoints named in PyMOL syntax through `StructureSelectionFromScript`,
    // which returns an EMPTY selection in this build with the state cell
    // reporting success and no error. It measured 0 of 40 lines drawn.
    //
    // This one resolves endpoints with `StructureElement.Loci.fromSchema`,
    // which takes the fields BOFFIN already has (author chain, author residue
    // number, atom name) and is a declarative selector rather than a parsed
    // language. There is no element index on either side to agree about, which
    // is the assumption the previous attempts were making.
    //
    // The counter stays regardless. An overlay drawing nothing looks exactly
    // like one with nothing to draw, so the count of lines ACTUALLY added is
    // returned and the caller is expected to check it against what it asked
    // for. That counter is what caught the second attempt.
    async drawInteractions(payload) {
      const viewer = await ensurePlugin();
      const lib = (molstar && molstar.lib) || {};
      const structureLib = lib.structure || {};
      const StructureElement = structureLib.StructureElement;
      if (!StructureElement || !StructureElement.Loci
          || typeof StructureElement.Loci.fromSchema !== 'function') {
        throw new Error(
          'molstar.lib.structure.StructureElement.Loci.fromSchema is not available'
        );
      }

      const manager = viewer.plugin.managers.structure.measurement;
      if (!manager || typeof manager.addDistance !== 'function') {
        throw new Error('managers.structure.measurement.addDistance is not available');
      }

      const cell = viewer.plugin.managers.structure.hierarchy.current.structures[0];
      const structure = cell && cell.cell.obj && cell.cell.obj.data;
      if (!structure) throw new Error('no structure is loaded');

      function locus(end) {
        return StructureElement.Loci.fromSchema(structure, {
          auth_asym_id: end.chain,
          auth_seq_id: end.number,
          auth_atom_id: end.atom,
        });
      }

      const lines = payload.lines || [];
      let drawn = 0;
      const unresolved = [];

      for (const line of lines) {
        let a, b;
        try {
          a = locus(line.a);
          b = locus(line.b);
        } catch (error) {
          unresolved.push(describe(line) + ': ' + error.message);
          continue;
        }
        // An empty Loci is the exact failure that went unnoticed last time, so
        // it is counted and named rather than passed on to a manager that will
        // accept it happily.
        if (StructureElement.Loci.isEmpty(a) || StructureElement.Loci.isEmpty(b)) {
          unresolved.push(describe(line) + ': one or both endpoints resolved to nothing');
          continue;
        }
        await manager.addDistance(a, b, {
          visualParams: { dashLength: 0.2 },
          selectionTag: 'boffin-interactions',
        });
        drawn += 1;
      }

      function describe(line) {
        return line.a.chain + '/' + line.a.number + '/' + line.a.atom
          + ' to ' + line.b.chain + '/' + line.b.number + '/' + line.b.atom;
      }

      state.hasInteractionOverlay = drawn > 0;
      // The first few reasons, not all of them: forty identical failures say
      // the same thing as three and cost more to carry back across the bridge.
      return { requested: lines.length, drawn: drawn, unresolved: unresolved.slice(0, 3) };
    },

    // Remove the overlay without disturbing the structure.
    async clearInteractions() {
      const viewer = await ensurePlugin();
      const manager = viewer.plugin.managers.structure.measurement;
      if (manager && typeof manager.getTransforms === 'function') {
        const transforms = manager.getTransforms();
        for (const transform of transforms) {
          await viewer.plugin.state.data.build().delete(transform.ref).commit();
        }
      }
      state.hasInteractionOverlay = false;
      return { ok: true };
    },

    // Render offscreen at an arbitrary size, so a figure can come off a phone.
    //
    // Written against what this vendored build actually exposes rather than
    // against the documented API: `plugin.helpers.viewportScreenshot` is real
    // here, its parameters are set by pushing a complete value object into
    // `behaviors.values`, and `getImageDataUri` returns a data URI. The UMD
    // build has already caught this project out once by exporting fewer names
    // at the top level than its source suggests, and the failure mode was not
    // an exception: it was `undefined` taking a fallback branch and a command
    // that appeared to work while drawing nothing.
    //
    // So the helper's absence is an explicit throw naming the path that was
    // missing, and the size actually rendered is returned alongside the image
    // so the caller can check it got what it asked for instead of trusting it.
    async exportImage(payload) {
      const viewer = await ensurePlugin();
      const helper = viewer.plugin.helpers && viewer.plugin.helpers.viewportScreenshot;
      if (!helper || typeof helper.getImageDataUri !== 'function') {
        throw new Error(
          'plugin.helpers.viewportScreenshot.getImageDataUri is not available in this build'
        );
      }

      const width = payload.width;
      const height = payload.height;

      // Merge over the current values rather than replacing them: the
      // parameter object carries fields this command has no opinion about
      // (axes, illumination), and pushing a partial object drops them.
      const current = helper.values;
      helper.behaviors.values.next({
        ...current,
        format: { name: 'png', params: {} },
        transparent: !!payload.transparent,
        resolution: { name: 'custom', params: { width: width, height: height } },
      });

      const uri = await helper.getImageDataUri();
      if (typeof uri !== 'string' || uri.indexOf('data:image/png;base64,') !== 0) {
        throw new Error('screenshot did not return a PNG data URI');
      }

      // What was actually rendered, which is not necessarily what was asked
      // for: the helper clamps to its own parameter bounds.
      const size = typeof helper.getSize === 'function'
        ? helper.getSize()
        : { width: width, height: height };

      return {
        base64: uri.slice('data:image/png;base64,'.length),
        width: size.width,
        height: size.height,
      };
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
