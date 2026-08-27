//  ImpostorRenderer.swift
//  BoffinRenderer
//
//  A Metal sphere-impostor renderer, and the harness to time it.
//
//  Phase 12's plan says "benchmark against Mol\\* rather than assumed to beat
//  it", so this is built to be MEASURED first and displayed second. It renders
//  offscreen, which means the numbers can be taken without a window, a device
//  or a person watching a frame counter.
//
//  What it is not: a replacement for Mol\\*. It draws atoms as spheres and
//  nothing else -- no cartoon, no surface, no selection, no labels. Those are
//  most of what the structure tab actually shows, and the point of the spike
//  is to find out whether the speed would be worth rebuilding them.

import BoffinStructure
import Foundation
import Metal
import simd

public struct RendererAtom {
    public var position: SIMD3<Float>
    public var radius: Float
    public var colour: SIMD3<Float>

    public init(position: SIMD3<Float>, radius: Float, colour: SIMD3<Float>) {
        self.position = position
        self.radius = radius
        self.colour = colour
    }
}

public enum RendererError: Error, CustomStringConvertible {
    case noDevice
    case shaderCompilation(String)
    case pipeline(String)
    case resources

    public var description: String {
        switch self {
        case .noDevice: "no Metal device on this machine"
        case .shaderCompilation(let detail): "shader compilation failed: \(detail)"
        case .pipeline(let detail): "pipeline creation failed: \(detail)"
        case .resources: "could not allocate render resources"
        }
    }
}

public final class ImpostorRenderer {

    /// Matches the `Atom` struct in the shader. Sixteen bytes of position and
    /// radius, sixteen of colour and padding: laid out so the GPU reads it
    /// without a stride fixup, which the packed_float3 in the shader relies on.
    struct Atom {
        var position: SIMD3<Float>
        var radius: Float
        var colour: SIMD3<Float>
        var pad: Float = 0
    }

    struct Uniforms {
        var modelViewProjection: simd_float4x4
        var modelView: simd_float4x4
        var projection: simd_float4x4
        var lightDirection: SIMD3<Float>
        var pad: Float = 0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.resources }
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ImpostorShaders.source, options: nil)
        } catch {
            throw RendererError.shaderCompilation(String(describing: error))
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "impostorVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "impostorFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RendererError.pipeline(String(describing: error))
        }

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else {
            throw RendererError.resources
        }
        depthState = state
    }

    /// Render one frame offscreen and wait for it, returning the GPU time.
    ///
    /// Waiting is the point: an unwaited command buffer measures how long it
    /// takes to ASK for a frame, which is microseconds regardless of how much
    /// work was asked for, and would make any structure look fast.
    @discardableResult
    public func renderFrame(
        atoms: [RendererAtom], width: Int = 1024, height: Int = 1024
    ) throws -> TimeInterval {
        guard !atoms.isEmpty else { return 0 }

        let packed = atoms.map {
            Atom(position: $0.position, radius: $0.radius, colour: $0.colour)
        }
        guard
            let atomBuffer = device.makeBuffer(
                bytes: packed, length: MemoryLayout<Atom>.stride * packed.count,
                options: .storageModeShared)
        else { throw RendererError.resources }

        let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colourDescriptor.usage = [.renderTarget]
        colourDescriptor.storageMode = .private
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private

        guard let colour = device.makeTexture(descriptor: colourDescriptor),
            let depth = device.makeTexture(descriptor: depthDescriptor)
        else { throw RendererError.resources }

        var uniforms = Self.uniforms(for: atoms, width: width, height: height)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.11, green: 0.14, blue: 0.29, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0

        guard let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { throw RendererError.resources }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(atomBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        // One quad, instanced once per atom. The alternative, a vertex buffer
        // holding four vertices per atom, would be four times the bandwidth
        // for identical geometry.
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4,
            instanceCount: atoms.count)
        encoder.endEncoding()

        let start = Date()
        buffer.commit()
        buffer.waitUntilCompleted()
        return Date().timeIntervalSince(start)
    }

    static func uniforms(
        for atoms: [RendererAtom], width: Int, height: Int
    ) -> Uniforms {
        var low = atoms[0].position
        var high = atoms[0].position
        for atom in atoms {
            low = simd_min(low, atom.position)
            high = simd_max(high, atom.position)
        }
        let centre = (low + high) / 2
        let extent = simd_length(high - low)
        let distance = max(extent * 1.5, 1)

        let eye = centre + SIMD3<Float>(0, 0, distance)
        let view = look(at: centre, from: eye)
        let aspect = Float(width) / Float(height)
        let projection = perspective(
            fieldOfView: .pi / 4, aspect: aspect,
            near: max(distance - extent, 0.1), far: distance + extent * 2)

        return Uniforms(
            modelViewProjection: projection * view,
            modelView: view,
            projection: projection,
            lightDirection: SIMD3<Float>(0.4, 0.6, 1.0))
    }

    static func look(at centre: SIMD3<Float>, from eye: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(centre - eye)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        let up = simd_cross(forward, right)
        return simd_float4x4(
            SIMD4<Float>(right.x, up.x, -forward.x, 0),
            SIMD4<Float>(right.y, up.y, -forward.y, 0),
            SIMD4<Float>(right.z, up.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1))
    }

    static func perspective(
        fieldOfView: Float, aspect: Float, near: Float, far: Float
    ) -> simd_float4x4 {
        let y = 1 / tan(fieldOfView * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0))
    }
}
