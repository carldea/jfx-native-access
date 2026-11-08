/*

Copyright 2026 Carl Dea

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://apache.org

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and limitations under the License.
*/
import Cocoa
import Metal
import QuartzCore
import simd

// --- SHADERS ---
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

// 2D Vertex Shader
vertex VertexOut vertexShader2D(uint vertexID [[vertex_id]]) {
    float2 positions[3] = { float2(0.0, 0.5), float2(-0.5, -0.5), float2(0.5, -0.5) };
    float4 colors[3] = { float4(1,0,0,1), float4(0,1,0,1), float4(0,0,1,1) };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.color = colors[vertexID];
    return out;
}

// 3D Vertex Shader
struct Vertex3DIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

vertex VertexOut vertexShader3D(Vertex3DIn in [[stage_in]],
                               constant Uniforms& uniforms [[buffer(1)]]) {
    VertexOut out;
    out.position = uniforms.modelViewProjectionMatrix * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]]) {
    return in.color;
}
"""

// --- STRUCTS ---
/// Same memory layout as the C `Vertex3D` (simd_float3 + simd_float4): stride 32, color at offset 16.
private struct Vertex3D {
    var position: SIMD3<Float>
    var color: SIMD4<Float>

    init(_ p: (Float, Float, Float), _ c: (Float, Float, Float, Float)) {
        position = SIMD3(p.0, p.1, p.2)
        color = SIMD4(c.0, c.1, c.2, c.3)
    }
}

// --- SIMD MATRIX MATH HELPERS ---
private func matrixRotation(_ rx: Float, _ ry: Float) -> simd_float4x4 {
    let cx = cos(rx), sx = sin(rx)
    let cy = cos(ry), sy = sin(ry)

    let rotX = simd_float4x4(columns: (
        SIMD4(1, 0, 0, 0),
        SIMD4(0, cx, sx, 0),
        SIMD4(0, -sx, cx, 0),
        SIMD4(0, 0, 0, 1)
    ))
    let rotY = simd_float4x4(columns: (
        SIMD4(cy, 0, -sy, 0),
        SIMD4(0, 1, 0, 0),
        SIMD4(sy, 0, cy, 0),
        SIMD4(0, 0, 0, 1)
    ))
    return rotX * rotY
}

private func matrixPerspective(fovRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let ys = 1.0 / tan(fovRadians * 0.5)
    let xs = ys / aspect
    let zs = farZ / (nearZ - farZ)
    let wz = (nearZ * farZ) / (nearZ - farZ)

    return simd_float4x4(columns: (
        SIMD4(xs, 0, 0, 0),
        SIMD4(0, ys, 0, 0),
        SIMD4(0, 0, zs, -1),
        SIMD4(0, 0, wz, 0)
    ))
}

/// Runs `body` on the main thread (synchronously), replacing `execute_on_main_thread`.
private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}

// --- RENDERER ---
@MainActor
private final class MetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState2D: MTLRenderPipelineState
    let pipelineState3D: MTLRenderPipelineState
    let vertexBuffer3D: MTLBuffer
    let vertexCount3D: Int
    let metalLayer: CAMetalLayer
    let parentWindow: NSWindow   // owned by JavaFX/Glass; retained here so it cannot dangle
    let childWindow: NSWindow
    let metalView: NSView

    var animationPhase: Float = 0
    var globalAlpha: Float = 0.4
    var renderMode: Int32 = 0 // 0 = 2D, 1 = 3D
    var rotationX: Float = 0
    var rotationY: Float = 0

    init(parentWindow: NSWindow) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw RendererError("No Metal device available")
        }
        self.device = device
        self.commandQueue = queue
        self.parentWindow = parentWindow

        // Shaders & pipelines
        let library = try device.makeLibrary(source: shaderSource, options: nil)

        // Pipeline 1: 2D Stretching Triangle
        let pipeDesc2D = MTLRenderPipelineDescriptor()
        pipeDesc2D.vertexFunction = library.makeFunction(name: "vertexShader2D")
        pipeDesc2D.fragmentFunction = library.makeFunction(name: "fragmentShader")
        pipeDesc2D.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState2D = try device.makeRenderPipelineState(descriptor: pipeDesc2D)

        // Pipeline 2: 3D Interactive Prism/Pyramid
        let vDesc3D = MTLVertexDescriptor()
        vDesc3D.attributes[0].format = .float3
        vDesc3D.attributes[0].offset = MemoryLayout<Vertex3D>.offset(of: \.position)!
        vDesc3D.attributes[0].bufferIndex = 0
        vDesc3D.attributes[1].format = .float4
        vDesc3D.attributes[1].offset = MemoryLayout<Vertex3D>.offset(of: \.color)!
        vDesc3D.attributes[1].bufferIndex = 0
        vDesc3D.layouts[0].stride = MemoryLayout<Vertex3D>.stride

        let pipeDesc3D = MTLRenderPipelineDescriptor()
        pipeDesc3D.vertexFunction = library.makeFunction(name: "vertexShader3D")
        pipeDesc3D.fragmentFunction = library.makeFunction(name: "fragmentShader")
        pipeDesc3D.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeDesc3D.vertexDescriptor = vDesc3D
        pipelineState3D = try device.makeRenderPipelineState(descriptor: pipeDesc3D)

        // 3D Geometry Data (a clean 3D triangular prism)
        let geometry: [Vertex3D] = [
            // Front Face triangle
            .init(( 0.0,  0.5, -0.5), (1, 0, 0, 1)), .init((-0.5, -0.5, -0.5), (0, 1, 0, 1)), .init(( 0.5, -0.5, -0.5), (0, 0, 1, 1)),
            // Back Face triangle
            .init(( 0.0,  0.5,  0.5), (1, 1, 0, 1)), .init(( 0.5, -0.5,  0.5), (0, 1, 1, 1)), .init((-0.5, -0.5,  0.5), (1, 0, 1, 1)),
            // Side Panel 1
            .init(( 0.0,  0.5, -0.5), (1, 0, 0, 1)), .init(( 0.5, -0.5, -0.5), (0, 0, 1, 1)), .init(( 0.0,  0.5,  0.5), (1, 1, 0, 1)),
            .init(( 0.5, -0.5, -0.5), (0, 0, 1, 1)), .init(( 0.5, -0.5,  0.5), (0, 1, 1, 1)), .init(( 0.0,  0.5,  0.5), (1, 1, 0, 1)),
            // Side Panel 2
            .init(( 0.0,  0.5,  0.5), (1, 1, 0, 1)), .init((-0.5, -0.5,  0.5), (1, 0, 1, 1)), .init(( 0.0,  0.5, -0.5), (1, 0, 0, 1)),
            .init((-0.5, -0.5,  0.5), (1, 0, 1, 1)), .init((-0.5, -0.5, -0.5), (0, 1, 0, 1)), .init(( 0.0,  0.5, -0.5), (1, 0, 0, 1)),
            // Bottom Panel
            .init((-0.5, -0.5, -0.5), (0, 1, 0, 1)), .init((-0.5, -0.5,  0.5), (1, 0, 1, 1)), .init(( 0.5, -0.5, -0.5), (0, 0, 1, 1)),
            .init(( 0.5, -0.5, -0.5), (0, 0, 1, 1)), .init((-0.5, -0.5,  0.5), (1, 0, 1, 1)), .init(( 0.5, -0.5,  0.5), (0, 1, 1, 1)),
        ]
        guard let buffer = geometry.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else {
            throw RendererError("Could not allocate vertex buffer")
        }
        vertexBuffer3D = buffer
        vertexCount3D = geometry.count

        // Child window + Metal layer
        childWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        childWindow.isReleasedWhenClosed = false
        childWindow.isOpaque = false
        childWindow.backgroundColor = .clear
        childWindow.ignoresMouseEvents = true // Pass inputs to JavaFX

        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false

        metalView = NSView(frame: .zero)
        metalView.wantsLayer = true
        metalView.layer = metalLayer
        childWindow.contentView = metalView
        parentWindow.addChildWindow(childWindow, ordered: .above)
    }

    func updateBounds(x: Double, y: Double, width: Double, height: Double, clipMode: Int32) {
        let parentFrame = parentWindow.contentRect(forFrameRect: parentWindow.frame)
        let cocoaX = parentFrame.origin.x + x
        let cocoaY = parentFrame.origin.y + parentFrame.size.height - (y + height)

        childWindow.setFrame(NSRect(x: cocoaX, y: cocoaY, width: width, height: height), display: true)
        metalLayer.frame = metalView.bounds

        if clipMode == 1 {
            metalLayer.cornerRadius = 0
            metalLayer.masksToBounds = false
            let maskLayer = CAShapeLayer()
            maskLayer.path = CGPath(ellipseIn: metalLayer.bounds, transform: nil)
            metalLayer.mask = maskLayer
        } else {
            metalLayer.mask = nil
            metalLayer.cornerRadius = 12
            metalLayer.masksToBounds = true
            metalLayer.maskedCorners = .layerMaxXMinYCorner
        }
    }

    func renderFrame() {
        autoreleasepool {
            guard let drawable = metalLayer.nextDrawable(),
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            animationPhase += 0.02
            let redPulse = 0.15 + Double(sin(animationPhase)) * 0.05
            let bluePulse = 0.25 + Double(cos(animationPhase)) * 0.05

            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = drawable.texture
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: redPulse, green: 0.1, blue: bluePulse,
                                                                    alpha: Double(globalAlpha))
            passDesc.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

            if renderMode == 1 {
                // --- 3D INTERACTIVE PRISM DRAW ---
                encoder.setRenderPipelineState(pipelineState3D)
                encoder.setVertexBuffer(vertexBuffer3D, offset: 0, index: 0)

                let modelMatrix = matrixRotation(rotationX, rotationY)
                let size = metalLayer.bounds.size
                let aspect: Float = size.height > 0 ? Float(size.width / size.height) : 1
                let projectionMatrix = matrixPerspective(fovRadians: 60 * .pi / 180, aspect: aspect,
                                                         nearZ: 0.1, farZ: 10)
                var viewMatrix = matrix_identity_float4x4
                viewMatrix.columns.3.z = -2

                // MVP = Projection * View * Model
                var mvp = projectionMatrix * viewMatrix * modelMatrix
                encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount3D)
            } else {
                // --- 2D STRETCHING TRIANGLE DRAW ---
                encoder.setRenderPipelineState(pipelineState2D)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    func tearDown() {
        parentWindow.removeChildWindow(childWindow)
        childWindow.orderOut(nil)
        childWindow.close()
    }
}

private struct RendererError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// --- C ABI (called from Java through the FFM API) ---
// Pointers travel as bit patterns (Int) across the main-thread hop so the closures stay Sendable.

@MainActor
private func renderer(_ bits: Int) -> MetalRenderer {
    Unmanaged<MetalRenderer>.fromOpaque(UnsafeRawPointer(bitPattern: bits)!).takeUnretainedValue()
}

@c(init_metal_renderer)
public func initMetalRenderer(_ nsWindowPtr: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let nsWindowPtr else { return nil }
    let windowBits = Int(bitPattern: nsWindowPtr)
    let rendererBits: Int = onMain {
        let parent = Unmanaged<NSWindow>.fromOpaque(UnsafeRawPointer(bitPattern: windowBits)!).takeUnretainedValue()
        do {
            let r = try MetalRenderer(parentWindow: parent)
            return Int(bitPattern: Unmanaged.passRetained(r).toOpaque())
        } catch {
            NSLog("Metal renderer initialisation failed: %@", String(describing: error))
            return 0
        }
    }
    return UnsafeMutableRawPointer(bitPattern: rendererBits)
}

@c(destroy_metal_renderer)
public func destroyMetalRenderer(_ rendererPtr: UnsafeMutableRawPointer?) {
    guard let rendererPtr else { return }
    let bits = Int(bitPattern: rendererPtr)
    onMain {
        let unmanaged = Unmanaged<MetalRenderer>.fromOpaque(UnsafeRawPointer(bitPattern: bits)!)
        unmanaged.takeUnretainedValue().tearDown()
        unmanaged.release()
    }
}

@c(update_renderer_bounds)
public func updateRendererBounds(_ rendererPtr: UnsafeMutableRawPointer?, _ x: Double, _ y: Double,
                                 _ width: Double, _ height: Double, _ clipMode: Int32) {
    guard let rendererPtr else { return }
    let bits = Int(bitPattern: rendererPtr)
    onMain { renderer(bits).updateBounds(x: x, y: y, width: width, height: height, clipMode: clipMode) }
}

@c(set_render_mode)
public func setRenderMode(_ rendererPtr: UnsafeMutableRawPointer?, _ mode: Int32) {
    guard let rendererPtr else { return }
    let bits = Int(bitPattern: rendererPtr)
    onMain { renderer(bits).renderMode = mode }
}

@c(update_rotation)
public func updateRotation(_ rendererPtr: UnsafeMutableRawPointer?, _ deltaX: Float, _ deltaY: Float) {
    guard let rendererPtr else { return }
    let bits = Int(bitPattern: rendererPtr)
    onMain {
        let r = renderer(bits)
        r.rotationY += deltaX * 0.01 // Horizontal drag rotates around Y axis
        r.rotationX += deltaY * 0.01 // Vertical drag rotates around X axis
    }
}

@c(set_renderer_alpha)
public func setRendererAlpha(_ rendererPtr: UnsafeMutableRawPointer?, _ alpha: Float) {
    guard let rendererPtr else { return }
    let bits = Int(bitPattern: rendererPtr)
    onMain { renderer(bits).globalAlpha = alpha }
}

@c(render_frame)
public func renderFrame(_ rendererPtr: UnsafeMutableRawPointer?) {
    guard let rendererPtr else { return }
    let bits = Int(bitPattern: rendererPtr)
    onMain { renderer(bits).renderFrame() }
}
