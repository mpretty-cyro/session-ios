import WebRTC
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import UIKit

final class CallVC : UIViewController, WebRTCSessionDelegate, VideoPreviewDelegate {
    let sessionID: String
    let uuid: String
    let mode: Mode
    let webRTCSession: WebRTCSession
    var shouldAnswer = false
    var isMuted = false
    var isVideoEnabled = false
    var shouldRestartCamera = true
    var conversationVC: ConversationVC? = nil
    
    lazy var cameraManager: CameraManager = {
        let result = CameraManager()
        result.delegate = self
        return result
    }()
    
    lazy var videoCapturer: RTCVideoCapturer = {
        return RTCCameraVideoCapturer(delegate: webRTCSession.localVideoSource)
    }()
    
    // MARK: UI Components
    private lazy var localVideoView: RTCMTLVideoView = {
        let result = RTCMTLVideoView()
        result.isHidden = !isVideoEnabled
        result.contentMode = .scaleAspectFill
        result.set(.width, to: 80)
        result.set(.height, to: 173)
        result.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture)))
        return result
    }()
    
    private lazy var remoteVideoView: RTCMTLVideoView = {
        let result = RTCMTLVideoView()
        result.alpha = 0
        result.contentMode = .scaleAspectFill
        return result
    }()
    
    private lazy var fadeView: UIView = {
        let result = UIView()
        let height: CGFloat = 64
        var frame = UIScreen.main.bounds
        frame.size.height = height
        let layer = CAGradientLayer()
        layer.frame = frame
        layer.colors = [ UIColor(hex: 0x000000).withAlphaComponent(0.4).cgColor, UIColor(hex: 0x000000).withAlphaComponent(0).cgColor ]
        result.layer.insertSublayer(layer, at: 0)
        result.set(.height, to: height)
        return result
    }()
    
    private lazy var minimizeButton: UIButton = {
        let result = UIButton(type: .custom)
        result.isHidden = true
        let image = UIImage(named: "Minimize")!.withTint(.white)
        result.setImage(image, for: UIControl.State.normal)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        result.addTarget(self, action: #selector(minimize), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var answerButton: UIButton = {
        let result = UIButton(type: .custom)
        let image = UIImage(named: "AnswerCall")!.withTint(.white)
        result.setImage(image, for: UIControl.State.normal)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        result.backgroundColor = Colors.accent
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(answerCall), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var hangUpButton: UIButton = {
        let result = UIButton(type: .custom)
        let image = UIImage(named: "EndCall")!.withTint(.white)
        result.setImage(image, for: UIControl.State.normal)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        result.backgroundColor = Colors.destructive
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(endCall), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var responsePanel: UIStackView = {
        let result = UIStackView(arrangedSubviews: [hangUpButton, answerButton])
        result.axis = .horizontal
        result.spacing = Values.veryLargeSpacing * 2 + 40
        return result
    }()

    private lazy var switchCameraButton: UIButton = {
        let result = UIButton(type: .custom)
        result.isEnabled = isVideoEnabled
        let image = UIImage(named: "SwitchCamera")!.withTint(.white)
        result.setImage(image, for: UIControl.State.normal)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        result.backgroundColor = UIColor(hex: 0x1F1F1F)
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(switchCamera), for: UIControl.Event.touchUpInside)
        return result
    }()

    private lazy var switchAudioButton: UIButton = {
        let result = UIButton(type: .custom)
        let image = UIImage(named: "AudioOff")!.withTint(.white)
        result.setImage(image, for: UIControl.State.normal)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        result.backgroundColor = UIColor(hex: 0x1F1F1F)
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(switchAudio), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var videoButton: UIButton = {
        let result = UIButton(type: .custom)
        let image = UIImage(named: "VideoCall")!.withTint(.white)
        result.setImage(image, for: UIControl.State.normal)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        result.backgroundColor = UIColor(hex: 0x1F1F1F)
        result.layer.cornerRadius = 30
        result.alpha = 0.5
        result.addTarget(self, action: #selector(operateCamera), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var operationPanel: UIStackView = {
        let result = UIStackView(arrangedSubviews: [videoButton, switchAudioButton, switchCameraButton])
        result.axis = .horizontal
        result.spacing = Values.veryLargeSpacing
        return result
    }()
    
    private lazy var titleLabel: UILabel = {
        let result = UILabel()
        result.textColor = .white
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.textAlignment = .center
        return result
    }()
    
    private lazy var callInfoLabel: UILabel = {
        let result = UILabel()
        result.textColor = .white
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.textAlignment = .center
        return result
    }()
    
    // MARK: Mode
    enum Mode {
        case offer
        case answer(sdp: RTCSessionDescription)
    }
    
    // MARK: Lifecycle
    init(for sessionID: String, uuid: String, mode: Mode) {
        self.sessionID = sessionID
        self.uuid = uuid
        self.mode = mode
        self.webRTCSession = WebRTCSession.current ?? WebRTCSession(for: sessionID, with: uuid)
        super.init(nibName: nil, bundle: nil)
        self.webRTCSession.delegate = self
    }
    
    required init(coder: NSCoder) { preconditionFailure("Use init(for:) instead.") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        WebRTCSession.current = webRTCSession
        setUpViewHierarchy()
        if shouldRestartCamera { cameraManager.prepare() }
        touch(videoCapturer)
        var contact: Contact?
        Storage.read { transaction in
            contact = Storage.shared.getContact(with: self.sessionID)
        }
        titleLabel.text = contact?.displayName(for: Contact.Context.regular) ?? sessionID
        if case .offer = mode {
            callInfoLabel.text = "Ringing..."
            Storage.write { transaction in
                self.webRTCSession.sendPreOffer(to: self.sessionID, using: transaction).done {
                    self.webRTCSession.sendOffer(to: self.sessionID, using: transaction).retainUntilComplete()
                }.retainUntilComplete()
            }
            answerButton.isHidden = true
        }
        if shouldAnswer { answerCall() }
    }
    
    func setUpViewHierarchy() {
        // Background
        let background = getBackgroudView()
        view.addSubview(background)
        background.pin(to: view)
        // Call info label
        view.addSubview(callInfoLabel)
        callInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        callInfoLabel.center(in: view)
        // Remote video view
        webRTCSession.attachRemoteRenderer(remoteVideoView)
        view.addSubview(remoteVideoView)
        remoteVideoView.translatesAutoresizingMaskIntoConstraints = false
        remoteVideoView.pin(to: view)
        // Local video view
        webRTCSession.attachLocalRenderer(localVideoView)
        view.addSubview(localVideoView)
        localVideoView.pin(.right, to: .right, of: view, withInset: -Values.smallSpacing)
        let topMargin = UIApplication.shared.keyWindow!.safeAreaInsets.top + Values.veryLargeSpacing
        localVideoView.pin(.top, to: .top, of: view, withInset: topMargin)
        // Fade view
        view.addSubview(fadeView)
        fadeView.translatesAutoresizingMaskIntoConstraints = false
        fadeView.pin([ UIView.HorizontalEdge.left, UIView.VerticalEdge.top, UIView.HorizontalEdge.right ], to: view)
        // Minimize button
        view.addSubview(minimizeButton)
        minimizeButton.translatesAutoresizingMaskIntoConstraints = false
        minimizeButton.pin(.left, to: .left, of: view)
        minimizeButton.pin(.top, to: .top, of: view, withInset: 32)
        // Title label
        view.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.center(.vertical, in: minimizeButton)
        titleLabel.center(.horizontal, in: view)
        // Response Panel
        view.addSubview(responsePanel)
        responsePanel.center(.horizontal, in: view)
        responsePanel.pin(.bottom, to: .bottom, of: view, withInset: -Values.newConversationButtonBottomOffset)
        // Operation Panel
        view.addSubview(operationPanel)
        operationPanel.center(.horizontal, in: view)
        operationPanel.pin(.bottom, to: .top, of: responsePanel, withInset: -Values.veryLargeSpacing)
    }
    
    private func getBackgroudView() -> UIView {
        let background = UIView()
        let imageView = UIImageView()
        imageView.layer.cornerRadius = 150
        imageView.layer.masksToBounds = true
        imageView.contentMode = .scaleAspectFill
        if let profilePicture = OWSProfileManager.shared().profileAvatar(forRecipientId: sessionID) {
            imageView.image = profilePicture
        } else {
            let displayName = Storage.shared.getContact(with: sessionID)?.name ?? sessionID
            imageView.image = Identicon.generatePlaceholderIcon(seed: sessionID, text: displayName, size: 300)
        }
        background.addSubview(imageView)
        imageView.set(.width, to: 300)
        imageView.set(.height, to: 300)
        imageView.center(in: background)
        let blurView = UIView()
        blurView.alpha = 0.5
        blurView.backgroundColor = .black
        background.addSubview(blurView)
        blurView.autoPinEdgesToSuperviewEdges()
        return background
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if (isVideoEnabled && shouldRestartCamera) { cameraManager.start() }
        shouldRestartCamera = true
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if (isVideoEnabled && shouldRestartCamera) { cameraManager.stop() }
    }
    
    // MARK: Delegate
    func webRTCIsConnected() {
        DispatchQueue.main.async {
            self.callInfoLabel.text = "Connected"
            self.minimizeButton.isHidden = false
            UIView.animate(withDuration: 0.5, delay: 1, options: [], animations: {
                self.callInfoLabel.alpha = 0
            }, completion: { _ in
                self.callInfoLabel.isHidden = true
                self.callInfoLabel.alpha = 1
            })
        }
    }
    
    func isRemoteVideoDidChange(isEnabled: Bool) {
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.25) {
                self.remoteVideoView.alpha = isEnabled ? 1 : 0
            }
        }
    }
    
    func dataChannelDidOpen() {
        // Send initial video status
        if (isVideoEnabled) {
            webRTCSession.turnOnVideo()
        } else {
            webRTCSession.turnOffVideo()
        }
    }
    
    // MARK: Interaction
    func handleAnswerMessage(_ message: CallMessage) {
        callInfoLabel.text = "Connecting..."
    }
    
    func handleEndCallMessage(_ message: CallMessage) {
        print("[Calls] Ending call.")
        callInfoLabel.isHidden = false
        callInfoLabel.text = "Call Ended"
        UIView.animate(withDuration: 0.25) {
            self.remoteVideoView.alpha = 0
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            self.conversationVC?.showInputAccessoryView()
            self.presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }
    
    internal func showCallModal() {
        let callModal = CallModal() { [weak self] in
            self?.answerCall()
        }
        callModal.modalPresentationStyle = .overFullScreen
        callModal.modalTransitionStyle = .crossDissolve
        present(callModal, animated: true, completion: nil)
    }
    
    @objc private func answerCall() {
        let userDefaults = UserDefaults.standard
        if userDefaults[.hasSeenCallIPExposureWarning] {
            if case let .answer(sdp) = mode {
                callInfoLabel.text = "Connecting..."
                webRTCSession.handleRemoteSDP(sdp, from: sessionID) // This sends an answer message internally
                self.answerButton.alpha = 0
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                    self.answerButton.isHidden = true
                }, completion: nil)
            }
        } else {
            userDefaults[.hasSeenCallIPExposureWarning] = true
            showCallModal()
        }
    }
    
    @objc private func endCall() {
        Storage.write { transaction in
            WebRTCSession.current?.endCall(with: self.sessionID, using: transaction)
        }
        self.conversationVC?.showInputAccessoryView()
        presentingViewController?.dismiss(animated: true, completion: nil)
    }
    
    @objc private func minimize() {
        self.shouldRestartCamera = false
        let miniCallView = MiniCallView(from: self)
        miniCallView.show()
        self.conversationVC?.showInputAccessoryView()
        presentingViewController?.dismiss(animated: true, completion: nil)
    }
    
    @objc private func operateCamera() {
        if (isVideoEnabled) {
            webRTCSession.turnOffVideo()
            localVideoView.isHidden = true
            cameraManager.stop()
            videoButton.alpha = 0.5
            switchCameraButton.isEnabled = false
            isVideoEnabled = false
        } else {
            let previewVC = VideoPreviewVC()
            previewVC.delegate = self
            present(previewVC, animated: true, completion: nil)
        }
    }
    
    func cameraDidConfirmTurningOn() {
        webRTCSession.turnOnVideo()
        localVideoView.isHidden = false
        cameraManager.prepare()
        cameraManager.start()
        videoButton.alpha = 1.0
        switchCameraButton.isEnabled = true
        isVideoEnabled = true
    }
    
    @objc private func switchCamera() {
        cameraManager.switchCamera()
    }
    
    @objc private func switchAudio() {
        if isMuted {
            switchAudioButton.backgroundColor = UIColor(hex: 0x1F1F1F)
            isMuted = false
            webRTCSession.unmute()
        } else {
            switchAudioButton.backgroundColor = Colors.destructive
            isMuted = true
            webRTCSession.mute()
        }
    }
    
    @objc private func handlePanGesture(gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self.view)
        if let draggedView = gesture.view {
            draggedView.center = location
            if gesture.state == .ended {
                let sideMargin = 40 + Values.verySmallSpacing
                if draggedView.frame.midX >= self.view.layer.frame.width / 2 {
                    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                        draggedView.center.x = self.view.layer.frame.width - sideMargin
                    }, completion: nil)
                }else{
                    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                        draggedView.center.x = sideMargin
                    }, completion: nil)
                }
                let topMargin = UIApplication.shared.keyWindow!.safeAreaInsets.top + Values.veryLargeSpacing
                if draggedView.frame.minY <= topMargin {
                    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                        draggedView.center.y = topMargin + draggedView.frame.size.height / 2
                    }, completion: nil)
                }
                let bottomMargin = UIApplication.shared.keyWindow!.safeAreaInsets.bottom
                if draggedView.frame.maxY >= self.view.layer.frame.height {
                    UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
                        draggedView.center.y = self.view.layer.frame.height - draggedView.frame.size.height / 2 - bottomMargin
                    }, completion: nil)
                }
            }
        }
    }
}
