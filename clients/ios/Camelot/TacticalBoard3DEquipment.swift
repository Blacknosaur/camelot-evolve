import SceneKit
import UIKit
import simd

/// Training equipment and staff figures for the 3D board. Local units are metres at figure
/// scale 1 with +x as the front, like the players; geometries and materials are shared.
extension TacticalBoard3DScene {
    static let coachColorHex = "3B4452"
    static let refereeColorHex = "17181B"
    static let refereeAccentHex = "F2D640"

    // MARK: Shared parts

    func darkMaterial() -> SCNMaterial {
        material("equipment-dark") {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(white: 0.12, alpha: 1)
            m.roughness.contents = 0.55
            m.metalness.contents = 0.2
            return m
        }
    }

    func netMaterial(repeatX: Float, repeatY: Float) -> SCNMaterial {
        material("net-\(repeatX)-\(repeatY)") {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = Board3DTextures.shared.net()
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(repeatX, repeatY, 1)
            m.transparency = 0.5
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            return m
        }
    }

    /// A round bar between two points.
    func tube(_ from: SIMD3<Float>, _ to: SIMD3<Float>, radius: CGFloat, material: SCNMaterial, into parent: SCNNode) {
        let length = simd_distance(from, to)
        guard length > 1e-4 else { return }
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        cylinder.radialSegmentCount = 10
        cylinder.firstMaterial = material
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (from + to) / 2
        node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(to - from))
        parent.addChildNode(node)
    }

    /// Translucent net made of textured quads (each quad is a, b, c, d in order).
    func net(_ quads: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)], material: SCNMaterial) -> SCNNode {
        var positions: [SCNVector3] = []
        var uvs: [CGPoint] = []
        for (a, b, c, d) in quads {
            for (p, uv) in [(a, CGPoint(x: 0, y: 0)), (b, CGPoint(x: 1, y: 0)), (c, CGPoint(x: 1, y: 1)), (a, CGPoint(x: 0, y: 0)), (c, CGPoint(x: 1, y: 1)), (d, CGPoint(x: 0, y: 1))] {
                positions.append(SCNVector3(p.x, p.y, p.z)); uvs.append(uv)
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(textureCoordinates: uvs)],
                                   elements: [SCNGeometryElement(indices: (0..<UInt32(positions.count)).map { $0 }, primitiveType: .triangles)])
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.castsShadow = false
        return node
    }

    // MARK: Cones and markers

    func tallCone(colorHex: String) -> SCNNode {
        let node = SCNNode()
        let cone = SCNCone(topRadius: 0.018, bottomRadius: 0.13, height: 0.72)
        cone.radialSegmentCount = 20
        cone.firstMaterial = solidMaterial(colorHex, roughness: 0.35)
        let body = SCNNode(geometry: cone)
        body.position.y = 0.4
        node.addChildNode(body)
        let base = SCNBox(width: 0.34, height: 0.035, length: 0.34, chamferRadius: 0.04)
        base.firstMaterial = solidMaterial(colorHex, roughness: 0.7)
        let baseNode = SCNNode(geometry: base)
        baseNode.position.y = 0.018
        node.addChildNode(baseNode)
        // Reflective collar.
        let collar = SCNCylinder(radius: 0.075, height: 0.09)
        collar.radialSegmentCount = 20
        collar.firstMaterial = solidMaterial(BoardPalette.white, roughness: 0.25)
        let collarNode = SCNNode(geometry: collar)
        collarNode.position.y = 0.5
        node.addChildNode(collarNode)
        return node
    }

    /// Low saucer marker with a hollow top.
    func domeCone(colorHex: String) -> SCNNode {
        let saucer = SCNCone(topRadius: 0.06, bottomRadius: 0.19, height: 0.075)
        saucer.radialSegmentCount = 28
        saucer.firstMaterial = solidMaterial(colorHex, roughness: 0.45)
        let node = SCNNode(geometry: saucer)
        node.position.y = 0.038
        let top = SCNCylinder(radius: 0.045, height: 0.004)
        top.firstMaterial = darkMaterial()
        let hole = SCNNode(geometry: top)
        hole.position.y = 0.038
        node.addChildNode(hole)
        let holder = SCNNode()
        holder.addChildNode(node)
        return holder
    }

    /// Slalom pole on a weighted base.
    func slalomPole(colorHex: String) -> SCNNode {
        let node = SCNNode()
        let shaft = SCNCylinder(radius: 0.02, height: 1.7)
        shaft.radialSegmentCount = 12
        shaft.firstMaterial = solidMaterial(colorHex, roughness: 0.3)
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.position.y = 0.9
        node.addChildNode(shaftNode)
        let cap = SCNSphere(radius: 0.03)
        cap.segmentCount = 10
        cap.firstMaterial = solidMaterial(colorHex, roughness: 0.3)
        let capNode = SCNNode(geometry: cap)
        capNode.position.y = 1.75
        node.addChildNode(capNode)
        let base = SCNCylinder(radius: 0.16, height: 0.05)
        base.radialSegmentCount = 20
        base.firstMaterial = darkMaterial()
        let baseNode = SCNNode(geometry: base)
        baseNode.position.y = 0.025
        node.addChildNode(baseNode)
        return node
    }

    /// Mini hurdle: two uprights, a crossbar and flat feet, across the facing direction.
    func hurdle(colorHex: String) -> SCNNode {
        let node = SCNNode()
        let frame = solidMaterial(colorHex, roughness: 0.35)
        let half: Float = 0.3, height: Float = 0.3
        for z in [-half, half] {
            tube(SIMD3(0, 0.02, z), SIMD3(0, height, z), radius: 0.018, material: frame, into: node)
            tube(SIMD3(-0.12, 0.012, z), SIMD3(0.12, 0.012, z), radius: 0.014, material: frame, into: node)
        }
        tube(SIMD3(0, height, -half), SIMD3(0, height, half), radius: 0.022, material: frame, into: node)
        return node
    }

    /// Agility ladder along +x with `rungs` rungs 0.45 m apart, centred on the anchor.
    func ladder(colorHex: String, rungs: Int) -> SCNNode {
        let node = SCNNode()
        let spacing: Float = 0.45, width: Float = 0.5
        let length = spacing * Float(rungs)
        let strap = SCNBox(width: CGFloat(length), height: 0.012, length: 0.035, chamferRadius: 0.005)
        strap.firstMaterial = darkMaterial()
        for z in [-width / 2, width / 2] {
            let side = SCNNode(geometry: strap)
            side.simdPosition = SIMD3(0, 0.008, z)
            node.addChildNode(side)
        }
        let rung = SCNBox(width: 0.04, height: 0.02, length: CGFloat(width), chamferRadius: 0.008)
        rung.firstMaterial = solidMaterial(colorHex, roughness: 0.4)
        for index in 0...rungs {
            let rungNode = SCNNode(geometry: rung)
            rungNode.simdPosition = SIMD3(-length / 2 + spacing * Float(index), 0.012, 0)
            node.addChildNode(rungNode)
        }
        return node
    }

    /// Speed hoop lying flat.
    func speedRing(colorHex: String) -> SCNNode {
        let torus = SCNTorus(ringRadius: 0.38, pipeRadius: 0.018)
        torus.ringSegmentCount = 40
        torus.pipeSegmentCount = 10
        torus.firstMaterial = solidMaterial(colorHex, roughness: 0.3)
        let node = SCNNode(geometry: torus)
        node.position.y = 0.02
        let holder = SCNNode()
        holder.addChildNode(node)
        return holder
    }

    // MARK: Walls and figures

    /// Defensive wall: `count` mannequins shoulder to shoulder across the facing direction.
    func mannequinWall(colorHex: String, count: Int) -> SCNNode {
        let node = SCNNode()
        let count = min(6, max(2, count))
        let spacing: Float = 0.5
        for index in 0..<count {
            let z = (Float(index) - Float(count - 1) / 2) * spacing
            // Copy before colouring (see the mannequin element): the geometry is shared.
            let body = SCNNode(geometry: sharedMannequin.copy() as? SCNGeometry)
            body.geometry?.firstMaterial = solidMaterial(colorHex, roughness: 0.45)
            body.simdScale = SIMD3(0.42, 1, 0.82)
            body.simdPosition = SIMD3(0, 1.02, z)
            node.addChildNode(body)
            let pole = SCNNode(geometry: sharedPole)
            pole.simdPosition = SIMD3(0, 0.14, z)
            node.addChildNode(pole)
        }
        // A shared base bar ties the wall together.
        let bar = SCNBox(width: 0.2, height: 0.05, length: CGFloat(spacing * Float(count)), chamferRadius: 0.02)
        bar.firstMaterial = darkMaterial()
        let barNode = SCNNode(geometry: bar)
        barNode.position.y = 0.025
        node.addChildNode(barNode)
        return node
    }

    /// Coach or referee: the player figure in staff colours with a role ring and badge.
    func staffFigure(referee: Bool, label: String) -> SCNNode {
        let node = SCNNode()
        let body = referee ? Self.refereeColorHex : Self.coachColorHex
        let ring = referee ? Self.refereeAccentHex : BoardPalette.white
        let base = SCNNode(geometry: SCNPlane(width: 1.35, height: 1.35))
        base.eulerAngles.x = -.pi / 2
        base.position.y = 0.012
        base.castsShadow = false
        base.geometry?.firstMaterial = flatMaterial("base-\(ring)-false", image: Board3DTextures.shared.baseRing(colorHex: ring, dashed: false))
        node.addChildNode(base)
        let figure = SCNNode(geometry: figureGeometry.copy() as? SCNGeometry)
        figure.geometry?.firstMaterial = staffMaterial(body, accent: referee ? Self.refereeAccentHex : nil)
        figure.simdScale = SIMD3(1, 1, 0.84)
        node.addChildNode(figure)
        let text = label.isEmpty ? (referee ? "Referee" : "Coach") : label
        if let image = Board3DTextures.shared.badge(number: nil, label: text, colorHex: ring, kind: .player) {
            node.addChildNode(billboard(image: image, key: "staff-\(referee)-\(text)", height: 0.5, bottom: 1.86))
        }
        return node
    }

    private func staffMaterial(_ hex: String, accent: String?) -> SCNMaterial {
        material("staff-\(hex)-\(accent ?? "-")") {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = BoardPalette.uiColor(hex)
            m.roughness.contents = 0.55
            m.metalness.contents = 0.0
            m.clearCoat.contents = 0.15
            // The chest patch glows softly white (coach) or in the referee's accent colour.
            m.emission.contents = accent.map { Board3DTextures.shared.chestMask(tint: $0) } ?? Board3DTextures.shared.chestMask()
            m.emission.intensity = accent == nil ? 0.22 : 0.85
            return m
        }
    }

    // MARK: Goals

    /// Goal frame with posts, crossbar, ground frame and a sloped translucent net. The mouth faces -z.
    func goal(width: Float, height: Float, depth: Float, bar: CGFloat, frameHex: String) -> SCNNode {
        let node = SCNNode()
        let frame = solidMaterial(frameHex, roughness: 0.25)
        let fl = SIMD3<Float>(-width / 2, 0, -depth / 2), fr = SIMD3<Float>(width / 2, 0, -depth / 2)
        let bl = SIMD3<Float>(-width / 2, 0, depth / 2), br = SIMD3<Float>(width / 2, 0, depth / 2)
        let lift = SIMD3<Float>(0, height, 0)
        let backLift = SIMD3<Float>(0, height * 0.55, 0)
        tube(fl, fl + lift, radius: bar, material: frame, into: node)
        tube(fr, fr + lift, radius: bar, material: frame, into: node)
        tube(fl + lift, fr + lift, radius: bar, material: frame, into: node)
        let support = solidMaterial("C9CDD2", roughness: 0.4)
        tube(bl, br, radius: bar * 0.5, material: support, into: node)
        tube(fl, bl, radius: bar * 0.5, material: support, into: node)
        tube(fr, br, radius: bar * 0.5, material: support, into: node)
        tube(bl, bl + backLift, radius: bar * 0.4, material: support, into: node)
        tube(br, br + backLift, radius: bar * 0.4, material: support, into: node)
        tube(bl + backLift, br + backLift, radius: bar * 0.4, material: support, into: node)
        let mesh = netMaterial(repeatX: max(2, width * 2.2), repeatY: max(2, height * 2.2))
        node.addChildNode(net([
            (fl + lift, fr + lift, br + backLift, bl + backLift),
            (bl + backLift, br + backLift, br, bl),
            (fl, fl + lift, bl + backLift, bl),
            (fr, fr + lift, br + backLift, br),
        ], material: mesh))
        return node
    }

    /// Pop-up goal: two arched frames (front tall, back low) with a net between them.
    func popUpGoal(colorHex: String) -> SCNNode {
        let node = SCNNode()
        let frame = solidMaterial(colorHex, roughness: 0.35)
        let width: Float = 1.5, height: Float = 1.0, depth: Float = 0.8
        func arch(z: Float, height: Float, width: Float) -> [SIMD3<Float>] {
            (0...10).map { index in
                let t = Float(index) / 10 * .pi
                return SIMD3(-cos(t) * width / 2, sin(t) * height, z)
            }
        }
        let front = arch(z: -depth / 2, height: height, width: width)
        let back = arch(z: depth / 2, height: height * 0.45, width: width * 0.85)
        for points in [front, back] {
            for (a, b) in zip(points, points.dropFirst()) { tube(a, b, radius: 0.022, material: frame, into: node) }
        }
        let mesh = netMaterial(repeatX: 1.5, repeatY: 1.5)
        var quads: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for index in 0..<10 { quads.append((front[index], front[index + 1], back[index + 1], back[index])) }
        node.addChildNode(net(quads, material: mesh))
        return node
    }

    /// Rebounder: a framed net leaning back on short legs; its face points to +x (the front).
    func rebounder(colorHex: String) -> SCNNode {
        let node = SCNNode()
        let frame = solidMaterial(colorHex, roughness: 0.35)
        let size: Float = 1.0, lean: Float = 0.3, lift: Float = 0.12
        let bl = SIMD3<Float>(0, lift, -size / 2), br = SIMD3<Float>(0, lift, size / 2)
        let tl = SIMD3<Float>(-lean, lift + size * 0.95, -size / 2), tr = SIMD3<Float>(-lean, lift + size * 0.95, size / 2)
        for (a, b) in [(bl, br), (br, tr), (tr, tl), (tl, bl)] { tube(a, b, radius: 0.025, material: frame, into: node) }
        let legs = darkMaterial()
        for z in [-size / 2, size / 2] {
            tube(SIMD3(0, 0, z), SIMD3(0, lift, z), radius: 0.02, material: legs, into: node)
            tube(SIMD3(-lean * 0.6, 0, z), SIMD3(-lean * 0.55, lift + size * 0.5, z), radius: 0.015, material: legs, into: node)
            tube(SIMD3(0.1, 0.01, z), SIMD3(-lean * 0.8, 0.01, z), radius: 0.015, material: legs, into: node)
        }
        node.addChildNode(net([(bl, br, tr, tl)], material: netMaterial(repeatX: 4, repeatY: 4)))
        return node
    }

    // MARK: Flag, cart, step marker

    /// Corner-style flag on a post with a gentle static bend in the cloth.
    func flag(colorHex: String) -> SCNNode {
        let node = SCNNode()
        let post = SCNCylinder(radius: 0.018, height: 1.5)
        post.radialSegmentCount = 10
        post.firstMaterial = solidMaterial(BoardPalette.white, roughness: 0.3)
        let postNode = SCNNode(geometry: post)
        postNode.position.y = 0.75
        node.addChildNode(postNode)
        // Cloth: a small grid bent in a soft wave, flying towards -x (behind the facing).
        let columns = 8, rows = 3
        let width: Float = 0.45, height: Float = 0.32, top: Float = 1.48
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        for row in 0...rows {
            for column in 0...columns {
                let u = Float(column) / Float(columns), v = Float(row) / Float(rows)
                let bend = sin(u * .pi * 1.4) * 0.05 * u
                positions.append(SCNVector3(-u * width, top - v * height - u * 0.03, bend))
                normals.append(SCNVector3(-cos(u * .pi * 1.4) * 0.3 * u, 0, 1))
            }
        }
        var indices: [UInt32] = []
        let stride = UInt32(columns + 1)
        for row in 0..<UInt32(rows) {
            for column in 0..<UInt32(columns) {
                let a = row * stride + column, b = a + 1, c = a + stride, d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        let cloth = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        cloth.firstMaterial = material("flag-\(colorHex)") {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = BoardPalette.uiColor(colorHex)
            m.roughness.contents = 0.8
            m.isDoubleSided = true
            return m
        }
        node.addChildNode(SCNNode(geometry: cloth))
        node.addChildNode(contactShadow(radius: 0.25))
        return node
    }

    /// Wire ball cart holding a heap of balls.
    func ballCart(basketball: Bool) -> SCNNode {
        let node = SCNNode()
        let wire = darkMaterial()
        let w: Float = 0.8, d: Float = 0.55, bottom: Float = 0.25, top: Float = 0.75
        let corners = [SIMD2<Float>(-w / 2, -d / 2), SIMD2(w / 2, -d / 2), SIMD2(w / 2, d / 2), SIMD2(-w / 2, d / 2)]
        for (index, corner) in corners.enumerated() {
            let next = corners[(index + 1) % 4]
            tube(SIMD3(corner.x, bottom, corner.y), SIMD3(next.x, bottom, next.y), radius: 0.012, material: wire, into: node)
            tube(SIMD3(corner.x, top, corner.y), SIMD3(next.x, top, next.y), radius: 0.012, material: wire, into: node)
            tube(SIMD3(corner.x, 0, corner.y), SIMD3(corner.x, top, corner.y), radius: 0.016, material: wire, into: node)
        }
        let ball = SCNSphere(radius: basketball ? 0.12 : 0.11)
        ball.segmentCount = 16
        ball.firstMaterial = ballMaterial(basketball: basketball)
        let layout: [SIMD3<Float>] = [
            SIMD3(-0.25, 0.36, -0.13), SIMD3(0, 0.36, -0.13), SIMD3(0.25, 0.36, -0.13),
            SIMD3(-0.25, 0.36, 0.13), SIMD3(0, 0.36, 0.13), SIMD3(0.25, 0.36, 0.13),
            SIMD3(-0.12, 0.56, 0), SIMD3(0.12, 0.56, 0.02), SIMD3(0.02, 0.6, -0.14),
        ]
        for position in layout {
            let ballNode = SCNNode(geometry: ball)
            ballNode.simdPosition = position
            node.addChildNode(ballNode)
        }
        node.addChildNode(contactShadow(radius: 0.7))
        return node
    }

    func ballMaterial(basketball: Bool) -> SCNMaterial {
        material("ball-\(basketball)") {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = Board3DTextures.shared.ball(basketball: basketball)
            m.roughness.contents = 0.38
            m.metalness.contents = 0.0
            return m
        }
    }

    /// Numbered sequence disc: a flat coloured disc with a floating number.
    func stepMarker(colorHex: String, number: Int?) -> SCNNode {
        let node = SCNNode()
        let disc = SCNCylinder(radius: 0.3, height: 0.03)
        disc.radialSegmentCount = 28
        disc.firstMaterial = solidMaterial(colorHex, roughness: 0.5)
        let discNode = SCNNode(geometry: disc)
        discNode.position.y = 0.016
        node.addChildNode(discNode)
        let rim = SCNTorus(ringRadius: 0.3, pipeRadius: 0.012)
        rim.ringSegmentCount = 32
        rim.firstMaterial = solidMaterial(BoardPalette.white, roughness: 0.3)
        let rimNode = SCNNode(geometry: rim)
        rimNode.position.y = 0.03
        node.addChildNode(rimNode)
        if let number, let image = Board3DTextures.shared.badge(number: number, label: "", colorHex: colorHex, kind: .player) {
            node.addChildNode(billboard(image: image, key: "step-\(colorHex)-\(number)", height: 0.5, bottom: 0.25))
        }
        return node
    }
}
