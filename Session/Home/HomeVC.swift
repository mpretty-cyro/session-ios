import SessionSnodeKit

// See https://github.com/yapstudios/YapDatabase/wiki/LongLivedReadTransactions and
// https://github.com/yapstudios/YapDatabase/wiki/YapDatabaseModifiedNotification for
// more information on database handling.
final class HomeVC : BaseVC, UITableViewDataSource, UITableViewDelegate, NewConversationButtonSetDelegate, SeedReminderViewDelegate {
    private var threads: YapDatabaseViewMappings!
    private var threadViewModelCache: [String:ThreadViewModel] = [:] // Thread ID to ThreadViewModel
    private var tableViewTopConstraint: NSLayoutConstraint!
    private var unreadMessageRequestCount: UInt {
        var count: UInt = 0
        
        dbConnection.read { transaction in
            let ext = transaction.ext(TSThreadDatabaseViewExtensionName) as! YapDatabaseViewTransaction
            ext.enumerateRows(inGroup: TSMessageRequestGroup) { _, _, object, _, _, _ in
                if ((object as? TSThread)?.unreadMessageCount(transaction: transaction) ?? 0) > 0 {
                    count += 1
                }
            }
        }
        
        return count
    }
    
    private var threadCount: UInt {
        threads.numberOfItems(inGroup: TSInboxGroup)
    }
    
    private lazy var dbConnection: YapDatabaseConnection = {
        let result = OWSPrimaryStorage.shared().newDatabaseConnection()
        result.objectCacheLimit = 500
        return result
    }()
    
    private var isReloading = false
    
    // MARK: UI Components
    private lazy var seedReminderView: SeedReminderView = {
        let result = SeedReminderView(hasContinueButton: true)
        let title = "You're almost finished! 80%"
        let attributedTitle = NSMutableAttributedString(string: title)
        attributedTitle.addAttribute(.foregroundColor, value: Colors.accent, range: (title as NSString).range(of: "80%"))
        result.title = attributedTitle
        result.subtitle = NSLocalizedString("view_seed_reminder_subtitle_1", comment: "")
        result.setProgress(0.8, animated: false)
        result.delegate = self
        return result
    }()
        
    private lazy var tableView: UITableView = {
        let result = UITableView()
        result.backgroundColor = .clear
        result.separatorStyle = .none
        result.register(MessageRequestsCell.self, forCellReuseIdentifier: MessageRequestsCell.reuseIdentifier)
        result.register(ConversationCell.self, forCellReuseIdentifier: ConversationCell.reuseIdentifier)
        let bottomInset = Values.newConversationButtonBottomOffset + NewConversationButtonSet.expandedButtonSize + Values.largeSpacing + NewConversationButtonSet.collapsedButtonSize
        result.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        result.showsVerticalScrollIndicator = false
        return result
    }()

    private lazy var newConversationButtonSet: NewConversationButtonSet = {
        let result = NewConversationButtonSet()
        result.delegate = self
        return result
    }()
    
    private lazy var fadeView: UIView = {
        let result = UIView()
        let gradient = Gradients.homeVCFade
        result.setGradient(gradient)
        result.isUserInteractionEnabled = false
        return result
    }()

