import SwiftUI
import ARKit
import CoreMotion
import Observation

// ── Configuration ──────────────────────────────────────────────────────────────
private let kWSHosts: [String] = [
    "192.168.4.10",             // Mac on Replay ESP32 AP network (primary demo setup)
    "192.168.2.1",              // Mac-as-hotspot / USB tether
    "172.20.10.2",              // Mac on third-phone hotspot
    "Priyams-MacBook-Air.local" // same-router mDNS (only works when Mac has internet)
]
private let kWSPort: Int    = 8765
private let kSendInterval: TimeInterval = 0.1 // 10 Hz

// ── Top-level view ──────────────────────────────────────────────────────────────
struct ContentView: View {
    @State private var coordinator = ARCoordinator()
    @State private var showHostPicker = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(coordinator: coordinator)
                .ignoresSafeArea()

            // Status bar — tap to change host
            HStack(spacing: 6) {
                Circle()
                    .fill(coordinator.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("WS \(coordinator.currentHost):\(kWSPort)  pkts: \(coordinator.packetCount)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
            .clipShape(Capsule())
            .padding(.bottom, 32)
            .onTapGesture { showHostPicker = true }
            .confirmationDialog("Select Mac host", isPresented: $showHostPicker) {
                ForEach(kWSHosts, id: \.self) { host in
                    Button(host) { coordinator.switchHost(host) }
                }
                Button("Cancel", role: .cancel) {}
            }
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
final class ARCoordinator: NSObject, ARSessionDelegate, URLSessionWebSocketDelegate {

    var packetCount: Int = 0
    var isConnected: Bool = false
    var currentHost: String = kWSHosts[0]

    private var latestFrame: ARFrame?
    private let motion = CMMotionManager()
    private var timer: Timer?
    private var debugCounter: Int = 0

    private var urlSession: URLSession!
    private var wsTask: URLSessionWebSocketTask?
    private var inFlight: Int = 0        // main-thread only
    private var reconnectPending = false  // ensures only one reconnect is scheduled at a time

    // MARK: Setup

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false       // fail fast so we get real errors + retry
        // No request timeout — WebSocket is a persistent connection; idle gaps are normal.
        urlSession = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        print("[WS] coordinator init — session \(ObjectIdentifier(urlSession!))")
        setupMotion()
        connectWS()
    }

    deinit {
        // invalidateAndCancel releases the delegate reference, breaking the retain cycle
        // and killing any in-flight tasks so they don't keep calling back after dealloc.
        urlSession.invalidateAndCancel()
        timer?.invalidate()
    }

    func bind(session: ARSession) {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        startTimer()
    }

    // MARK: WebSocket

    /// Switch to a different host and reconnect immediately. Called from the host picker UI.
    func switchHost(_ host: String) {
        currentHost = host
        scheduleReconnect(delay: 0)
    }

    private func connectWS() {
        reconnectPending = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "ws://\(currentHost):\(kWSPort)") else { return }
        print("[WS] connecting to \(url.absoluteString)")
        let task = urlSession.webSocketTask(with: url)
        wsTask = task
        inFlight = 0
        task.resume()
        listenLoop(task)
    }

    private func listenLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self = self, let task = task, self.wsTask === task else { return }
            switch result {
            case .success:
                self.listenLoop(task)
            case .failure(let err):
                let delay = Self.backoffDelay(for: err)
                print("[WS] recv err (retry in \(Int(delay))s): \(err.localizedDescription)")
                self.scheduleReconnect(delay: delay)
            }
        }
    }

    /// ENOMEM (error 12) means the socket pool is exhausted — back off 15 s.
    private static func backoffDelay(for error: Error) -> TimeInterval {
        return ((error as NSError).code == 12) ? 15.0 : 2.0
    }

