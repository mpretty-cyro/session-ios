// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionSnodeKit

final class ThreadPickerVC: UIViewController, UITableViewDataSource, UITableViewDelegate, AttachmentApprovalViewControllerDelegate {
    private let viewModel: ThreadPickerViewModel = ThreadPickerViewModel()
    private var dataChangeObservable: DatabaseCancellable? {
        didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
    }
    private var hasLoadedInitialData: Bool = false
    
    var shareNavController: ShareNavController?
    
    // MARK: - Intialization
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UI
    
    private lazy var titleLabel: UILabel = {
        let titleLabel: UILabel = UILabel()
        titleLabel.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        titleLabel.text = "vc_share_title".localized()
        titleLabel.themeTextColor = .textPrimary
        
        return titleLabel
    }()
    
    private lazy var databaseErrorLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.text = "database_inaccessible_error".localized()
        result.textAlignment = .center
        result.themeTextColor = .textPrimary
        result.numberOfLines = 0
        result.isHidden = true
        
        return result
    }()

    private lazy var tableView: UITableView = {
        let tableView: UITableView = UITableView()
        tableView.themeBackgroundColor = .backgroundPrimary
        tableView.separatorStyle = .none
        tableView.register(view: SimplifiedConversationCell.self)
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        
        return tableView
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.titleView = titleLabel
        
        view.themeBackgroundColor = .backgroundPrimary
        view.addSubview(tableView)
        view.addSubview(databaseErrorLabel)
        
        setupLayout()
        
        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        startObservingChanges()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopObservingChanges()
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        /// Need to dispatch to the next run loop to prevent a possible crash caused by the database resuming mid-query
        DispatchQueue.main.async { [weak self] in
            self?.startObservingChanges()
        }
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        stopObservingChanges()
    }
    
    // MARK: Layout
    
    private func setupLayout() {
        tableView.pin(to: view)
        
        databaseErrorLabel.pin(.top, to: .top, of: view, withInset: Values.massiveSpacing)
        databaseErrorLabel.pin(.leading, to: .leading, of: view, withInset: Values.veryLargeSpacing)
        databaseErrorLabel.pin(.trailing, to: .trailing, of: view, withInset: -Values.veryLargeSpacing)
    }
    
    // MARK: - Updating
    
    private func startObservingChanges() {
        guard dataChangeObservable == nil else { return }
        
        // Start observing for data changes
        dataChangeObservable = Storage.shared.start(
            viewModel.observableViewData,
            onError:  { [weak self] _ in self?.databaseErrorLabel.isHidden = Storage.shared.isValid },
            onChange: { [weak self] viewData in
                // The defaul scheduler emits changes on the main thread
                self?.handleUpdates(viewData)
            }
        )
    }
    
    private func stopObservingChanges() {
        dataChangeObservable = nil
    }
    
    private func handleUpdates(_ updatedViewData: [SessionThreadViewModel]) {
        // Ensure the first load runs without animations (if we don't do this the cells will animate
        // in from a frame of CGRect.zero)
        guard hasLoadedInitialData else {
            hasLoadedInitialData = true
            UIView.performWithoutAnimation { handleUpdates(updatedViewData) }
            return
        }
        
        // Reload the table content (animate changes after the first load)
        tableView.reload(
            using: StagedChangeset(source: viewModel.viewData, target: updatedViewData),
            with: .automatic,
            interrupt: { $0.changeCount > 100 }    // Prevent too many changes from causing performance issues
        ) { [weak self] updatedData in
            self?.viewModel.updateData(updatedData)
        }
    }
    
    // MARK: - UITableViewDataSource
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.viewModel.viewData.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: SimplifiedConversationCell = tableView.dequeue(type: SimplifiedConversationCell.self, for: indexPath)
        cell.update(with: self.viewModel.viewData[indexPath.row])
        
        return cell
    }
    
    // MARK: - Interaction
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        ShareNavController.attachmentPrepPublisher?
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sinkUntilComplete(
                receiveValue: { [weak self] attachments in
                    guard let strongSelf = self else { return }
                    
                    let approvalVC: UINavigationController = AttachmentApprovalViewController.wrappedInNavController(
                        threadId: strongSelf.viewModel.viewData[indexPath.row].threadId,
                        threadVariant: strongSelf.viewModel.viewData[indexPath.row].threadVariant,
                        attachments: attachments,
                        approvalDelegate: strongSelf
                    )
                    strongSelf.navigationController?.present(approvalVC, animated: true, completion: nil)
                }
            )
    }
    
    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didApproveAttachments attachments: [SignalAttachment],
        forThreadId threadId: String,
        threadVariant: SessionThread.Variant,
        messageText: String?,
        using dependencies: Dependencies = Dependencies()
    ) {
        // Sharing a URL or plain text will populate the 'messageText' field so in those
        // cases we should ignore the attachments
        let isSharingUrl: Bool = (attachments.count == 1 && attachments[0].isUrl)
        let isSharingText: Bool = (attachments.count == 1 && attachments[0].isText)
        let finalAttachments: [SignalAttachment] = (isSharingUrl || isSharingText ? [] : attachments)
        let body: String? = (
            isSharingUrl && (messageText?.isEmpty == true || attachments[0].linkPreviewDraft == nil) ?
            (
                (messageText?.isEmpty == true || (attachments[0].text() == messageText) ?
                    attachments[0].text() :
                    "\(attachments[0].text() ?? "")\n\n\(messageText ?? "")"
                )
            ) :
            messageText
        )
        
        shareNavController?.dismiss(animated: true, completion: nil)
        
        ModalActivityIndicatorViewController.present(fromViewController: shareNavController!, canCancel: false, message: "vc_share_sending_message".localized()) { activityIndicator in
            Storage.resumeDatabaseAccess()
            
            /// When we prepare the message we set the timestamp to be the `SnodeAPI.currentOffsetTimestampMs()`
            /// but won't actually have a value because the share extension won't have talked to a service node yet which can cause
            /// issues with Disappearing Messages, as a result we need to explicitly `getNetworkTime` in order to ensure it's accurate
            Just(())
                .setFailureType(to: Error.self)
                .flatMap { _ in
                    // We may not have sufficient snodes, so rather than failing we try to load/fetch
                    // them if needed
                    guard !SnodeAPI.hasCachedSnodesIncludingExpired() else {
                        return Just(())
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }
                    
                    return SnodeAPI.getSnodePool()
                        .map { _ in () }
                        .eraseToAnyPublisher()
                }
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .flatMap { _ in
                    SnodeAPI
                        .getSwarm(
                            for: {
                                switch threadVariant {
                                    case .contact, .legacyGroup, .group: return threadId
                                    case .community: return getUserHexEncodedPublicKey(using: dependencies)
                                }
                            }(),
                            using: dependencies
                        )
                        .tryFlatMapWithRandomSnode { SnodeAPI.getNetworkTime(from: $0, using: dependencies) }
                        .map { _ in () }
                        .eraseToAnyPublisher()
                }
                .flatMap { _ in
                    dependencies.storage.writePublisher { db -> MessageSender.PreparedSendData in
                        guard
                            let threadVariant: SessionThread.Variant = try SessionThread
                                .filter(id: threadId)
                                .select(.variant)
                                .asRequest(of: SessionThread.Variant.self)
                                .fetchOne(db)
                        else { throw MessageSenderError.noThread }
                        
                        // Create the interaction
                        let interaction: Interaction = try Interaction(
                            threadId: threadId,
                            authorId: getUserHexEncodedPublicKey(db),
                            variant: .standardOutgoing,
                            body: body,
                            timestampMs: SnodeAPI.currentOffsetTimestampMs(),
                            hasMention: Interaction.isUserMentioned(db, threadId: threadId, body: body),
                            expiresInSeconds: try? DisappearingMessagesConfiguration
                                .select(.durationSeconds)
                                .filter(id: threadId)
                                .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                                .asRequest(of: TimeInterval.self)
                                .fetchOne(db),
                            linkPreviewUrl: (isSharingUrl ? attachments.first?.linkPreviewDraft?.urlString : nil)
                        ).inserted(db)
                        
                        guard let interactionId: Int64 = interaction.id else {
                            throw StorageError.failedToSave
                        }
                        
                        // If the user is sharing a Url, there is a LinkPreview and it doesn't match an existing
                        // one then add it now
                        if
                            isSharingUrl,
                            let linkPreviewDraft: LinkPreviewDraft = attachments.first?.linkPreviewDraft,
                            (try? interaction.linkPreview.isEmpty(db)) == true
                        {
                            try LinkPreview(
                                url: linkPreviewDraft.urlString,
                                title: linkPreviewDraft.title,
                                attachmentId: LinkPreview
                                    .generateAttachmentIfPossible(
                                        imageData: linkPreviewDraft.jpegImageData,
                                        mimeType: OWSMimeTypeImageJpeg
                                    )?
                                    .inserted(db)
                                    .id
                            ).insert(db)
                        }
                        
                        // Prepare any attachments
                        try Attachment.process(
                            db,
                            data: Attachment.prepare(attachments: finalAttachments),
                            for: interactionId
                        )
                        
                        // Prepare the message send data
                        return try MessageSender
                            .preparedSendData(
                                db,
                                interaction: interaction,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                using: dependencies
                            )
                    }
                }
                .flatMap { MessageSender.performUploadsIfNeeded(preparedSendData: $0, using: dependencies) }
                .flatMap { MessageSender.sendImmediate(data: $0, using: dependencies) }
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { [weak self] result in
                        Storage.suspendDatabaseAccess()
                        activityIndicator.dismiss { }
                        
                        switch result {
                            case .finished: self?.shareNavController?.shareViewWasCompleted()
                            case .failure(let error): self?.shareNavController?.shareViewFailed(error: error)
                        }
                    }
                )
        }
    }

    func attachmentApprovalDidCancel(_ attachmentApproval: AttachmentApprovalViewController) {
        dismiss(animated: true, completion: nil)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeMessageText newMessageText: String?) {
    }
    
    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didRemoveAttachment attachment: SignalAttachment) {
    }
    
    func attachmentApprovalDidTapAddMore(_ attachmentApproval: AttachmentApprovalViewController) {
    }
}
