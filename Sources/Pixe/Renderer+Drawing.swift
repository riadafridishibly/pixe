import MetalKit
import simd

extension Renderer {
    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = SIMD2(Float(size.width), Float(size.height))

        backingScaleFactor = view.window?.backingScaleFactor ?? 2.0
        let pointWidth = Float(size.width) / Float(backingScaleFactor)
        let pointHeight = Float(size.height) / Float(backingScaleFactor)
        gridLayout.viewportWidth = pointWidth
        gridLayout.viewportHeight = pointHeight
        gridLayout.clampScroll()
    }

    func draw(in view: MTKView) {
        switch mode {
        case .image:
            drawImage(in: view)
        case .thumbnail:
            drawThumbnailGrid(in: view)
        }
    }

    // MARK: - Image Drawing

    private func drawImage(in view: MTKView) {
        guard let currentTex = gifAnimator?.currentTexture ?? currentTexture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        if (config.strip || swipeTemporaryStrip) && scale <= 1.0 && rotationSteps == 0 && imageList.count > 1 {
            drawImageStrip(encoder: encoder, currentTexture: currentTex)
        } else {
            var uniforms = Uniforms(transform: buildTransformMatrix())
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(currentTex, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Chrome: navigation buttons
        if chromeNavButtonAlpha > 0.01 {
            drawNavButtons(encoder: encoder)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func drawImageStrip(encoder: MTLRenderCommandEncoder, currentTexture: MTLTexture) {
        let count = imageList.count
        let currentIdx = imageList.currentIndex
        let n = 3 // max neighbors on each side
        let slots = 2 * n + 1 // total slots: [-n...n] mapped to [0...2n]
        let gap = stripGapNDC

        // Precompute per-slot data using arrays indexed by (r + n)
        var aspects = [Float](repeating: 1.0, count: slots)
        var widths = [Float](repeating: 0, count: slots)
        var indices = [Int](repeating: 0, count: slots)
        for r in -n...n {
            let idx = ((currentIdx + r) % count + count) % count
            let s = r + n
            indices[s] = idx
            aspects[s] = r == 0 ? imageAspect : aspectForIndex(idx)
            widths[s] = ndcWidth(forAspect: aspects[s])
        }

        // Compute center positions by accumulating widths outward from center
        var centers = [Float](repeating: 0, count: slots)
        centers[n] = stripOffset
        for r in 1...n {
            centers[n + r] = centers[n + r - 1] + widths[n + r - 1] / 2.0 + gap + widths[n + r] / 2.0
            centers[n - r] = centers[n - r + 1] - widths[n - r + 1] / 2.0 - gap - widths[n - r] / 2.0
        }

        for r in -n...n {
            let s = r + n
            let centerX = centers[s]
            let w = widths[s]
            if centerX + w / 2.0 < -1.0 || centerX - w / 2.0 > 1.0 { continue }

            let idx = indices[s]
            // Avoid drawing duplicates when count is small
            if count <= n * 2 && r != 0 {
                let firstR = ((idx - currentIdx) % count + count) % count
                let canonR = firstR <= count / 2 ? firstR : firstR - count
                if canonR != r { continue }
            }

            var texture: MTLTexture
            if r == 0 {
                texture = currentTexture
            } else {
                let path = imageList.allPaths[idx]
                if let entry = prefetchCache[path] {
                    texture = entry.texture
                } else if let thumbTex = thumbnailCache?.texture(at: idx) {
                    texture = thumbTex
                } else {
                    continue
                }
            }

            var uniforms = Uniforms(transform: buildStripImageTransform(aspect: aspects[s], offsetX: centerX))
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    // MARK: - Thumbnail Grid Drawing

    private func drawThumbnailGrid(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let cache = thumbnailCache else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Sync aspect ratios from cache so layout reflects actual image proportions
        gridLayout.updateAspects(from: cache.aspects)

        let visible = gridLayout.visibleRange()
        let animTime = Float(CACurrentMediaTime() - selectionAnimationStart)

        // Draw visible thumbnails — collect uniforms into a shared buffer
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        // Gather visible items that have textures
        var visibleItems: [(index: Int, texture: MTLTexture)] = []
        for i in visible {
            let texture: MTLTexture
            if i == gridLayout.selectedIndex, let animTex = thumbnailGIFAnimator?.currentTexture {
                texture = animTex
            } else {
                guard let t = cache.texture(at: i) else { continue }
                texture = t
            }
            visibleItems.append((i, texture))
        }

        if !visibleItems.isEmpty {
            let uniformStride = MemoryLayout<Uniforms>.stride
            let needed = visibleItems.count

            // Prevent CPU from rewriting a uniform buffer the GPU is still reading.
            thumbnailInFlightSemaphore.wait()

            if needed > thumbnailUniformCapacity || thumbnailUniformBuffers.count != thumbnailFramesInFlight {
                let newCapacity = max(needed, thumbnailUniformCapacity * 2, 64)
                var newBuffers: [MTLBuffer] = []
                newBuffers.reserveCapacity(thumbnailFramesInFlight)
                for _ in 0 ..< thumbnailFramesInFlight {
                    guard let buffer = device.makeBuffer(length: uniformStride * newCapacity, options: .storageModeShared) else {
                        newBuffers.removeAll()
                        break
                    }
                    newBuffers.append(buffer)
                }
                if newBuffers.count == thumbnailFramesInFlight {
                    thumbnailUniformBuffers = newBuffers
                    thumbnailUniformCapacity = newCapacity
                } else {
                    thumbnailInFlightSemaphore.signal()
                    encoder.endEncoding()
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                    return
                }
            }

            let frameSlot = thumbnailFrameSlot
            thumbnailFrameSlot = (thumbnailFrameSlot + 1) % thumbnailFramesInFlight
            let buffer = thumbnailUniformBuffers[frameSlot]
            commandBuffer.addCompletedHandler { [thumbnailInFlightSemaphore] _ in
                thumbnailInFlightSemaphore.signal()
            }

            let ptr = buffer.contents().bindMemory(to: Uniforms.self, capacity: needed)
            for (slot, item) in visibleItems.enumerated() {
                ptr[slot] = Uniforms(transform: gridLayout.transformForIndex(item.index))
            }

            let selIdx = gridLayout.selectedIndex
            var selectedSlot: Int? = nil

            // Draw non-selected thumbnails with normal pipeline
            for (slot, item) in visibleItems.enumerated() {
                if item.index == selIdx {
                    selectedSlot = slot
                    continue
                }
                encoder.setVertexBuffer(buffer, offset: uniformStride * slot, index: 1)
                encoder.setFragmentTexture(item.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }

            // Draw selected thumbnail with morph effect
            if let slot = selectedSlot {
                encoder.setRenderPipelineState(morphThumbnailPipelineState)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(buffer, offset: uniformStride * slot, index: 1)
                encoder.setFragmentTexture(visibleItems[slot].texture, index: 0)
                var morph = MorphUniforms(time: animTime, effectType: morphEffect.rawValue)
                encoder.setFragmentBytes(&morph, length: MemoryLayout<MorphUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        // Draw animated selection border on top of thumbnails
        if visible.contains(gridLayout.selectedIndex) {
            let selIdx = gridLayout.selectedIndex
            let (_, _, itemW, itemH) = gridLayout.itemRect(at: selIdx)
            let borderWidth: Float = 6.0

            encoder.setRenderPipelineState(selectionPipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            var transform = Uniforms(transform: gridLayout.transformForIndex(selIdx))
            encoder.setVertexBytes(&transform, length: MemoryLayout<Uniforms>.stride, index: 1)

            let fireInset: Float = selectionEffect == .fire ? 20.0 : 0.0
            var selUniforms = SelectionUniforms(
                time: animTime,
                rectSize: SIMD2<Float>(itemW, itemH),
                borderWidth: borderWidth,
                effectType: selectionEffect.rawValue,
                innerOffset: SIMD2<Float>(fireInset, fireInset),
                innerSize: SIMD2<Float>(itemW - fireInset * 2, itemH - fireInset * 2)
            )
            encoder.setFragmentBytes(&selUniforms, length: MemoryLayout<SelectionUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Chrome: hover highlight
        if let inputHandler = (view as? MetalImageView)?.inputHandler,
           let hoverIdx = inputHandler.hoveredIndex,
           hoverIdx != gridLayout.selectedIndex,
           visible.contains(hoverIdx) {
            drawHoverHighlight(encoder: encoder, index: hoverIdx)
        }

        // Chrome: scrollbar
        if chromeScrollbarAlpha > 0.01 {
            drawScrollbar(encoder: encoder)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Trigger background loading for prefetch range
        let prefetch = gridLayout.prefetchRange()
        cache.ensureLoaded(indices: prefetch, pinnedIndices: visible, paths: imageList.allPaths) { [weak self] in
            if let view = self?.window?.contentView as? MTKView {
                view.needsDisplay = true
            }
        }
    }

    // MARK: - Chrome Drawing

    private func drawHoverHighlight(encoder: MTLRenderCommandEncoder, index: Int) {
        encoder.setRenderPipelineState(flatColorPipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        var transform = Uniforms(transform: gridLayout.transformForIndex(index))
        encoder.setVertexBytes(&transform, length: MemoryLayout<Uniforms>.stride, index: 1)

        var color = ColorUniforms(color: SIMD4<Float>(1, 1, 1, 0.08))
        encoder.setFragmentBytes(&color, length: MemoryLayout<ColorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawScrollbar(encoder: MTLRenderCommandEncoder) {
        let vpW = gridLayout.viewportWidth
        let vpH = gridLayout.viewportHeight
        let visFrac = gridLayout.visibleFraction
        guard visFrac < 1.0 else { return }  // No scrollbar if everything fits

        let scrollFrac = gridLayout.scrollFraction
        let barWidth: Float = 6.0
        let barPadding: Float = 4.0
        let thumbHeight = max(20.0, vpH * visFrac)
        let trackHeight = vpH - barPadding * 2
        let thumbY = barPadding + scrollFrac * (trackHeight - thumbHeight)

        // Convert to NDC
        let ndcX = ((vpW - barPadding - barWidth / 2.0) / vpW) * 2.0 - 1.0
        let ndcY = 1.0 - ((thumbY + thumbHeight / 2.0) / vpH) * 2.0
        let ndcW = barWidth / vpW
        let ndcH = thumbHeight / vpH

        encoder.setRenderPipelineState(flatColorPipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let scrollTransform = simd_float4x4(
            SIMD4<Float>(ndcW, 0, 0, 0),
            SIMD4<Float>(0, ndcH, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndcX, ndcY, 0, 1)
        )
        var transform = Uniforms(transform: scrollTransform)
        encoder.setVertexBytes(&transform, length: MemoryLayout<Uniforms>.stride, index: 1)

        var color = ColorUniforms(color: SIMD4<Float>(1, 1, 1, chromeScrollbarAlpha))
        encoder.setFragmentBytes(&color, length: MemoryLayout<ColorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawNavButtons(encoder: MTLRenderCommandEncoder) {
        guard let inputHandler = (window?.contentView as? MetalImageView)?.inputHandler else { return }

        encoder.setRenderPipelineState(navZonePipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // Full-height zones covering the left/right 15% of the viewport
        let zoneWidth: Float = 0.15  // fraction of viewport — matches click edge zone

        if inputHandler.mouseInLeftEdge {
            drawNavZone(encoder: encoder, ndcLeft: -1.0, ndcWidth: zoneWidth * 2.0, pointsLeft: true)
        }
        if inputHandler.mouseInRightEdge {
            drawNavZone(encoder: encoder, ndcLeft: 1.0 - zoneWidth * 2.0, ndcWidth: zoneWidth * 2.0, pointsLeft: false)
        }
    }

    private func drawNavZone(encoder: MTLRenderCommandEncoder,
                             ndcLeft: Float, ndcWidth: Float, pointsLeft: Bool) {
        // Full-height quad positioned at the edge
        let ndcCenterX = ndcLeft + ndcWidth / 2.0
        let transform = simd_float4x4(
            SIMD4<Float>(ndcWidth / 2.0, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),   // full height in NDC
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndcCenterX, 0, 0, 1)
        )
        var uniforms = Uniforms(transform: transform)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        let vpW = gridLayout.viewportWidth
        let vpH = gridLayout.viewportHeight
        let zoneWidthPts = vpW * 0.15  // matches the 15% edge zone
        let aspect = zoneWidthPts / vpH

        var nav = NavZoneUniforms(alpha: chromeNavButtonAlpha, pointsLeft: pointsLeft ? 1 : 0, aspectRatio: aspect)
        encoder.setFragmentBytes(&nav, length: MemoryLayout<NavZoneUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
