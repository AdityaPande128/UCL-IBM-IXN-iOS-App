import SwiftUI
import AVFoundation
import JarvisKit

// Pair with the Mac: scan the code pair-phone prints, or type the details.
// The probe is the ladder itself; success lands in chat.
struct OnboardingView: View {
    @EnvironmentObject var model: ChatViewModel
    @State private var host = ""
    @State private var port = "8080"
    @State private var token = ""
    @State private var secret = ""
    @State private var scanning = false
    @State private var manual = false
    @State private var probing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pair with Your Mac")
                    .font(.largeTitle.bold())
                    .padding(.top, 40)
                Text("Open Jarvis on your Mac, bring up the pairing code "
                     + "(Terminal: pair-phone), and scan it with this phone.")
                    .foregroundStyle(.secondary)
                Text("Please make sure both devices are on the same network.")
                    .font(.callout.bold())
                    .foregroundStyle(Palette.accent)

                Button {
                    scanning = true
                } label: {
                    Text("Scan pairing code")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)

                Button(manual ? "Hide manual entry" : "Enter details manually") {
                    manual.toggle()
                }
                .tint(Palette.accent)

                if manual {
                    TextField("Host (IP address)", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                    SecureField("Pairing token", text: $token)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Direct secret (for away-from-home)", text: $secret)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        pair(host: host, port: Int(port) ?? 8080,
                             token: token, secret: secret)
                    } label: {
                        if probing { ProgressView() } else { Text("Connect") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(host.isEmpty || token.isEmpty || probing)
                }

                if case .unreachable = model.state {
                    Text("Could not reach the Mac with those details.")
                        .foregroundStyle(Palette.errorText)
                }
                if case .pairRequired(let reason) = model.state {
                    Text(reason).foregroundStyle(Palette.errorText)
                }
            }
            .padding()
        }
        .onChange(of: model.state) { newState in
            switch newState {
            case .connecting: break
            default: probing = false
            }
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { payload in
                scanning = false
                applyScanned(payload)
            }
        }
    }

    private func applyScanned(_ payload: String) {
        guard let parsed = decodeJSON(payload),
              let scannedHost = str(parsed, "host"), !scannedHost.isEmpty,
              let scannedToken = str(parsed, "token"), !scannedToken.isEmpty
        else {
            manual = true
            return
        }
        let scannedPort = int(parsed, "port") ?? 8080
        pair(host: scannedHost,
             port: (1...65535).contains(scannedPort) ? scannedPort : 8080,
             token: scannedToken, secret: str(parsed, "secret") ?? "")
    }

    private func pair(host: String, port: Int, token: String, secret: String) {
        probing = true
        model.prefs.host = host
        model.prefs.port = port
        model.prefs.token = token
        model.prefs.secret = secret
        model.prefs.paired = true
        model.connect()
    }
}

// The classic capture pipeline: one metadata output, QR only, first result
// wins. The session lives and dies with the view.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController,
                                   AVCaptureMetadataOutputObjectsDelegate {
        var onFound: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.layer.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            delivered = true
            onFound?(value)
        }
    }
}