    private lazy var emptyStateView: UIView = {
        let explanationLabel = UILabel()
        explanationLabel.textColor = Colors.text
        explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
        explanationLabel.numberOfLines = 0
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.textAlignment = .center
        explanationLabel.text = NSLocalizedString("vc_home_empty_state_message", comment: "")
        let createNewPrivateChatButton = Button(style: .prominentOutline, size: .large)
        createNewPrivateChatButton.setTitle(NSLocalizedString("vc_home_empty_state_button_title", comment: ""), for: UIControl.State.normal)
        createNewPrivateChatButton.addTarget(self, action: #selector(createNewDM), for: UIControl.Event.touchUpInside)
        createNewPrivateChatButton.set(.width, to: Values.iPadButtonWidth)
        let result = UIStackView(arrangedSubviews: [ explanationLabel, createNewPrivateChatButton ])
        result.axis = .vertical
        result.spacing = Values.mediumSpacing
        result.alignment = .center
        result.isHidden = true
        return result
    }()
    
    // MARK: Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Note: This is a hack to ensure `isRTL` is initially gets run on the main thread so the value is cached (it gets
        // called on background threads and if it hasn't cached the value then it can cause odd performance issues since
        // it accesses UIKit)
        _ = CurrentAppContext().isRTL
        
        // Threads (part 1)
        dbConnection.beginLongLivedReadTransaction() // Freeze the connection for use on the main thread (this gives us a stable data source that doesn't change until we tell it to)
        // Preparation
        SignalApp.shared().homeViewController = self
        // Gradient & nav bar
        setUpGradientBackground()
        if navigationController?.navigationBar != nil {
            setUpNavBarStyle()
        }
        updateNavBarButtons()
        setUpNavBarSessionHeading()
        // Recovery phrase reminder
        let hasViewedSeed = UserDefaults.standard[.hasViewedSeed]
        if !hasViewedSeed {
            view.addSubview(seedReminderView)
            seedReminderView.pin(.leading, to: .leading, of: view)
            seedReminderView.pin(.top, to: .top, of: view)
            seedReminderView.pin(.trailing, to: .trailing, of: view)
        }
        // Table view
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.pin(.leading, to: .leading, of: view)
        if !hasViewedSeed {
            tableViewTopConstraint = tableView.pin(.top, to: .bottom, of: seedReminderView)
        } else {
            tableViewTopConstraint = tableView.pin(.top, to: .top, of: view, withInset: Values.smallSpacing)
        }
        tableView.pin(.trailing, to: .trailing, of: view)
        tableView.pin(.bottom, to: .bottom, of: view)
        view.addSubview(fadeView)
        fadeView.pin(.leading, to: .leading, of: view)
        let topInset = 0.15 * view.height()
        fadeView.pin(.top, to: .top, of: view, withInset: topInset)
        fadeView.pin(.trailing, to: .trailing, of: view)
        fadeView.pin(.bottom, to: .bottom, of: view)
        // Empty state view
        view.addSubview(emptyStateView)
        emptyStateView.center(.horizontal, in: view)
        let verticalCenteringConstraint = emptyStateView.center(.vertical, in: view)
        verticalCenteringConstraint.constant = -16 // Makes things appear centered visually
        // New conversation button set
        view.addSubview(newConversationButtonSet)
        newConversationButtonSet.center(.horizontal, in: view)
        newConversationButtonSet.pin(.bottom, to: .bottom, of: view, withInset: -Values.newConversationButtonBottomOffset) // Negative due to how the constraint is set up
        // Notifications
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(handleYapDatabaseModifiedNotification(_:)), name: .YapDatabaseModified, object: OWSPrimaryStorage.shared().dbNotificationObject)
        notificationCenter.addObserver(self, selector: #selector(handleProfileDidChangeNotification(_:)), name: NSNotification.Name(rawValue: kNSNotificationName_OtherUsersProfileDidChange), object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleLocalProfileDidChangeNotification(_:)), name: Notification.Name(kNSNotificationName_LocalProfileDidChange), object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleSeedViewedNotification(_:)), name: .seedViewed, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleBlockedContactsUpdatedNotification(_:)), name: .blockedContactsUpdated, object: nil)
        // Threads (part 2)
        threads = YapDatabaseViewMappings(groups: [ TSMessageRequestGroup, TSInboxGroup ], view: TSThreadDatabaseViewExtensionName) // The extension should be registered at this point
        threads.setIsReversed(true, forGroup: TSInboxGroup)
        dbConnection.read { transaction in
            self.threads.update(with: transaction) // Perform the initial update
        }
        // Start polling if needed (i.e. if the user just created or restored their Session ID)
        if OWSIdentityManager.shared().identityKeyPair() != nil {
            let appDelegate = UIApplication.shared.delegate as! AppDelegate
            appDelegate.startPollerIfNeeded()
            appDelegate.startClosedGroupPoller()
            appDelegate.startOpenGroupPollersIfNeeded()
            // Do this only if we created a new Session ID, or if we already received the initial configuration message
            if UserDefaults.standard[.hasSyncedInitialConfiguration] {
                appDelegate.syncConfigurationIfNeeded()
            }
        }
        // Re-populate snode pool if needed
        SnodeAPI.getSnodePool().retainUntilComplete()
        LokinetWrapper.setupIfNeeded()
        
        // Onion request path countries cache
        DispatchQueue.global(qos: .utility).sync {
            let _ = IP2Country.shared.populateCacheIfNeeded()
        }
        // Get default open group rooms if needed
        OpenGroupAPIV2.getDefaultRoomsIfNeeded()        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reload()
    }
    
