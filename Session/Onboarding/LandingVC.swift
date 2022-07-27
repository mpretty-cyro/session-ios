// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class LandingVC: BaseVC {
    
    // MARK: Components
    private lazy var fakeChatView: FakeChatView = {
        let result = FakeChatView()
        result.set(.height, to: LandingVC.fakeChatViewHeight)
        return result
    }()
    
    private lazy var registerButton: Button = {
        let result = Button(style: .prominentFilled, size: .large)
        result.setTitle(NSLocalizedString("vc_landing_register_button_title", comment: ""), for: UIControl.State.normal)
        result.titleLabel!.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.addTarget(self, action: #selector(register), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    private lazy var restoreButton: Button = {
        let result = Button(style: .prominentOutline, size: .large)
        result.setTitle(NSLocalizedString("vc_landing_restore_button_title", comment: ""), for: UIControl.State.normal)
        result.titleLabel!.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.addTarget(self, action: #selector(restore), for: UIControl.Event.touchUpInside)
        return result
    }()
    
    // MARK: Settings
    private static let fakeChatViewHeight = isIPhone5OrSmaller ? CGFloat(234) : CGFloat(260)
    
    // MARK: Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setUpGradientBackground()
        setUpNavBarStyle()
        setUpNavBarSessionIcon()
        // Title label
        let titleLabel = UILabel()
        titleLabel.textColor = Colors.text
        titleLabel.font = .boldSystemFont(ofSize: isIPhone5OrSmaller ? Values.largeFontSize : Values.veryLargeFontSize)
        titleLabel.text = NSLocalizedString("vc_landing_title_2", comment: "")
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        // Title label container
        let titleLabelContainer = UIView()
        titleLabelContainer.addSubview(titleLabel)
        titleLabel.pin(.leading, to: .leading, of: titleLabelContainer, withInset: Values.veryLargeSpacing)
        titleLabel.pin(.top, to: .top, of: titleLabelContainer)
        titleLabelContainer.pin(.trailing, to: .trailing, of: titleLabel, withInset: Values.veryLargeSpacing)
        titleLabelContainer.pin(.bottom, to: .bottom, of: titleLabel)
        // Spacers
        let topSpacer = UIView.vStretchingSpacer()
        let bottomSpacer = UIView.vStretchingSpacer()
        // Link button
        let linkButton = UIButton()
        linkButton.setTitle(NSLocalizedString("vc_landing_link_button_title", comment: ""), for: UIControl.State.normal)
        linkButton.setTitleColor(Colors.text, for: UIControl.State.normal)
        linkButton.titleLabel!.font = .boldSystemFont(ofSize: Values.smallFontSize)
        linkButton.addTarget(self, action: #selector(link), for: UIControl.Event.touchUpInside)
        // Link button container
        let linkButtonContainer = UIView()
        linkButtonContainer.set(.height, to: Values.onboardingButtonBottomOffset)
        linkButtonContainer.addSubview(linkButton)
        linkButton.center(.horizontal, in: linkButtonContainer)
        let isIPhoneX = (UIApplication.shared.keyWindow!.safeAreaInsets.bottom > 0)
        linkButton.centerYAnchor.constraint(equalTo: linkButtonContainer.centerYAnchor, constant: isIPhoneX ? -4 : 0).isActive = true
        // Button stack view
        let buttonStackView = UIStackView(arrangedSubviews: [ registerButton, restoreButton ])
        buttonStackView.axis = .vertical
        buttonStackView.spacing = isIPhone5OrSmaller ? Values.smallSpacing : Values.mediumSpacing
        buttonStackView.alignment = .fill
        if UIDevice.current.isIPad {
            registerButton.set(.width, to: Values.iPadButtonWidth)
            restoreButton.set(.width, to: Values.iPadButtonWidth)
            buttonStackView.alignment = .center
        }
        // Button stack view container
        let buttonStackViewContainer = UIView()
        buttonStackViewContainer.addSubview(buttonStackView)
        buttonStackView.pin(.leading, to: .leading, of: buttonStackViewContainer, withInset: isIPhone5OrSmaller ? CGFloat(52) : Values.massiveSpacing)
        buttonStackView.pin(.top, to: .top, of: buttonStackViewContainer)
        buttonStackViewContainer.pin(.trailing, to: .trailing, of: buttonStackView, withInset: isIPhone5OrSmaller ? CGFloat(52) : Values.massiveSpacing)
        buttonStackViewContainer.pin(.bottom, to: .bottom, of: buttonStackView)
        // Main stack view
        let mainStackView = UIStackView(arrangedSubviews: [ topSpacer, titleLabelContainer, UIView.spacer(withHeight: isIPhone5OrSmaller ? Values.smallSpacing : Values.mediumSpacing), fakeChatView, bottomSpacer, buttonStackViewContainer, linkButtonContainer ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        view.addSubview(mainStackView)
        mainStackView.pin(to: view)
        topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor, multiplier: 1).isActive = true
    }
    
    // MARK: Interaction
    @objc private func register() {
        let registerVC = RegisterVC()
        navigationController!.pushViewController(registerVC, animated: true)
    }
    
    @objc private func restore() {
        let restoreVC = RestoreVC()
        navigationController!.pushViewController(restoreVC, animated: true)
    }
    
    @objc private func link() {
        let linkVC = LinkDeviceVC()
        navigationController!.pushViewController(linkVC, animated: true)
    }
}
