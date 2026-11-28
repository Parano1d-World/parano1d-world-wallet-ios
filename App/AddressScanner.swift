import SwiftUI
import AVFoundation

enum ScannedAddress {
    static func parse(_ payload:String) -> String? {
        guard payload.utf8.count<=256 else{return nil}
        let address=payload.trimmingCharacters(in:.whitespacesAndNewlines)
        // Address only: never execute a URL, select a network, or approve an amount.
        return AddressValidator.valid(address) ? address : nil
    }
}
enum ScannedContactInvitation {
    static func candidates(_ payload:String) -> [String] {
        guard payload.utf8.count<=8192 else{return []}
        let scheme="paramo1d://contact/"
        let normalized=payload.replacingOccurrences(of:"\r\n",with:"\n")
        var tails:[String]=[]
        var search=normalized.startIndex..<normalized.endIndex
        while let found=normalized.range(of:scheme,options:.caseInsensitive,range:search),tails.count<4 {
            let next=normalized.range(of:scheme,options:.caseInsensitive,range:found.upperBound..<normalized.endIndex)
            tails.append(String(normalized[found.upperBound..<(next?.lowerBound ?? normalized.endIndex)]))
            guard let next else{break}
            search=next.lowerBound..<normalized.endIndex
        }
        if tails.isEmpty {
            let trimmed=normalized.trimmingCharacters(in:.whitespacesAndNewlines)
            // A copied code without its link is accepted only if it starts like
            // an encoded contact card. Native signature verification decides.
            if trimmed.hasPrefix("eyJ") {tails=[trimmed]}
            else if let data=trimmed.data(using:.utf8),
                    let card=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                    card["contact"] != nil,card["signature"] != nil {
                tails=[data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")]
            }
        }
        let allowed=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var results=Set<String>()
        for tail in tails {
            // Shared text can wrap the code or add prose after it. Try each
            // completed line, with and without a formatting hyphen at its end.
            var kept="",unwrapped=""
            for line in tail.split(separator:"\n",omittingEmptySubsequences:false).prefix(96) {
                let piece=String(line).trimmingCharacters(in:.whitespacesAndNewlines)
                if piece.isEmpty {if !kept.isEmpty {break};continue}
                let token=piece.unicodeScalars.prefix {allowed.contains($0)}.map(String.init).joined()
                if token.isEmpty {break}
                if token != piece && !kept.isEmpty {break}
                kept+=token
                unwrapped+=token.hasSuffix("-") ? String(token.dropLast()) : token
                for encoded in [kept,unwrapped] where !encoded.isEmpty && encoded.utf8.count<=4096 {
                    results.insert(scheme+encoded)
                }
                if token != piece {break}
            }
        }
        return results.sorted {$0.count>$1.count}
    }
    static func parse(_ payload:String) -> String? {candidates(payload).first}
}

struct AddressScanner:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let receive:(String)->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            CameraQRView(receive:{address in receive(address);dismiss()},parse:ScannedAddress.parse,
                         instruction:"Scan a Parano1d address. Review every payment before approval.",
                         invalidMessage:"This QR code is not a valid Parano1d address. No action was taken.")
                .navigationTitle("Scan address").navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}}
        }
    }
}
struct ContactInvitationScanner:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let receive:(String)->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            CameraQRView(receive:{invitation in receive(invitation);dismiss()},parse:ScannedContactInvitation.parse,
                         instruction:"Scan a signed contact invitation. Compare its identity with your friend before approval.",
                         invalidMessage:"This is not a Paramo1d contact invitation. No contact was added.")
                .navigationTitle("Scan contact").navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}}
        }
    }
}
/// Scans the pairing QR shown by the Parano1d Mining dashboard on the owner's computer.
struct RigPairScanner:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let receive:(String)->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            CameraQRView(receive:{code in receive(code);dismiss()},parse:RigPairCode.parse,
                         instruction:"Scan the pairing QR on your mining computer's dashboard.",
                         invalidMessage:"This is not a Parano1d Mining pairing code. Nothing was paired.")
                .navigationTitle("Scan mining QR").navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}}
        }
    }
}
private struct CameraQRView:UIViewControllerRepresentable {
    let receive:(String)->Void
    let parse:(String)->String?
    let instruction:String
    let invalidMessage:String
    func makeUIViewController(context:Context)->AddressCameraController{
        AddressCameraController(receive:receive,parse:parse,instruction:instruction,invalidMessage:invalidMessage)
    }
    func updateUIViewController(_ controller:AddressCameraController,context:Context){}
    static func dismantleUIViewController(_ controller:AddressCameraController,coordinator:()){controller.stop()}
}
private final class AddressCameraController:UIViewController,AVCaptureMetadataOutputObjectsDelegate {
    private let capture=AVCaptureSession()
    private let worker=DispatchQueue(label:"com.koajent.parano1d.address-camera")
    private var configured=false // worker queue only
    private var visible=false // main queue only
    private var delivered=false // main queue only
    private let preview=AVCaptureVideoPreviewLayer()
    private let message=UILabel()
    private let receive:(String)->Void
    private let parse:(String)->String?
    private let instruction:String
    private let invalidMessage:String
    init(receive:@escaping(String)->Void,parse:@escaping(String)->String?,instruction:String,invalidMessage:String){
        self.receive=receive;self.parse=parse;self.instruction=instruction;self.invalidMessage=invalidMessage
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder){fatalError("Not supported")}
    override func viewDidLoad(){
        super.viewDidLoad();view.backgroundColor = .black
        preview.session=capture;preview.videoGravity = .resizeAspectFill;view.layer.addSublayer(preview)
        message.text=instruction
        message.textColor = .white;message.backgroundColor=UIColor.black.withAlphaComponent(0.75)
        message.numberOfLines=0;message.textAlignment = .center;message.translatesAutoresizingMaskIntoConstraints=false
        view.addSubview(message)
        NSLayoutConstraint.activate([message.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),message.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),message.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-24),message.heightAnchor.constraint(greaterThanOrEqualToConstant:70)])
        NotificationCenter.default.addObserver(self,selector:#selector(background),name:UIApplication.didEnterBackgroundNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(foreground),name:UIApplication.didBecomeActiveNotification,object:nil)
    }
    override func viewDidLayoutSubviews(){super.viewDidLayoutSubviews();preview.frame=view.bounds}
    override func viewDidAppear(_ animated:Bool){super.viewDidAppear(animated);visible=true;authorize()}
    override func viewWillDisappear(_ animated:Bool){super.viewWillDisappear(animated);visible=false;stop()}
    deinit{NotificationCenter.default.removeObserver(self)}
    @objc private func background(){stop()}
    @objc private func foreground(){if visible && !delivered{authorize()}}
    private func authorize(){
        guard visible,!delivered,UIApplication.shared.applicationState == .active else{return}
        switch AVCaptureDevice.authorizationStatus(for:.video){
        case .authorized:start()
        case .notDetermined:AVCaptureDevice.requestAccess(for:.video){[weak self] granted in DispatchQueue.main.async{guard let self,self.visible else{return};if granted{self.authorize()}else{self.message.text="Camera access is off. Enable it in iOS Settings, or enter the address manually."}}}
        default:message.text="Camera access is off. Enable it in iOS Settings, or enter the address manually."
        }
    }
    private func start(){
        worker.async{[weak self] in
            guard let self else{return}
            do {
                if !self.configured {
                    guard let camera=AVCaptureDevice.default(for:.video) else{throw AppFailure("No camera is available. Enter the address manually.")}
                    let input=try AVCaptureDeviceInput(device:camera);let output=AVCaptureMetadataOutput()
                    self.capture.beginConfiguration()
                    guard self.capture.canAddInput(input),self.capture.canAddOutput(output) else{self.capture.commitConfiguration();throw AppFailure("QR scanning is unavailable on this device.")}
                    self.capture.addInput(input);self.capture.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else{self.capture.removeInput(input);self.capture.removeOutput(output);self.capture.commitConfiguration();throw AppFailure("QR scanning is unsupported.")}
                    output.setMetadataObjectsDelegate(self,queue:.main);output.metadataObjectTypes=[.qr]
                    self.capture.commitConfiguration();self.configured=true
                }
                if !self.capture.isRunning{self.capture.startRunning()}
            }catch{DispatchQueue.main.async{[weak self] in self?.message.text=error.localizedDescription}}
        }
    }
    func stop(){
        // Retain the session until queued shutdown completes, even if the sheet
        // releases its controller before the worker executes this block.
        let session=capture
        worker.async{if session.isRunning{session.stopRunning()}}
    }
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput objects:[AVMetadataObject],from connection:AVCaptureConnection){
        guard visible,!delivered,UIApplication.shared.applicationState == .active else{return}
        for object in objects {
            guard let code=object as? AVMetadataMachineReadableCodeObject,let text=code.stringValue else{continue}
            guard let payload=parse(text) else{message.text=invalidMessage;continue}
            delivered=true;stop();receive(payload);return
        }
    }
}
