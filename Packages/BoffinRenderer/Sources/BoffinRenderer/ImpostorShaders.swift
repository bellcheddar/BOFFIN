//  ImpostorShaders.swift
//  BoffinRenderer
//
//  The Metal source for sphere impostors, compiled at run time.
//
//  Impostors rather than sphere meshes: a tessellated sphere costs hundreds of
//  triangles per atom, and a ribosome has enough atoms that the triangle count
//  alone would sink it. An impostor is ONE quad per atom, with the fragment
//  shader working out where the sphere surface would be and writing the depth
//  it would have had. The silhouette is exact at every zoom level, which a
//  mesh's never is.
//
//  Compiled from source at run time rather than shipped as a metallib. That
//  costs a few tens of milliseconds once, and it keeps the spike free of build
//  system arrangements that would have to be undone if the answer turns out to
//  be "keep Mol*".

enum ImpostorShaders {

    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Atom {
            packed_float3 position;
            float radius;
            packed_float3 colour;
            float pad;
        };

        struct Uniforms {
            float4x4 modelViewProjection;
            float4x4 modelView;
            float4x4 projection;
            packed_float3 lightDirection;
            float pad;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 offset;
            float3 colour;
            float3 centreEye;
            float radius;
        };

        // One quad per atom, four vertices, drawn instanced. The quad is built in
        // EYE space so it always faces the camera: billboarding by rotating in
        // world space would need a matrix per atom and would still be wrong under
        // perspective at the edges of the frame.
        vertex VertexOut impostorVertex(uint vertexID [[vertex_id]],
                                        uint instanceID [[instance_id]],
                                        constant Atom *atoms [[buffer(0)]],
                                        constant Uniforms &uniforms [[buffer(1)]])
        {
            const float2 corners[4] = {
                float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
            };
            float2 corner = corners[vertexID];
            Atom atom = atoms[instanceID];

            float4 centreEye = uniforms.modelView * float4(atom.position, 1.0);
            // The quad is widened slightly. A quad exactly the sphere's diameter
            // clips the silhouette under perspective, because the visible outline
            // of a sphere is larger than its diameter when it is near the camera.
            float scale = atom.radius * 1.15;
            float4 cornerEye = centreEye + float4(corner * scale, 0.0, 0.0);

            VertexOut out;
            out.position = uniforms.projection * cornerEye;
            out.offset = corner * 1.15;
            out.colour = atom.colour;
            out.centreEye = centreEye.xyz;
            out.radius = atom.radius;
            return out;
        }

        struct FragmentOut {
            float4 colour [[color(0)]];
            float depth [[depth(any)]];
        };

        fragment FragmentOut impostorFragment(VertexOut in [[stage_in]],
                                              constant Uniforms &uniforms [[buffer(1)]])
        {
            float radiusSquared = dot(in.offset, in.offset);
            // Outside the sphere's circle, the quad is not the sphere. Discarding
            // is what makes a square into a sphere; without it every atom is a
            // coloured tile.
            if (radiusSquared > 1.0) { discard_fragment(); }

            float z = sqrt(1.0 - radiusSquared);
            float3 normal = float3(in.offset, z);
            float3 surfaceEye = in.centreEye + normal * in.radius;

            // The depth the SPHERE would have had, not the quad's. Without this
            // two impostors interpenetrate as flat cards and the scene looks like
            // stickers rather than atoms.
            float4 clip = uniforms.projection * float4(surfaceEye, 1.0);
            FragmentOut out;
            out.depth = clip.z / clip.w;

            float lambert = max(dot(normalize(normal), normalize(uniforms.lightDirection)), 0.0);
            float ambient = 0.25;
            out.colour = float4(in.colour * (ambient + 0.75 * lambert), 1.0);
            return out;
        }
        """
}