    override func appDidBecomeActive(_ notification: Notification) {
        reload()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UITableViewDataSource
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
            case 0:
                if unreadMessageRequestCount > 0 && !CurrentAppContext().appUserDefaults()[.hasHiddenMessageRequests] {
                    return 1
                }
                
                return 0
                
            case 1: return Int(threadCount)
            default: return 0
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
            case 0:
                let cell = tableView.dequeueReusableCell(withIdentifier: MessageRequestsCell.reuseIdentifier) as! MessageRequestsCell
                cell.update(with: Int(unreadMessageRequestCount))
                return cell
                
            default:
                let cell = tableView.dequeueReusableCell(withIdentifier: ConversationCell.reuseIdentifier) as! ConversationCell
                cell.threadViewModel = threadViewModel(at: indexPath.row)
                return cell
        }
    }
        
    // MARK: Updating
    
    private func reload() {
        AssertIsOnMainThread()
        guard !isReloading else { return }
        isReloading = true
        dbConnection.beginLongLivedReadTransaction() // Jump to the latest commit
        dbConnection.read { transaction in
            self.threads.update(with: transaction)
        }
        threadViewModelCache.removeAll()
        tableView.reloadData()
        emptyStateView.isHidden = (threadCount != 0)
        isReloading = false
    }
    
    @objc private func handleYapDatabaseModifiedNotification(_ yapDatabase: YapDatabase) {
        // NOTE: This code is very finicky and crashes easily. Modify with care.
        AssertIsOnMainThread()
        // If we don't capture `threads` here, a race condition can occur where the
        // `thread.snapshotOfLastUpdate != firstSnapshot - 1` check below evaluates to
        // `false`, but `threads` then changes between that check and the
        // `ext.getSectionChanges(&sectionChanges, rowChanges: &rowChanges, for: notifications, with: threads)`
        // line. This causes `tableView.endUpdates()` to crash with an `NSInternalInconsistencyException`.
        let threads = threads!
        // Create a stable state for the connection and jump to the latest commit
        let notifications = dbConnection.beginLongLivedReadTransaction()
        guard !notifications.isEmpty else { return }
        let ext = dbConnection.ext(TSThreadDatabaseViewExtensionName) as! YapDatabaseViewConnection
        let hasChanges = (
            ext.hasChanges(forGroup: TSMessageRequestGroup, in: notifications) ||
            ext.hasChanges(forGroup: TSInboxGroup, in: notifications)
        )
        
        guard hasChanges else { return }
        
        if let firstChangeSet = notifications[0].userInfo {
            let firstSnapshot = firstChangeSet[YapDatabaseSnapshotKey] as! UInt64
            
            // The 'getSectionChanges' code below will crash if we try to process multiple commits at once
            // so just force a full reload
            if threads.snapshotOfLastUpdate != firstSnapshot - 1 {
                // Check if we inserted a new message request (if so then unhide the message request banner)
                if
                    let extensions: [String: Any] = firstChangeSet[YapDatabaseExtensionsKey] as? [String: Any],
                    let viewExtensions: [String: Any] = extensions[TSThreadDatabaseViewExtensionName] as? [String: Any]
                {
                    // Note: We do a 'flatMap' here rather than explicitly grab the desired key because
                    // the key we need is 'changeset_key_changes' in 'YapDatabaseViewPrivate.h' so could
                    // change due to an update and silently break this - this approach is a bit safer
                    let allChanges: [Any] = Array(viewExtensions.values).compactMap { $0 as? [Any] }.flatMap { $0 }
                    let messageRequestInserts = allChanges
                        .compactMap { $0 as? YapDatabaseViewRowChange }
                        .filter { $0.finalGroup == TSMessageRequestGroup && $0.type == .insert }
                    
                    if !messageRequestInserts.isEmpty && CurrentAppContext().appUserDefaults()[.hasHiddenMessageRequests] {
                        CurrentAppContext().appUserDefaults()[.hasHiddenMessageRequests] = false
                    }
                }
                
                // If there are no unread message requests then hide the message request banner
                if unreadMessageRequestCount == 0 {
                    CurrentAppContext().appUserDefaults()[.hasHiddenMessageRequests] = true
                }
                
                return reload()
            }
        }
        
        var sectionChanges = NSArray()
        var rowChanges = NSArray()
        ext.getSectionChanges(&sectionChanges, rowChanges: &rowChanges, for: notifications, with: threads)
        
        // Separate out the changes for new message requests and the inbox (so we can avoid updating for
        // new messages within an existing message request)
        let messageRequestChanges = rowChanges
            .compactMap { $0 as? YapDatabaseViewRowChange }
            .filter { $0.originalGroup == TSMessageRequestGroup || $0.finalGroup == TSMessageRequestGroup }
        let inboxRowChanges = rowChanges
            .compactMap { $0 as? YapDatabaseViewRowChange }
            .filter { $0.originalGroup == TSInboxGroup || $0.finalGroup == TSInboxGroup }
        
        guard sectionChanges.count > 0 || inboxRowChanges.count > 0 || messageRequestChanges.count > 0 else { return }
        
        tableView.beginUpdates()
        
        // If we need to unhide the message request row and then re-insert it
        if !messageRequestChanges.isEmpty {
            
            // If there are no unread message requests then hide the message request banner
            if unreadMessageRequestCount == 0 && tableView.numberOfRows(inSection: 0) == 1 {
                CurrentAppContext().appUserDefaults()[.hasHiddenMessageRequests] = true
                tableView.deleteRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
            }
            else {
                if tableView.numberOfRows(inSection: 0) == 1 && Int(unreadMessageRequestCount) <= 0 {
                    tableView.deleteRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
                }
                else if tableView.numberOfRows(inSection: 0) == 0 && Int(unreadMessageRequestCount) > 0 && !CurrentAppContext().appUserDefaults()[.hasHiddenMessageRequests] {
                    tableView.insertRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
                }
            }
        }
        
        inboxRowChanges.forEach { rowChange in
            let key = rowChange.collectionKey.key
            threadViewModelCache[key] = nil
            
            switch rowChange.type {
                case .delete:
                    tableView.deleteRows(at: [ rowChange.indexPath! ], with: .automatic)
                    
                case .insert:
                    tableView.insertRows(at: [ rowChange.newIndexPath! ], with: .automatic)
                    
                case .update:
                    tableView.reloadRows(at: [ rowChange.indexPath! ], with: .automatic)
                    
                case .move:
                    // Note: We need to handle the move from the message requests section to the inbox (since
                    // we are only showing a single row for message requests we need to custom handle this as
                    // an insert as the change won't be defined correctly)
                    if rowChange.originalGroup == TSMessageRequestGroup && rowChange.finalGroup == TSInboxGroup {
                        tableView.insertRows(at: [ rowChange.newIndexPath! ], with: .automatic)
                    }
                    else if rowChange.originalGroup == TSInboxGroup && rowChange.finalGroup == TSMessageRequestGroup {
                        tableView.deleteRows(at: [ rowChange.indexPath! ], with: .automatic)
                    }
                    
                default: break
            }
        }
        tableView.endUpdates()
        // HACK: Moves can have conflicts with the other 3 types of change.
        // Just batch perform all the moves separately to prevent crashing.
        // Since all the changes are from the original state to the final state,
        // it will still be correct if we pick the moves out.
        tableView.beginUpdates()
        rowChanges.forEach { rowChange in
            let rowChange = rowChange as! YapDatabaseViewRowChange
            let key = rowChange.collectionKey.key
            threadViewModelCache[key] = nil
            
            switch rowChange.type {
                case .move:
                    // Since we are custom handling this specific movement in the above 'updates' call we need
                    // to avoid trying to handle it here
                    if rowChange.originalGroup == TSMessageRequestGroup || rowChange.finalGroup == TSMessageRequestGroup {
                        return
                    }
                    
                    tableView.moveRow(at: rowChange.indexPath!, to: rowChange.newIndexPath!)
                    
                default: break
            }
        }
        tableView.endUpdates()
        emptyStateView.isHidden = (threadCount != 0)
    }
    
    @objc private func handleProfileDidChangeNotification(_ notification: Notification) {
        tableView.reloadData() // TODO: Just reload the affected cell
    }
    
    @objc private func handleLocalProfileDidChangeNotification(_ notification: Notification) {
        updateNavBarButtons()
    }
    
    @objc private func handleSeedViewedNotification(_ notification: Notification) {
        tableViewTopConstraint.isActive = false
        tableViewTopConstraint = tableView.pin(.top, to: .top, of: view, withInset: Values.smallSpacing)
        seedReminderView.removeFromSuperview()
    }

    @objc private func handleBlockedContactsUpdatedNotification(_ notification: Notification) {
        self.tableView.reloadData() // TODO: Just reload the affected cell
    }
    
    private func updateNavBarButtons() {
        // Profile picture view
        let profilePictureSize = Values.verySmallProfilePictureSize
        let profilePictureView = ProfilePictureView()
        profilePictureView.accessibilityLabel = "Settings button"
        profilePictureView.size = profilePictureSize
        profilePictureView.publicKey = getUserHexEncodedPublicKey()
        profilePictureView.update()
        profilePictureView.set(.width, to: profilePictureSize)
        profilePictureView.set(.height, to: profilePictureSize)
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(openSettings))
        profilePictureView.addGestureRecognizer(tapGestureRecognizer)
        
        // Path status indicator
        let pathStatusView = PathStatusView(networkLayer: .onionRequest)
        pathStatusView.accessibilityLabel = "Current onion routing path indicator"
        pathStatusView.set(.width, to: PathStatusView.size)
        pathStatusView.set(.height, to: PathStatusView.size)
        
        // Path status indicator
        let pathStatusView2 = PathStatusView(networkLayer: .lokinet)
        pathStatusView2.accessibilityLabel = "Current loki routing path indicator"
        pathStatusView2.set(.width, to: PathStatusView.size)
        pathStatusView2.set(.height, to: PathStatusView.size)
        
        // Path status indicator
        let pathStatusView3 = PathStatusView(networkLayer: .direct)
        pathStatusView3.accessibilityLabel = "Current direct routing path indicator"
        pathStatusView3.set(.width, to: PathStatusView.size)
        pathStatusView3.set(.height, to: PathStatusView.size)
        
        // Container view
        let profilePictureViewContainer = UIView()
        profilePictureViewContainer.accessibilityLabel = "Settings button"
        profilePictureViewContainer.addSubview(profilePictureView)
        profilePictureView.autoPinEdgesToSuperviewEdges()
        profilePictureViewContainer.addSubview(pathStatusView)
        pathStatusView.pin(.leading, to: .leading, of: profilePictureViewContainer, withInset: -2)
        pathStatusView.pin(.bottom, to: .bottom, of: profilePictureViewContainer)
        
        profilePictureViewContainer.addSubview(pathStatusView2)
        pathStatusView2.center(.horizontal, in: profilePictureViewContainer)
        pathStatusView2.pin(.bottom, to: .bottom, of: profilePictureViewContainer)
        
        profilePictureViewContainer.addSubview(pathStatusView3)
        pathStatusView3.pin(.trailing, to: .trailing, of: profilePictureViewContainer, withInset: 2)
        pathStatusView3.pin(.bottom, to: .bottom, of: profilePictureViewContainer)
        
        // Left bar button item
        let leftBarButtonItem = UIBarButtonItem(customView: profilePictureViewContainer)
        leftBarButtonItem.accessibilityLabel = "Settings button"
        leftBarButtonItem.isAccessibilityElement = true
        navigationItem.leftBarButtonItem = leftBarButtonItem
        
        // Right bar button item - search button
        let rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(showSearchUI))
        rightBarButtonItem.accessibilityLabel = "Search button"
        rightBarButtonItem.isAccessibilityElement  = true
        navigationItem.rightBarButtonItem = rightBarButtonItem
    }

    @objc override internal func handleAppModeChangedNotification(_ notification: Notification) {
        super.handleAppModeChangedNotification(notification)
        let gradient = Gradients.homeVCFade
        fadeView.setGradient(gradient) // Re-do the gradient
        tableView.reloadData()
    }
    
    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        switch indexPath.section {
            case 0:
                let viewController: MessageRequestsViewController = MessageRequestsViewController()
                self.navigationController?.pushViewController(viewController, animated: true)
                return
                
            default:
                guard let thread = self.thread(at: indexPath.row) else { return }
                show(thread, with: ConversationViewAction.none, highlightedMessageID: nil, animated: true)
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        switch indexPath.section {
            case 0:
                let hide = UITableViewRowAction(style: .destructive, title: NSLocalizedString("TXT_HIDE_TITLE", comment: "")) { [weak self] _, _ in
                    CurrentAppContext().appUserDefaults()[.hasHiddenMessageRequests] = true

                    // Animate the row removal
                    self?.tableView.beginUpdates()
                    self?.tableView.deleteRows(at: [indexPath], with: .automatic)
                    self?.tableView.endUpdates()
                }
                hide.backgroundColor = Colors.destructive
                
                return [hide]
                
            default:
                guard let thread = self.thread(at: indexPath.row) else { return [] }
                let delete = UITableViewRowAction(style: .destructive, title: NSLocalizedString("TXT_DELETE_TITLE", comment: "")) { [weak self] _, _ in
                    var message = NSLocalizedString("CONVERSATION_DELETE_CONFIRMATION_ALERT_MESSAGE", comment: "")
                    if let thread = thread as? TSGroupThread, thread.isClosedGroup, thread.groupModel.groupAdminIds.contains(getUserHexEncodedPublicKey()) {
                        message = NSLocalizedString("admin_group_leave_warning", comment: "")
                    }
                    let alert = UIAlertController(title: NSLocalizedString("CONVERSATION_DELETE_CONFIRMATION_ALERT_TITLE", comment: ""), message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: NSLocalizedString("TXT_DELETE_TITLE", comment: ""), style: .destructive) { [weak self] _ in
                        self?.delete(thread)
                    })
                    alert.addAction(UIAlertAction(title: NSLocalizedString("TXT_CANCEL_TITLE", comment: ""), style: .default) { _ in })
                    guard let self = self else { return }
                    self.presentAlert(alert)
                }
                delete.backgroundColor = Colors.destructive
                
                let isPinned = thread.isPinned
                let pin = UITableViewRowAction(style: .normal, title: NSLocalizedString("PIN_BUTTON_TEXT", comment: "")) { [weak self] _, _ in
                    thread.isPinned = true
                    thread.save()
                    self?.threadViewModelCache.removeValue(forKey: thread.uniqueId!)
                    tableView.reloadRows(at: [ indexPath ], with: UITableView.RowAnimation.fade)
                }
                pin.backgroundColor = Colors.pathsBuilding
                let unpin = UITableViewRowAction(style: .normal, title: NSLocalizedString("UNPIN_BUTTON_TEXT", comment: "")) { [weak self] _, _ in
                    thread.isPinned = false
                    thread.save()
                    self?.threadViewModelCache.removeValue(forKey: thread.uniqueId!)
                    tableView.reloadRows(at: [ indexPath ], with: UITableView.RowAnimation.fade)
                }
                unpin.backgroundColor = Colors.pathsBuilding
                
                if let thread = thread as? TSContactThread, !thread.isNoteToSelf() {
                    let publicKey = thread.contactSessionID()

                    let block = UITableViewRowAction(style: .normal, title: NSLocalizedString("BLOCK_LIST_BLOCK_BUTTON", comment: "")) { _, _ in
                        Storage.shared.write(
                            with: { transaction in
                                guard  let transaction = transaction as? YapDatabaseReadWriteTransaction, let contact: Contact = Storage.shared.getContact(with: publicKey, using: transaction) else {
                                    return
                                }
                                
                                contact.isBlocked = true
                                Storage.shared.setContact(contact, using: transaction as Any)
                            },
                            completion: {
                                MessageSender.syncConfiguration(forceSyncNow: true).retainUntilComplete()
                                
                                DispatchQueue.main.async {
                                    tableView.reloadRows(at: [ indexPath ], with: UITableView.RowAnimation.fade)
                                }
                            }
                        )
                    }
                    block.backgroundColor = Colors.unimportant
                    let unblock = UITableViewRowAction(style: .normal, title: NSLocalizedString("BLOCK_LIST_UNBLOCK_BUTTON", comment: "")) { _, _ in
                        Storage.shared.write(
                            with: { transaction in
                                guard  let transaction = transaction as? YapDatabaseReadWriteTransaction, let contact: Contact = Storage.shared.getContact(with: publicKey, using: transaction) else {
                                    return
                                }
                                
                                contact.isBlocked = false
                                Storage.shared.setContact(contact, using: transaction as Any)
                            },
                            completion: {
                                MessageSender.syncConfiguration(forceSyncNow: true).retainUntilComplete()
                                
                                DispatchQueue.main.async {
                                    tableView.reloadRows(at: [ indexPath ], with: UITableView.RowAnimation.fade)
                                }
                            }
                        )
                    }
                    unblock.backgroundColor = Colors.unimportant
                    return [ delete, (thread.isBlocked() ? unblock : block), (isPinned ? unpin : pin) ]
                }
                else {
                    return [ delete, (isPinned ? unpin : pin) ]
                }
        }
    }
    
    // MARK: - Interaction
    
    func handleContinueButtonTapped(from seedReminderView: SeedReminderView) {
        let seedVC = SeedVC()
        let navigationController = OWSNavigationController(rootViewController: seedVC)
        present(navigationController, animated: true, completion: nil)
    }
    
    @objc func show(_ thread: TSThread, with action: ConversationViewAction, highlightedMessageID: String?, animated: Bool) {
        DispatchMainThreadSafe {
            if let presentedVC = self.presentedViewController {
                presentedVC.dismiss(animated: false, completion: nil)
            }
            let conversationVC = ConversationVC(thread: thread)
            self.navigationController?.setViewControllers([ self, conversationVC ], animated: true)
        }
    }
    
    private func delete(_ thread: TSThread) {
        let openGroupV2 = Storage.shared.getV2OpenGroup(for: thread.uniqueId!)
        Storage.write { transaction in
            Storage.shared.cancelPendingMessageSendJobs(for: thread.uniqueId!, using: transaction)
            if let openGroupV2 = openGroupV2 {
                OpenGroupManagerV2.shared.delete(openGroupV2, associatedWith: thread, using: transaction)
            } else if let thread = thread as? TSGroupThread, thread.isClosedGroup == true {
                let groupID = thread.groupModel.groupId
                let groupPublicKey = LKGroupUtilities.getDecodedGroupID(groupID)
                MessageSender.leave(groupPublicKey, using: transaction).retainUntilComplete()
                thread.removeAllThreadInteractions(with: transaction)
                thread.remove(with: transaction)
            } else {
                thread.removeAllThreadInteractions(with: transaction)
                thread.remove(with: transaction)
            }
        }
    }
    
    @objc private func openSettings() {
        let settingsVC = SettingsVC()
        let navigationController = OWSNavigationController(rootViewController: settingsVC)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true, completion: nil)
    }
    
    @objc private func showSearchUI() {
        if let presentedVC = self.presentedViewController {
            presentedVC.dismiss(animated: false, completion: nil)
        }
        let searchController = GlobalSearchViewController()
        self.navigationController?.setViewControllers([ self, searchController ], animated: true)
    }
    
    @objc func joinOpenGroup() {
        let joinOpenGroupVC = JoinOpenGroupVC()
        let navigationController = OWSNavigationController(rootViewController: joinOpenGroupVC)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        present(navigationController, animated: true, completion: nil)
    }
    
    @objc func createNewDM() {
        let newDMVC = NewDMVC()
        let navigationController = OWSNavigationController(rootViewController: newDMVC)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        present(navigationController, animated: true, completion: nil)
    }
    
    @objc(createNewDMFromDeepLink:)
    func createNewDMFromDeepLink(sessionID: String) {
        let newDMVC = NewDMVC(sessionID: sessionID)
        let navigationController = OWSNavigationController(rootViewController: newDMVC)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        present(navigationController, animated: true, completion: nil)
    }
    
    @objc func createClosedGroup() {
        let newClosedGroupVC = NewClosedGroupVC()
        let navigationController = OWSNavigationController(rootViewController: newClosedGroupVC)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        present(navigationController, animated: true, completion: nil)
    }
    
    // MARK: Convenience
    private func thread(at index: Int) -> TSThread? {
        var thread: TSThread? = nil
        dbConnection.read { transaction in
            // Note: Section needs to be '1' as we now have 'TSMessageRequests' as the 0th section
            let ext = transaction.ext(TSThreadDatabaseViewExtensionName) as! YapDatabaseViewTransaction
            thread = ext.object(atRow: UInt(index), inSection: 1, with: self.threads) as? TSThread
        }
        return thread
    }
    
    private func threadViewModel(at index: Int) -> ThreadViewModel? {
        guard let thread = thread(at: index) else { return nil }
        if let cachedThreadViewModel = threadViewModelCache[thread.uniqueId!] {
            return cachedThreadViewModel
        } else {
            var threadViewModel: ThreadViewModel? = nil
            dbConnection.read { transaction in
                threadViewModel = ThreadViewModel(thread: thread, transaction: transaction)
            }
            threadViewModelCache[thread.uniqueId!] = threadViewModel
            return threadViewModel
        }
    }
}