    /// Tear down the current task and reconnect to `currentHost` after `delay` seconds.
    /// The guard ensures only one reconnect is ever pending at a time.
    private func scheduleReconnect(delay: TimeInterval = 2.0) {
        guard !reconnectPending else { return }
        reconnectPending = true
        isConnected = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connectWS()
        }
    }

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        print("[WS] connected to \(currentHost)")
        isConnected = true
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        print("[WS] closed \(closeCode.rawValue)")
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard task == wsTask else { return }
        if let error {
            let delay = Self.backoffDelay(for: error)
            print("[WS] task error (retry in \(Int(delay))s): \(error.localizedDescription)")
            scheduleReconnect(delay: delay)
        }
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

    func session(_ session: ARSession, didFailWithError error: Error) {}

    // MARK: Color sampling (sparse fallback)

    private func sampleRGBLocked(
        worldPt: simd_float3,
        pixelBuffer: CVPixelBuffer,
        camera: ARCamera
    ) -> (UInt8, UInt8, UInt8)? {
        let worldToCam = simd_inverse(camera.transform)
        let pt4 = simd_float4(worldPt.x, worldPt.y, worldPt.z, 1)
        let camPt = worldToCam * pt4
        guard camPt.z < 0 else { return nil }
        let depth = -camPt.z

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
        guard px >= 0, px < width, py >= 0, py < height else { return nil }

        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let Y = Int(yPlane[py * yStride + px])

        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let chromaOff = (py / 2) * cbcrStride + (px / 2) * 2
        let Cb = Int(cbcrPlane[chromaOff])
        let Cr = Int(cbcrPlane[chromaOff + 1])

        let R = min(max(Int(Double(Y) + 1.402   * Double(Cr - 128)), 0), 255)
        let G = min(max(Int(Double(Y) - 0.344136 * Double(Cb - 128)
                                      - 0.714136 * Double(Cr - 128)), 0), 255)
        let B = min(max(Int(Double(Y) + 1.772   * Double(Cb - 128)), 0), 255)
        return (UInt8(R), UInt8(G), UInt8(B))
    }

    // MARK: LiDAR dense cloud → binary blob
    // Each point is 15 B: f32 x, f32 y, f32 z, u8 r, u8 g, u8 b (little-endian).

    private func buildDenseCloudBinary(frame: ARFrame, depthData: ARDepthData) -> (UInt32, Data) {
        let depthMap = depthData.depthMap
        let colorBuf = frame.capturedImage
        let confMap  = depthData.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(colorBuf, .readOnly)
        if let cm = confMap { CVPixelBufferLockBaseAddress(cm, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(colorBuf, .readOnly)
            if let cm = confMap { CVPixelBufferUnlockBaseAddress(cm, .readOnly) }
        }

        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        let dStrideElems =
            CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let dPtr = CVPixelBufferGetBaseAddress(depthMap)!
            .assumingMemoryBound(to: Float32.self)

        var confPtr: UnsafeMutablePointer<UInt8>? = nil
        var confStride = 0
        if let cm = confMap {
            confPtr = CVPixelBufferGetBaseAddress(cm)!
                .assumingMemoryBound(to: UInt8.self)
            confStride = CVPixelBufferGetBytesPerRow(cm)
        }

        let colorW     = CVPixelBufferGetWidthOfPlane(colorBuf, 0)
        let colorH     = CVPixelBufferGetHeightOfPlane(colorBuf, 0)
        let yStride    = CVPixelBufferGetBytesPerRowOfPlane(colorBuf, 0)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(colorBuf, 1)
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(colorBuf, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(colorBuf, 1)!
            .assumingMemoryBound(to: UInt8.self)

        let imgRes = frame.camera.imageResolution
        let K  = frame.camera.intrinsics
        let sx = Float(dw) / Float(imgRes.width)
        let sy = Float(dh) / Float(imgRes.height)
        let fxd = K.columns.0.x * sx
        let fyd = K.columns.1.y * sy
        let cxd = K.columns.2.x * sx
        let cyd = K.columns.2.y * sy

        let colorScaleX = Float(colorW) / Float(dw)
        let colorScaleY = Float(colorH) / Float(dh)

        let camT = frame.camera.transform

        // Stride 4 on the 256×192 depth map → ~3000 candidates, ~1500–2000 kept
        // after confidence/range filtering. At 15 B/pt that's ~25–30 KB per
        // binary WS frame — comfortable over local TCP.
        let strideX = 4
        let strideY = 4

        var data = Data()
        data.reserveCapacity((dw / strideX) * (dh / strideY) * 15)
        var count: UInt32 = 0

        var v = 0
        while v < dh {
            var u = 0
            while u < dw {
                defer { u += strideX }

                if let cp = confPtr {
                    let conf = cp[v * confStride + u]
                    if conf == 0 { continue }
                }

                let d = dPtr[v * dStrideElems + u]
                if !d.isFinite || d <= 0.05 || d > 5.0 { continue }

                let xCam =  (Float(u) - cxd) * d / fxd
                let yCam = -(Float(v) - cyd) * d / fyd
                let zCam = -d

                let wp = camT * simd_float4(xCam, yCam, zCam, 1)

                let cx = Int(Float(u) * colorScaleX)
                let cy = Int(Float(v) * colorScaleY)
                if cx < 0 || cx >= colorW || cy < 0 || cy >= colorH { continue }

                let Y  = Int(yPlane[cy * yStride + cx])
                let off = (cy / 2) * cbcrStride + (cx / 2) * 2
                let Cb = Int(cbcrPlane[off])
                let Cr = Int(cbcrPlane[off + 1])

                let R = UInt8(min(max(Int(Double(Y) + 1.402    * Double(Cr - 128)), 0), 255))
                let G = UInt8(min(max(Int(Double(Y) - 0.344136 * Double(Cb - 128)
                                                    - 0.714136 * Double(Cr - 128)), 0), 255))
                let B = UInt8(min(max(Int(Double(Y) + 1.772    * Double(Cb - 128)), 0), 255))

                var fx32 = wp.x
                var fy32 = wp.y
                var fz32 = wp.z
                withUnsafeBytes(of: &fx32) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &fy32) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &fz32) { data.append(contentsOf: $0) }
                data.append(R)
                data.append(G)
                data.append(B)
                count += 1
            }
            v += strideY
        }

        return (count, data)
    }

    // MARK: Packet
    //
    // Binary layout (little-endian):
    //   u32  magic  = 0x41524b54 ("ARKT")
    //   f64  timestamp
    //   f32  cameraMatrix[16]  (col-major)
    //   f32  quatXYZW[4]
    //   u32  pointCount
    //   repeated pointCount × { f32 x, f32 y, f32 z, u8 r, u8 g, u8 b }

    private func sendPacket() {
        guard let frame = latestFrame else { return }
        guard isConnected, let task = wsTask else { return }
        guard inFlight < 3 else { return }   // drop frame if WS is backlogged

        var pointBlob = Data()
        var numPoints: UInt32 = 0
        var mode = "none"

        if let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            let (n, blob) = buildDenseCloudBinary(frame: frame, depthData: depth)
            numPoints = n
            pointBlob = blob
            mode = "lidar"
        } else if let cloud = frame.rawFeaturePoints {
            let pixelBuffer = frame.capturedImage
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            pointBlob.reserveCapacity(cloud.points.count * 15)
            for p in cloud.points {
                guard let (r, g, b) = sampleRGBLocked(
                    worldPt: p, pixelBuffer: pixelBuffer, camera: frame.camera
                ) else { continue }
                var x: Float32 = p.x
                var y: Float32 = p.y
                var z: Float32 = p.z
                withUnsafeBytes(of: &x) { pointBlob.append(contentsOf: $0) }
                withUnsafeBytes(of: &y) { pointBlob.append(contentsOf: $0) }
                withUnsafeBytes(of: &z) { pointBlob.append(contentsOf: $0) }
                pointBlob.append(r)
                pointBlob.append(g)
                pointBlob.append(b)
                numPoints += 1
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            mode = "sparse"
        }

        var header = Data()
        header.reserveCapacity(96)

        var magic: UInt32 = 0x41524b54
        withUnsafeBytes(of: &magic) { header.append(contentsOf: $0) }

        var ts: Float64 = frame.timestamp
        withUnsafeBytes(of: &ts) { header.append(contentsOf: $0) }

        let t = frame.camera.transform
        let matrixFloats: [Float32] = [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]
        matrixFloats.withUnsafeBytes { header.append(contentsOf: $0) }

        var quat: [Float32] = [0, 0, 0, 1]
        if let dm = motion.deviceMotion {
            let q = dm.attitude.quaternion
            quat = [Float32(q.x), Float32(q.y), Float32(q.z), Float32(q.w)]
        }
        quat.withUnsafeBytes { header.append(contentsOf: $0) }

        var count = numPoints
        withUnsafeBytes(of: &count) { header.append(contentsOf: $0) }

        var full = header
        full.append(pointBlob)

        inFlight += 1
        task.send(.data(full)) { [weak self] err in
            self?.inFlight -= 1
            if let err = err {
                print("[WS] send err: \(err.localizedDescription)")
                self?.scheduleReconnect()
            }
        }

        packetCount += 1

        debugCounter += 1
        if debugCounter % 20 == 0 {
            print("[DBG] mode=\(mode) pts=\(numPoints) bytes=\(full.count)")
        }
    }
}
