//  AtomStoreBridge.swift
//  BoffinRenderer
//
//  Turning a parsed structure into something the renderer can draw.

import BoffinStructure
import simd

extension RendererAtom {

    /// Every atom of a structure, at van der Waals radii and CPK colours.
    ///
    /// Radii and colours are looked up per element rather than per atom name:
    /// a benchmark that spent its time in string comparisons would be
    /// measuring the lookup rather than the renderer.
    public static func all(from store: AtomStore) -> [RendererAtom] {
        var atoms: [RendererAtom] = []
        atoms.reserveCapacity(store.count)
        for index in 0..<store.count {
            let element = store.element[index].uppercased()
            atoms.append(
                RendererAtom(
                    position: SIMD3(store.x[index], store.y[index], store.z[index]),
                    radius: radius(of: element),
                    colour: colour(of: element)))
        }
        return atoms
    }

    /// Bondi van der Waals radii, in angstroms.
    static func radius(of element: String) -> Float {
        switch element {
        case "H": 1.20
        case "C": 1.70
        case "N": 1.55
        case "O": 1.52
        case "P": 1.80
        case "S": 1.80
        case "MG": 1.73
        case "ZN": 1.39
        case "FE": 2.00
        default: 1.70
        }
    }

    /// CPK, which is what a structural biologist expects to see.
    static func colour(of element: String) -> SIMD3<Float> {
        switch element {
        case "C": [0.35, 0.35, 0.38]
        case "N": [0.19, 0.31, 0.97]
        case "O": [0.94, 0.16, 0.16]
        case "S": [1.00, 0.78, 0.20]
        case "P": [1.00, 0.50, 0.00]
        case "H": [0.92, 0.92, 0.92]
        case "MG": [0.16, 0.55, 0.16]
        case "ZN", "FE": [0.65, 0.45, 0.20]
        default: [0.75, 0.45, 0.75]
        }
    }
}
