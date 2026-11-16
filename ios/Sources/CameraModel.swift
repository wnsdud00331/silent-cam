import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// 셔터음 없는 촬영: 사진 촬영 기능(AVCapturePhotoOutput) 대신
/// 카메라 영상 프레임 한 장을 잘라 JPEG로 저장한다.
final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    @Published var thumbnail: UIImage?
    @Published var zoomLevels: [CGFloat] = [1, 2, 3]
    @Published var zoom: CGFloat = 1
    @Published var resolutionLabel = "4K"
    @Published var cameraDenied = false
    @Published var photosDenied = false
    @Published var savedCount = 0
    @Published var flash = false

    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "pilgicam.session")
    private let frameQueue = DispatchQueue(label: "pilgicam.frames")
    private let ciContext = CIContext()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // sessionQueue 전용
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var wideFactor: CGFloat = 1
    private var isFront = false
    private var configured = false

    // frameQueue 전용
    private var captureRequested = false

    // MARK: 시작

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.configureAndRun() } else { self.cameraDenied = true }
                }
            }
        default:
            cameraDenied = true
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                self.photosDenied = !(status == .authorized || status == .limited)
            }
        }
    }

    func resume() {
        sessionQueue.async {
            if self.configured && !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configureAndRun() {
        sessionQueue.async {
            guard !self.configured else { return }
            self.session.beginConfiguration()
            self.output.alwaysDiscardsLateVideoFrames = true
            self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
            if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            self.session.commitConfiguration()
            self.setCamera(front: false)
            self.configured = true
            self.session.startRunning()
        }
    }

    // MARK: 카메라 / 줌

    func flip() {
        sessionQueue.async { self.setCamera(front: !self.isFront) }
    }

    /// sessionQueue에서 호출
    private func setCamera(front: Bool) {
        let position: AVCaptureDevice.Position = front ? .front : .back
        let types: [AVCaptureDevice.DeviceType] = front
            ? [.builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        guard let dev = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices.first,
              let newInput = try? AVCaptureDeviceInput(device: dev) else { return }

        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
            device = dev
        } else if let old = input, session.canAddInput(old) {
            session.addInput(old)
        }
        let is4K = session.canSetSessionPreset(.hd4K3840x2160)
        session.sessionPreset = is4K ? .hd4K3840x2160 : .high

        if let c = output.connection(with: .video) {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = front
            }
        }
        session.commitConfiguration()
        isFront = front

        // 초광각이 있는 기기는 줌 배율 2.0이 "1×"(일반 광각)
        var wf: CGFloat = 1
        let switches = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        if dev.deviceType == .builtInTripleCamera || dev.deviceType == .builtInDualWideCamera, let first = switches.first {
            wf = first
        }
        wideFactor = wf

        let maxShown = min(dev.maxAvailableVideoZoomFactor, 20) / wf
        var levels: [CGFloat] = []
        if wf > 1 { levels.append(1 / wf) }
        levels.append(1)
        if dev.deviceType == .builtInTripleCamera, switches.count >= 2 {
            levels.append((switches[1] / wf).rounded())
        } else if dev.deviceType == .builtInDualCamera, let tele = switches.first {
            levels.append(tele.rounded())
        } else {
            levels.append(contentsOf: [2, 3].filter { $0 <= maxShown })
        }
        levels = Array(Set(levels)).sorted()

        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = max(dev.minAvailableVideoZoomFactor, min(wf, dev.maxAvailableVideoZoomFactor))
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        } catch {}

        DispatchQueue.main.async {
            self.zoomLevels = levels
            self.zoom = 1
            self.resolutionLabel = is4K ? "4K" : "HD"
        }
    }

    func setZoom(_ z: CGFloat) {
        zoom = z
        sessionQueue.async {
            guard let d = self.device else { return }
            let f = max(d.minAvailableVideoZoomFactor, min(z * self.wideFactor, d.maxAvailableVideoZoomFactor))
            do {
                try d.lockForConfiguration()
                d.ramp(toVideoZoomFactor: f, withRate: 10)
                d.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: 촬영

    func capture() {
        frameQueue.async { self.captureRequested = true }
        haptic.impactOccurred()
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.flash = false }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard captureRequested, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        captureRequested = false

        // 미리보기와 같은 3:4 비율로 가운데를 자름
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let ext = image.extent
        let targetH = min(ext.height, ext.width * 4 / 3)
        let rect = CGRect(x: ext.minX, y: ext.minY + (ext.height - targetH) / 2, width: ext.width, height: targetH)
        image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(
                of: image, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        else { return }

        let scale = 240 / max(image.extent.width, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let thumb = ciContext.createCGImage(small, from: small.extent).map { UIImage(cgImage: $0) }

        DispatchQueue.main.async { if let thumb { self.thumbnail = thumb } }
        save(jpeg)
    }

    private func save(_ data: Data) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }) { ok, _ in
            DispatchQueue.main.async {
                if ok { self.savedCount += 1 } else { self.photosDenied = true }
            }
        }
    }
}
