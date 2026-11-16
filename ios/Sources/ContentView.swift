import AVFoundation
import AVKit
import SwiftUI

private let camYellow = Color(red: 1, green: 0.84, blue: 0.04)

struct ContentView: View {
    @StateObject private var cam = CameraModel()
    @State private var showGrid = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                    .frame(height: 48)
                    .padding(.horizontal, 18)

                GeometryReader { geo in
                    let w = geo.size.width
                    let h = min(geo.size.height, w * 4 / 3)
                    ZStack {
                        CameraPreview(session: cam.session, onHardwareButton: { cam.capture() })
                        if showGrid { GridOverlay() }
                        Color.black
                            .opacity(cam.flash ? 0.85 : 0)
                            .animation(.easeOut(duration: 0.15), value: cam.flash)
                            .allowsHitTesting(false)
                        VStack {
                            Spacer()
                            zoomBar.padding(.bottom, 14)
                        }
                    }
                    .frame(width: w, height: h)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { cam.capture() }
                    .position(x: w / 2, y: geo.size.height / 2)
                }

                Text("사진")
                    .font(.system(size: 13.5, weight: .semibold))
                    .kerning(0.8)
                    .foregroundColor(camYellow)
                    .frame(height: 44)

                bottomBar
                    .frame(height: 110)
                    .padding(.horizontal, 30)
            }

            if cam.cameraDenied { deniedView }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            cam.start()
        }
        .onChange(of: phase) { p in
            if p == .active { cam.resume() }
        }
    }

    // MARK: 위쪽

    private var topBar: some View {
        HStack {
            Button { showGrid.toggle() } label: {
                Image(systemName: "squareshape.split.3x3")
                    .font(.system(size: 19))
                    .foregroundColor(showGrid ? camYellow : .white)
                    .frame(width: 36, height: 36)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "speaker.slash.fill").font(.system(size: 11))
                Text("무음").font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            Spacer()
            if cam.photosDenied {
                Button { openSettings() } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(camYellow)
                        .frame(width: 36, height: 36)
                }
            } else {
                Text(cam.resolutionLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 36, height: 36)
            }
        }
    }

    // MARK: 줌

    private var zoomBar: some View {
        HStack(spacing: 4) {
            ForEach(cam.zoomLevels, id: \.self) { z in
                let on = abs(cam.zoom - z) < 0.01
                Button { cam.setZoom(z) } label: {
                    Text(zoomLabel(z, on))
                        .font(.system(size: on ? 12 : 11, weight: .bold))
                        .foregroundColor(on ? camYellow : .white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .scaleEffect(on ? 1.12 : 1)
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .animation(.easeOut(duration: 0.15), value: cam.zoom)
    }

    private func zoomLabel(_ z: CGFloat, _ on: Bool) -> String {
        let s: String
        if z < 1 { s = String(format: ".%d", Int((z * 10).rounded())) }
        else if z == z.rounded() { s = "\(Int(z))" }
        else { s = String(format: "%.1f", z) }
        return on ? s + "×" : s
    }

    // MARK: 아래쪽

    private var bottomBar: some View {
        HStack {
            Button {
                if let u = URL(string: "photos-redirect://") { UIApplication.shared.open(u) }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.11))
                    if let t = cam.thumbnail {
                        Image(uiImage: t).resizable().scaledToFill()
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if cam.savedCount > 0 {
                        Text("\(cam.savedCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(3)
                    }
                }
            }
            Spacer()
            Button { cam.capture() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 5).frame(width: 78, height: 78)
                    Circle().fill(Color.white).frame(width: 64, height: 64)
                }
            }
            .buttonStyle(ShutterStyle())
            .accessibilityLabel("촬영")
            Spacer()
            Button { cam.flip() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .accessibilityLabel("카메라 전환")
        }
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 40)).foregroundColor(.white)
            Text("카메라 권한이 꺼져 있어요").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
            Text("설정에서 필기캠의 카메라 접근을 허용해 주세요.")
                .font(.system(size: 15)).foregroundColor(.white.opacity(0.62))
                .multilineTextAlignment(.center)
            Button { openSettings() } label: {
                Text("설정 열기")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 14).fill(camYellow))
            }
            .padding(.top, 10)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private func openSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
    }
}

struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: g.size.height))
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: 카메라 미리보기 + 볼륨 버튼 촬영

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onHardwareButton: () -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        if #available(iOS 17.2, *) {
            // 볼륨 버튼(및 카메라 버튼)을 누르면 촬영
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .began { onHardwareButton() }
            }
            v.addInteraction(interaction)
        }
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}
