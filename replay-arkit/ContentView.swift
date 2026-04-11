import SwiftUI
import ARKit
import CoreMotion
import Network
import Observation

//

// ── Configuration ──────────────────────────────────────────────────────────────
private let kDestinationHost: String = "192.168.2.1"  // change to receiver IP
private let kDestinationPort: UInt16 = 9000
private let kSendInterval: TimeInterval = 0.1             // 100 ms

// ── Top-level view ──────────────────────────────────────────────────────────────
struct ContentView: View {
    @State private var coordinator = ARCoordinator()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(coordinator: coordinator)
                .ignoresSafeArea()

            // Status badge
            HStack(spacing: 6) {
                Circle()
                    .fill(coordinator.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("UDP :\(kDestinationPort)  pkts: \(coordinator.packetCount)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
            .clipShape(Capsule())
            .padding(.bottom, 32)
        }
    }
}

// ── UIViewRepresentable wrapper ─────────────────────────────────────────────────
struct ARViewContainer: UIViewRepresentable {
    let coordinator: ARCoordinator

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.autoenablesDefaultLighting = true
        view.session.delegate = coordinator
        coordinator.bind(session: view.session)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// ── Main coordinator ────────────────────────────────────────────────────────────
@Observable
final class ARCoordinator: NSObject, ARSessionDelegate {

    var packetCount: Int = 0
    var isRunning: Bool = false

    private var latestFrame: ARFrame?
    private let motion = CMMotionManager()
    private var udp: NWConnection?
    private var timer: Timer?
    private var debugCounter: Int = 0

    // MARK: Setup

    override init() {
        super.init()
        setupUDP()
        setupMotion()
    }

    func bind(session: ARSession) {
        let config = ARWorldTrackingConfiguration()
        // Enable raw feature points (point cloud)
        config.frameSemantics = []
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        startTimer()
    }

    // MARK: UDP

    private func setupUDP() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let host = NWEndpoint.Host(kDestinationHost)
        let port = NWEndpoint.Port(rawValue: kDestinationPort)!
        udp = NWConnection(host: host, port: port, using: params)
        udp?.start(queue: .global(qos: .utility))
    }

    // MARK: Motion

    private func setupMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = kSendInterval
        motion.startDeviceMotionUpdates()
    }

    // MARK: Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: kSendInterval, repeats: true) { [weak self] _ in
            self?.sendPacket()
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.isRunning = false }
    }

    // MARK: Color sampling

    /// Sample the real camera color for a world-space ARKit feature point.
    /// The caller must have already called CVPixelBufferLockBaseAddress(.readOnly)
    /// on `pixelBuffer` before invoking this, and unlock after the batch is done.
    /// Returns nil if the point is behind the camera or projects outside the
    /// captured image — callers should drop those points entirely.
    private func sampleRGBLocked(
        worldPt: simd_float3,
        pixelBuffer: CVPixelBuffer,
        camera: ARCamera
    ) -> (UInt8, UInt8, UInt8)? {
        // World → camera space (ARKit: camera looks down -Z, so points in
        // front of the camera have camPt.z < 0).
        let worldToCam = simd_inverse(camera.transform)
        let pt4 = simd_float4(worldPt.x, worldPt.y, worldPt.z, 1)
        let camPt = worldToCam * pt4

        guard camPt.z < 0 else { return nil }  // behind camera
        let depth = -camPt.z

        // Pinhole projection using intrinsics (in native sensor pixels).
        // ARKit camera Y points up while image Y points down → flip Y.
        let K  = camera.intrinsics
        let fx = K.columns.0.x
        let fy = K.columns.1.y
        let cx = K.columns.2.x
        let cy = K.columns.2.y

        let u =  fx * camPt.x / depth + cx
        let v = -fy * camPt.y / depth + cy

        let imageRes = camera.imageResolution
        let width  = Int(imageRes.width)
        let height = Int(imageRes.height)
        let px = Int(u)
        let py = Int(v)

        guard px >= 0, px < width, py >= 0, py < height else {
            return nil  // outside captured image
        }

        // Y plane: full resolution, 1 byte per pixel
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let Y = Int(yPlane[py * yStride + px])

        // CbCr plane: half resolution, 2 bytes per chroma pixel (Cb then Cr)
        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let chromaOff = (py / 2) * cbcrStride + (px / 2) * 2
        let Cb = Int(cbcrPlane[chromaOff])
        let Cr = Int(cbcrPlane[chromaOff + 1])

        // BT.601 YCbCr → RGB
        let R = min(max(Int(Double(Y) + 1.402   * Double(Cr - 128)), 0), 255)
        let G = min(max(Int(Double(Y) - 0.344136 * Double(Cb - 128)
                                      - 0.714136 * Double(Cr - 128)), 0), 255)
        let B = min(max(Int(Double(Y) + 1.772   * Double(Cb - 128)), 0), 255)
        return (UInt8(R), UInt8(G), UInt8(B))
    }

    // MARK: Packet

    private func sendPacket() {
        guard let frame = latestFrame else { return }

        // ── Camera world transform (column-major, 16 floats) ──────────────────
        let t = frame.camera.transform
        let matrix: [Float] = [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]

        // ── Point cloud (with per-point RGB sampled from camera image) ────────
        // Drops any point that is behind the camera or projects outside the
        // captured image — persistent ARKit feature points that aren't in the
        // current view.
        var pointArray: [[Any]] = []
        var rawPointCount = 0
        if let cloud = frame.rawFeaturePoints {
            rawPointCount = cloud.points.count
            let pixelBuffer = frame.capturedImage
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            pointArray = cloud.points.compactMap { p -> [Any]? in
                guard let (r, g, b) = sampleRGBLocked(
                    worldPt: p, pixelBuffer: pixelBuffer, camera: frame.camera)
                else { return nil }
                return [p.x, p.y, p.z, Int(r), Int(g), Int(b)]
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        debugCounter += 1
        if debugCounter % 20 == 0 {
            var rSum = 0, gSum = 0, bSum = 0
            for pt in pointArray {
                rSum += (pt[3] as? Int) ?? 0
                gSum += (pt[4] as? Int) ?? 0
                bSum += (pt[5] as? Int) ?? 0
            }
            let n = max(pointArray.count, 1)
            print("[DBG] raw=\(rawPointCount) kept=\(pointArray.count) avgRGB=(\(rSum/n),\(gSum/n),\(bSum/n))")
        }

        // ── Device motion quaternion ──────────────────────────────────────────
        var quat: [Double] = [0.0, 0.0, 0.0, 1.0]
        if let dm = motion.deviceMotion {
            let q = dm.attitude.quaternion
            quat = [q.x, q.y, q.z, q.w]
        }

        // ── Assemble & send ───────────────────────────────────────────────────
        let payload: [String: Any] = [
            "ts":             frame.timestamp,
            "cameraMatrix":   matrix,           // col-major 4×4
            "pointCloud":     pointArray,        // [[x,y,z,r,g,b], ...]
            "quatXYZW":       quat,              // device motion quaternion
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        udp?.send(content: data, completion: .idempotent)

        DispatchQueue.main.async { [weak self] in
            self?.packetCount += 1
        }
    }
}
