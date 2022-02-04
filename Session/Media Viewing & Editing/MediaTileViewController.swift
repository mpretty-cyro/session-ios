//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import UIKit
import SessionUIKit

public protocol MediaTileViewControllerDelegate: AnyObject {
    func mediaTileViewControllerWillDismiss(_ viewController: MediaTileViewController)
    func mediaTileViewController(_ viewController: MediaTileViewController, didTapView tappedView: UIView, mediaGalleryItem: MediaGalleryItem)
}

public class MediaTileViewController: UIViewController, MediaGalleryDataSourceDelegate, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {

    private weak var mediaGalleryDataSource: MediaGalleryDataSource?

    private var galleryItems: [GalleryDate: [MediaGalleryItem]] {
        guard let mediaGalleryDataSource = self.mediaGalleryDataSource else {
            owsFailDebug("mediaGalleryDataSource was unexpectedly nil")
            return [:]
        }
        return mediaGalleryDataSource.sections
    }

    private var galleryDates: [GalleryDate] {
        guard let mediaGalleryDataSource = self.mediaGalleryDataSource else {
            owsFailDebug("mediaGalleryDataSource was unexpectedly nil")
            return []
        }
        return mediaGalleryDataSource.sectionDates
    }
    public var focusedItem: MediaGalleryItem?

    private let uiDatabaseConnection: YapDatabaseConnection

    public weak var delegate: MediaTileViewControllerDelegate?
    
    private var isUserScrolling: Bool = false {
        didSet {
            autoLoadMoreIfNecessary()
        }
    }

    var isInBatchSelectMode = false {
        didSet {
            collectionView.allowsMultipleSelection = isInBatchSelectMode
            updateSelectButton()
            updateDeleteButton()
        }
    }

    // MARK: - Initialization

    init(mediaGalleryDataSource: MediaGalleryDataSource, uiDatabaseConnection: YapDatabaseConnection) {
        self.mediaGalleryDataSource = mediaGalleryDataSource
        assert(uiDatabaseConnection.isInLongLivedReadTransaction())
        self.uiDatabaseConnection = uiDatabaseConnection

        super.init(nibName: nil, bundle: nil)
    }

    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    // MARK: - UI
    
    // This should be substantially larger than one screen size so we don't have to call it
    // multiple times in a rapid succession, but not so large that loading get's really chopping
    static let kMediaTileViewLoadBatchSize: UInt = 40
    
    static let kItemsPerPortraitRow: CGFloat = 3
    static let kInterItemSpacing: CGFloat = 10
    static let kFooterBarHeight: CGFloat = 40
    
    override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .allButUpsideDown
    }
    
    var footerBarBottomConstraint: NSLayoutConstraint?
    
    fileprivate lazy var mediaTileViewLayout: MediaTileViewLayout = {
        let layout: MediaTileViewLayout = MediaTileViewLayout()
        layout.sectionInsetReference = .fromSafeArea
        layout.minimumInteritemSpacing = MediaTileViewController.kInterItemSpacing
        layout.minimumLineSpacing = MediaTileViewController.kInterItemSpacing
        layout.sectionHeadersPinToVisibleBounds = true

        return layout
    }()
    
    lazy var collectionView: UICollectionView = {
        let collectionView: UICollectionView = UICollectionView(frame: .zero, collectionViewLayout: mediaTileViewLayout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = Colors.settingsBackground
        collectionView.delegate = self
        collectionView.dataSource = self
        
        collectionView.register(PhotoGridViewCell.self, forCellWithReuseIdentifier: PhotoGridViewCell.reuseIdentifier)
        collectionView.register(MediaGallerySectionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: MediaGallerySectionHeader.reuseIdentifier)
        collectionView.register(MediaGalleryStaticHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: MediaGalleryStaticHeader.reuseIdentifier)
        
        return collectionView
    }()

    lazy var footerBar: UIToolbar = {
        let footerBar = UIToolbar()
        let footerItems = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            deleteButton,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        ]
        footerBar.setItems(footerItems, animated: false)

        footerBar.barTintColor = Colors.navigationBarBackground
        footerBar.tintColor = Colors.text

        return footerBar
    }()

    lazy var deleteButton: UIBarButtonItem = {
        let deleteButton = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(didPressDelete))
        deleteButton.tintColor = Theme.darkThemeNavbarIconColor

        return deleteButton
    }()

    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()
        
        // Add a custom back button if this is the only view controller
        if self.navigationController?.viewControllers.first == self {
            let backButton = OWSViewController.createOWSBackButton(withTarget: self, selector: #selector(didPressDismissButton))
            self.navigationItem.leftBarButtonItem = backButton
        }
        
        view.backgroundColor = Colors.settingsBackground
        ViewControllerUtilities.setUpDefaultSessionStyle(for: self, title: MediaStrings.allMedia, hasCustomBackButton: false, hasCustomBackground: true)
        
        view.addSubview(collectionView)
        view.addSubview(footerBar)

        updateSelectButton()
        setupLayout()
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        guard let focusedItem = self.focusedItem else { return }

        guard let indexPath = self.indexPath(galleryItem: focusedItem) else {
            owsFailDebug("unexpectedly unable to find indexPath for focusedItem: \(focusedItem)")
            return
        }

        Logger.debug("scrolling to focused item at indexPath: \(indexPath)")
        self.view.layoutIfNeeded()
        self.collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        self.autoLoadMoreIfNecessary()
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        self.delegate?.mediaTileViewControllerWillDismiss(self)
    }

    override public func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        self.mediaTileViewLayout.invalidateLayout()
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        self.updateLayout()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        footerBar.autoPinWidthToSuperview()
        footerBar.autoSetDimension(.height, toSize: MediaTileViewController.kFooterBarHeight)
        footerBarBottomConstraint = footerBar.autoPinEdge(toSuperviewEdge: .bottom, withInset: -MediaTileViewController.kFooterBarHeight)
        
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leftAnchor.constraint(equalTo: view.leftAnchor),
            collectionView.rightAnchor.constraint(equalTo: view.rightAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // Do this last to ensure it updates after the layout is setup
        mediaTileViewLayout.invalidateLayout()
    }
    
    // MARK: - Interaction
    
    @objc
    public func didPressDismissButton() {
        dismiss(animated: true, completion: nil)
    }

    // MARK: - UICollectionViewDelegate

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.autoLoadMoreIfNecessary()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.isUserScrolling = true
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        self.isUserScrolling = false
    }

    public func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard !galleryDates.isEmpty else { return false }

        switch indexPath.section {
            case loadNewerSectionIdx, kLoadOlderSectionIdx: return false
            default: return true
        }
    }

    public func collectionView(_ collectionView: UICollectionView, shouldDeselectItemAt indexPath: IndexPath) -> Bool {
        guard !galleryDates.isEmpty else { return false }

        switch indexPath.section {
            case loadNewerSectionIdx, kLoadOlderSectionIdx: return false
            default: return true
        }
    }

    public func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard !galleryDates.isEmpty else { return false }

        switch indexPath.section {
            case loadNewerSectionIdx, kLoadOlderSectionIdx: return false
            default: return true
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let gridCell = self.collectionView(collectionView, cellForItemAt: indexPath) as? PhotoGridViewCell else {
            owsFailDebug("galleryCell was unexpectedly nil")
            return
        }

        guard let galleryItem = (gridCell.item as? GalleryGridCellItem)?.galleryItem else {
            owsFailDebug("galleryItem was unexpectedly nil")
            return
        }

        if isInBatchSelectMode {
            updateDeleteButton()
        }
        else {
            collectionView.deselectItem(at: indexPath, animated: true)
            self.delegate?.mediaTileViewController(self, didTapView: gridCell.imageView, mediaGalleryItem: galleryItem)
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if isInBatchSelectMode {
            updateDeleteButton()
        }
    }

    // MARK: - UICollectionViewDataSource

    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        guard !galleryDates.isEmpty else { return 1 } // Empty state if empty

        // One for each galleryDate plus a "loading older" and "loading newer" section
        return galleryItems.keys.count + 2
    }

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection sectionIdx: Int) -> Int {
        guard !galleryDates.isEmpty else { return 0 }

        if sectionIdx == loadNewerSectionIdx { return 0 }   // Load more recent
        if sectionIdx == kLoadOlderSectionIdx { return 0 }  // Load older

        guard let sectionDate = self.galleryDates[safe: sectionIdx - 1] else {
            owsFailDebug("unknown section: \(sectionIdx)")
            return 0
        }

        guard let section = self.galleryItems[sectionDate] else {
            owsFailDebug("no section for date: \(sectionDate)")
            return 0
        }

        return section.count
    }

    public func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {

        let defaultView = UICollectionReusableView()

        guard galleryDates.count > 0 else {
            guard let sectionHeader = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: MediaGalleryStaticHeader.reuseIdentifier, for: indexPath) as? MediaGalleryStaticHeader else {

                owsFailDebug("unable to build section header for kLoadOlderSectionIdx")
                return defaultView
            }
            let title = NSLocalizedString("GALLERY_TILES_EMPTY_GALLERY", comment: "Label indicating media gallery is empty")
            sectionHeader.configure(title: title)
            return sectionHeader
        }

        if (kind == UICollectionView.elementKindSectionHeader) {
            switch indexPath.section {
                case loadNewerSectionIdx:
                    guard let sectionHeader = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: MediaGalleryStaticHeader.reuseIdentifier, for: indexPath) as? MediaGalleryStaticHeader else {

                        owsFailDebug("unable to build section header for kLoadOlderSectionIdx")
                        return defaultView
                    }
                    let title = NSLocalizedString("GALLERY_TILES_LOADING_MORE_RECENT_LABEL", comment: "Label indicating loading is in progress")
                    sectionHeader.configure(title: title)
                    return sectionHeader
                    
                case kLoadOlderSectionIdx:
                    guard let sectionHeader = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: MediaGalleryStaticHeader.reuseIdentifier, for: indexPath) as? MediaGalleryStaticHeader else {

                        owsFailDebug("unable to build section header for kLoadOlderSectionIdx")
                        return defaultView
                    }
                    let title = NSLocalizedString("GALLERY_TILES_LOADING_OLDER_LABEL", comment: "Label indicating loading is in progress")
                    sectionHeader.configure(title: title)
                    return sectionHeader
                    
                default:
                    guard let sectionHeader = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: MediaGallerySectionHeader.reuseIdentifier, for: indexPath) as? MediaGallerySectionHeader else {
                        owsFailDebug("unable to build section header for indexPath: \(indexPath)")
                        return defaultView
                    }
                    guard let date = self.galleryDates[safe: indexPath.section - 1] else {
                        owsFailDebug("unknown section for indexPath: \(indexPath)")
                        return defaultView
                    }

                    sectionHeader.configure(title: date.localizedString)
                    return sectionHeader
            }
        }

        return defaultView
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        Logger.debug("indexPath: \(indexPath)")

        let defaultCell = UICollectionViewCell()

        guard galleryDates.count > 0 else {
            owsFailDebug("unexpected cell for loadNewerSectionIdx")
            return defaultCell
        }

        switch indexPath.section {
            case loadNewerSectionIdx:
                owsFailDebug("unexpected cell for loadNewerSectionIdx")
                return defaultCell
                
            case kLoadOlderSectionIdx:
                owsFailDebug("unexpected cell for kLoadOlderSectionIdx")
                return defaultCell
                
            default:
                guard let galleryItem = galleryItem(at: indexPath) else {
                    owsFailDebug("no message for path: \(indexPath)")
                    return defaultCell
                }

                guard let cell = self.collectionView.dequeueReusableCell(withReuseIdentifier: PhotoGridViewCell.reuseIdentifier, for: indexPath) as? PhotoGridViewCell else {
                    owsFailDebug("unexpected cell for indexPath: \(indexPath)")
                    return defaultCell
                }

                let gridCellItem = GalleryGridCellItem(galleryItem: galleryItem)
                cell.configure(item: gridCellItem)

                return cell
        }
    }

    func galleryItem(at indexPath: IndexPath) -> MediaGalleryItem? {
        guard let sectionDate = self.galleryDates[safe: indexPath.section - 1] else {
            owsFailDebug("unknown section: \(indexPath.section)")
            return nil
        }

        guard let sectionItems = self.galleryItems[sectionDate] else {
            owsFailDebug("no section for date: \(sectionDate)")
            return nil
        }

        guard let galleryItem = sectionItems[safe: indexPath.row] else {
            owsFailDebug("no message for row: \(indexPath.row)")
            return nil
        }

        return galleryItem
    }
    
    private func indexPath(galleryItem: MediaGalleryItem) -> IndexPath? {
        guard let sectionIdx = galleryDates.firstIndex(of: galleryItem.galleryDate) else {
            return nil
        }
        guard let rowIdx = galleryItems[galleryItem.galleryDate]!.firstIndex(of: galleryItem) else {
            return nil
        }

        return IndexPath(row: rowIdx, section: sectionIdx + 1)
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    func updateLayout() {
        let firstItemSection: Int = (kLoadOlderSectionIdx + 1)
        let screenWidth: CGFloat = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let approxItemWidth: CGFloat = (screenWidth / MediaTileViewController.kItemsPerPortraitRow)
        let itemSectionInsets: UIEdgeInsets = collectionView(collectionView, layout: mediaTileViewLayout, insetForSectionAt: firstItemSection)
        let widthInset: CGFloat = (itemSectionInsets.left + itemSectionInsets.right)
        let containerWidth: CGFloat = (collectionView.frame.width > CGFloat.leastNonzeroMagnitude ?
            collectionView.frame.width :
            view.bounds.width
        )
        let collectionViewWidth: CGFloat = (containerWidth - widthInset)
        let itemCount: CGFloat = round(collectionViewWidth / approxItemWidth)
        let spaceWidth: CGFloat = ((itemCount - 1) * MediaTileViewController.kInterItemSpacing)
        let availableWidth: CGFloat = (collectionViewWidth - spaceWidth)

        let itemWidth = floor(availableWidth / CGFloat(itemCount))
        let newItemSize = CGSize(width: itemWidth, height: itemWidth)

        if (newItemSize != mediaTileViewLayout.itemSize) {
            mediaTileViewLayout.itemSize = newItemSize
            mediaTileViewLayout.invalidateLayout()
        }
    }
    
    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        guard !galleryDates.isEmpty else { return .zero }
        guard section != loadNewerSectionIdx && section != kLoadOlderSectionIdx else { return .zero }
        
        return UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    }

    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {

        let kMonthHeaderSize: CGSize = CGSize(width: 0, height: 50)
        let kStaticHeaderSize: CGSize = CGSize(width: 0, height: 100)

        guard galleryDates.count > 0 else {
            return kStaticHeaderSize
        }

        guard let mediaGalleryDataSource = self.mediaGalleryDataSource else {
            owsFailDebug("mediaGalleryDataSource was unexpectedly nil")
            return CGSize.zero
        }

        switch section {
            case loadNewerSectionIdx:
                // Show "loading newer..." if there is still more recent data to be fetched
                return mediaGalleryDataSource.hasFetchedMostRecent ? CGSize.zero : kStaticHeaderSize
                
            case kLoadOlderSectionIdx:
                // Show "loading older..." if there is still older data to be fetched
                return mediaGalleryDataSource.hasFetchedOldest ? CGSize.zero : kStaticHeaderSize
                
            default: return kMonthHeaderSize
        }
    }

    // MARK: - Batch Selection

    func updateDeleteButton() {
        if let count = collectionView.indexPathsForSelectedItems?.count, count > 0 {
            self.deleteButton.isEnabled = true
        }
        else {
            self.deleteButton.isEnabled = false
        }
    }

    func updateSelectButton() {
        if isInBatchSelectMode {
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(didCancelSelect))
        }
        else {
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: NSLocalizedString("BUTTON_SELECT", comment: "Button text to enable batch selection mode"),
                style: .plain,
                target: self,
                action: #selector(didTapSelect)
            )
        }
    }

    @objc func didTapSelect(_ sender: Any) {
        isInBatchSelectMode = true

        // Show toolbar
        UIView.animate(withDuration: 0.1, delay: 0, options: .curveEaseInOut, animations: { [weak self] in
            self?.footerBarBottomConstraint?.isActive = false
            self?.footerBarBottomConstraint = self?.footerBar.autoPinEdge(toSuperviewSafeArea: .bottom)
            self?.footerBar.superview?.layoutIfNeeded()

            // Ensure toolbar doesn't cover bottom row.
            self?.collectionView.contentInset.bottom += MediaTileViewController.kFooterBarHeight
        }, completion: nil)

        // disabled until at least one item is selected
        self.deleteButton.isEnabled = false

        // Don't allow the user to leave mid-selection, so they realized they have
        // to cancel (lose) their selection if they leave.
        self.navigationItem.hidesBackButton = true
    }

    @objc func didCancelSelect(_ sender: Any) {
        endSelectMode()
    }

    func endSelectMode() {
        isInBatchSelectMode = false

        // Hide toolbar
        UIView.animate(withDuration: 0.1, delay: 0, options: .curveEaseInOut, animations: { [weak self] in
            self?.footerBarBottomConstraint?.isActive = false
            self?.footerBarBottomConstraint = self?.footerBar.autoPinEdge(toSuperviewEdge: .bottom, withInset: -MediaTileViewController.kFooterBarHeight)
            self?.footerBar.superview?.layoutIfNeeded()

            // Undo "ensure toolbar doesn't cover bottom row."
            self?.collectionView.contentInset.bottom -= MediaTileViewController.kFooterBarHeight
        }, completion: nil)

        self.navigationItem.hidesBackButton = false

        // Deselect any selected
        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: false)}
    }

    @objc func didPressDelete(_ sender: Any) {
        guard let indexPaths = collectionView.indexPathsForSelectedItems else {
            owsFailDebug("indexPaths was unexpectedly nil")
            return
        }

        let items: [MediaGalleryItem] = indexPaths.compactMap { return self.galleryItem(at: $0) }

        guard let mediaGalleryDataSource = self.mediaGalleryDataSource else {
            owsFailDebug("mediaGalleryDataSource was unexpectedly nil")
            return
        }

        let confirmationTitle: String = {
            if indexPaths.count == 1 {
                return NSLocalizedString("MEDIA_GALLERY_DELETE_SINGLE_MESSAGE", comment: "Confirmation button text to delete selected media message from the gallery")
            }
            
            let format = NSLocalizedString("MEDIA_GALLERY_DELETE_MULTIPLE_MESSAGES_FORMAT", comment: "Confirmation button text to delete selected media from the gallery, embeds {{number of messages}}")
            return String(format: format, indexPaths.count)
        }()

        let deleteAction = UIAlertAction(title: confirmationTitle, style: .destructive) { _ in
            mediaGalleryDataSource.delete(items: items, initiatedBy: self)
            self.endSelectMode()
        }

        let actionSheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        actionSheet.addAction(deleteAction)
        actionSheet.addAction(OWSAlerts.cancelAction)

        presentAlert(actionSheet)
    }
    

    // MARK: - MediaGalleryDataSourceDelegate

    func mediaGalleryDataSource(_ mediaGalleryDataSource: MediaGalleryDataSource, willDelete items: [MediaGalleryItem], initiatedBy: AnyObject) {
        // We've got to lay out the collectionView before any changes are made to the date source
        // otherwise we'll fail when we try to remove the deleted sections/rows
        collectionView.layoutIfNeeded()
    }

    func mediaGalleryDataSource(_ mediaGalleryDataSource: MediaGalleryDataSource, deletedSections: IndexSet, deletedItems: [IndexPath]) {
        Logger.debug("with deletedSections: \(deletedSections) deletedItems: \(deletedItems)")

        guard mediaGalleryDataSource.galleryItemCount > 0  else {
            // Show Empty
            self.collectionView.reloadData()
            return
        }

        collectionView.performBatchUpdates({
            collectionView.deleteSections(deletedSections)
            collectionView.deleteItems(at: deletedItems)
        })
    }

    // MARK: - Lazy Loading

    var oldestLoadedItem: MediaGalleryItem? {
        guard let oldestDate = galleryDates.first else {
            return nil
        }

        return galleryItems[oldestDate]?.first
    }

    var mostRecentLoadedItem: MediaGalleryItem? {
        guard let mostRecentDate = galleryDates.last else {
            return nil
        }

        return galleryItems[mostRecentDate]?.last
    }

    var isFetchingMoreData: Bool = false

    let loadNewerSectionIdx = 0
    var kLoadOlderSectionIdx: Int {
        return galleryDates.count + 1
    }

    public func autoLoadMoreIfNecessary() {
        guard !isUserScrolling else { return }
        guard !isFetchingMoreData else { return }

        guard let mediaGalleryDataSource = self.mediaGalleryDataSource else {
            owsFailDebug("mediaGalleryDataSource was unexpectedly nil")
            return
        }

        let kEdgeThreshold: CGFloat = 800
        let contentOffsetY = self.collectionView.contentOffset.y
        let oldContentHeight = self.collectionView.contentSize.height
        let needsMoreRecentContent: Bool = (
            !mediaGalleryDataSource.hasFetchedMostRecent && (
                oldContentHeight < self.collectionView.frame.height ||
                contentOffsetY < kEdgeThreshold
            )
        )
        let needsOlderContent: Bool = (
            !mediaGalleryDataSource.hasFetchedOldest && (
                oldContentHeight < self.collectionView.frame.height ||
                (oldContentHeight - contentOffsetY) < kEdgeThreshold
            )
        )

        // Near the top, load newer content
        if needsMoreRecentContent {
            guard let mostRecentLoadedItem = self.mostRecentLoadedItem else {
                Logger.debug("no mostRecent item")
                return
            }

            self.isFetchingMoreData = true

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            UIView.performWithoutAnimation {
                // mediaTileViewLayout will adjust content offset to compensate for the change in content height so that
                // the same content is visible after the update. I considered doing something like setContentOffset in the
                // batchUpdate completion block, but it caused a distinct flicker, which I was able to avoid with the
                // `CollectionViewLayout.prepare` based approach.
                self.mediaTileViewLayout.isInsertingCellsToTop = true
                self.mediaTileViewLayout.contentSizeBeforeInsertingToTop = self.collectionView.contentSize
                self.collectionView.performBatchUpdates({ [weak self] in
                    mediaGalleryDataSource.ensureGalleryItemsLoaded(.after, item: mostRecentLoadedItem, amount: MediaTileViewController.kMediaTileViewLoadBatchSize) { addedSections, addedItems in
                        Logger.debug("insertingSections: \(addedSections), items: \(addedItems)")
                        self?.collectionView.insertSections(addedSections)
                        self?.collectionView.insertItems(at: addedItems)
                    }
                }, completion: { [weak self] finished in
                    Logger.debug("performBatchUpdates finished: \(finished)")
                    self?.isFetchingMoreData = false
                    CATransaction.commit()
                })
            }
        }
        
        // Near the bottom (or not enough content to fill the screen), load older content
        if needsOlderContent {
            guard let oldestLoadedItem = self.oldestLoadedItem else {
                Logger.debug("no oldest item")
                return
            }

            self.isFetchingMoreData = true

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            
            self.collectionView.performBatchUpdates({ [weak self] in
                mediaGalleryDataSource.ensureGalleryItemsLoaded(.before, item: oldestLoadedItem, amount: MediaTileViewController.kMediaTileViewLoadBatchSize) { addedSections, addedItems in
                    Logger.debug("insertingSections: \(addedSections) items: \(addedItems)")

                    self?.collectionView.insertSections(addedSections)
                    self?.collectionView.insertItems(at: addedItems)
                }
            }, completion: { [weak self] finished in
                Logger.debug("performBatchUpdates finished: \(finished)")
                self?.isFetchingMoreData = false
                CATransaction.commit()
            })
        }
    }
}

// MARK: - Private Helper Classes

// Accomodates remaining scrolled to the same "apparent" position when new content is inserted
// into the top of a collectionView. There are multiple ways to solve this problem, but this
// is the only one which avoided a perceptible flicker.
private class MediaTileViewLayout: UICollectionViewFlowLayout {
    static let kDecorationViewKind: String = "SectionBackgroundView"
    
    fileprivate var isInsertingCellsToTop: Bool = false
    fileprivate var contentSizeBeforeInsertingToTop: CGSize?
            
    override init() {
        super.init()
        
        self.register(
            MediaGallerySectionBackground.self,
            forDecorationViewOfKind: MediaTileViewLayout.kDecorationViewKind
        )
    }
            
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        self.register(
            MediaGallerySectionBackground.self,
            forDecorationViewOfKind: MediaTileViewLayout.kDecorationViewKind
        )
    }
            
    override public func prepare() {
        super.prepare()

        if isInsertingCellsToTop {
            if let collectionView = collectionView, let oldContentSize = contentSizeBeforeInsertingToTop {
                let newContentSize = collectionViewContentSize
                let contentOffsetY = collectionView.contentOffset.y + (newContentSize.height - oldContentSize.height)
                let newOffset = CGPoint(x: collectionView.contentOffset.x, y: contentOffsetY)
                collectionView.setContentOffset(newOffset, animated: false)
            }
            contentSizeBeforeInsertingToTop = nil
            isInsertingCellsToTop = false
        }
    }
    
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let allAttributes: [UICollectionViewLayoutAttributes] = super.layoutAttributesForElements(in: rect) else {
            return nil
        }
        
        var newAttributes: [UICollectionViewLayoutAttributes] = []
        
        allAttributes.forEach { attributes in
            guard attributes.indexPath.item == 0 else { return }
            guard (self.collectionView?.numberOfItems(inSection: attributes.indexPath.section) ?? 0) > 0 else {
                return
            }
            guard let sectionBackgroundAttrs: UICollectionViewLayoutAttributes = self.layoutAttributesForDecorationView(ofKind: MediaTileViewLayout.kDecorationViewKind, at: attributes.indexPath) else {
                return
            }
            
            newAttributes.append(sectionBackgroundAttrs)
        }
        
        return allAttributes.appending(contentsOf: newAttributes)
    }
    
    override func layoutAttributesForDecorationView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard elementKind == MediaTileViewLayout.kDecorationViewKind, let collectionView: UICollectionView = collectionView else {
            return super.layoutAttributesForDecorationView(ofKind: elementKind, at: indexPath)
        }
        
        let numItems: Int = (self.collectionView?.numberOfItems(inSection: indexPath.section) ?? 0)
        let firstIndexPath: IndexPath = IndexPath(item: 0, section: indexPath.section)
        let lastIndexPath: IndexPath = IndexPath(item: numItems - 1, section: indexPath.section)
        
        guard numItems > 0 else { return nil }
        guard let firstAttrs: UICollectionViewLayoutAttributes = self.layoutAttributesForItem(at: firstIndexPath) else {
            return nil
        }
        guard let lastAttrs: UICollectionViewLayoutAttributes = self.layoutAttributesForItem(at: lastIndexPath) else {
            return nil
        }
        
        let specificSectionInsets: UIEdgeInsets? = (collectionView.delegate as? UICollectionViewDelegateFlowLayout)?.collectionView?(collectionView, layout: self, insetForSectionAt: indexPath.section)
        let insets: UIEdgeInsets = (specificSectionInsets ?? sectionInset)
        let attrs: UICollectionViewLayoutAttributes = UICollectionViewLayoutAttributes(
            forDecorationViewOfKind: MediaTileViewLayout.kDecorationViewKind,
            with: indexPath
        )
        attrs.frame = CGRect(
            x: (firstAttrs.frame.minX - 10),
            y: (firstAttrs.frame.minY - 10),
            width: (collectionView.frame.width - ((insets.left + insets.right) - (10 * 2))),
            height: ((lastAttrs.frame.maxY - (firstAttrs.frame.minY - 10)) + 10)
        )
        attrs.zIndex = -1
        
        return attrs
    }
    
    override func initialLayoutAttributesForAppearingDecorationElement(ofKind elementKind: String, at decorationIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attrs: UICollectionViewLayoutAttributes = super.initialLayoutAttributesForAppearingDecorationElement(ofKind: elementKind, at: decorationIndexPath) else {
            return nil
        }
        guard elementKind == MediaTileViewLayout.kDecorationViewKind else { return attrs }
        
        attrs.alpha = 0
        
        return attrs
    }
    
    override func finalLayoutAttributesForDisappearingDecorationElement(ofKind elementKind: String, at decorationIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attrs: UICollectionViewLayoutAttributes = super.initialLayoutAttributesForAppearingDecorationElement(ofKind: elementKind, at: decorationIndexPath) else {
            return nil
        }
        guard elementKind == MediaTileViewLayout.kDecorationViewKind else { return attrs }
        
        attrs.alpha = 0
        
        return attrs
    }
}

// MARK: -

private class MediaGallerySectionHeader: UICollectionReusableView {
    static let reuseIdentifier = "MediaGallerySectionHeader"

    private let label: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.ows_mediumFont(withSize: Values.mediumFontSize)
        label.textColor = Colors.text
        
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        
        backgroundColor = Colors.settingsBackground
        addSubview(label)

        setupLayout()
    }

    @available(*, unavailable, message: "Unimplemented")
    required init?(coder aDecoder: NSCoder) {
        notImplemented()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leftAnchor.constraint(equalTo: leftAnchor, constant: 10),
            label.rightAnchor.constraint(equalTo: rightAnchor, constant: -10)
        ])
    }
    
    // MARK: - Content
    
    override public func prepareForReuse() {
        super.prepareForReuse()

        label.text = nil
    }

    public func configure(title: String) {
        label.text = title
    }
}

// MARK: -

private class MediaGallerySectionBackground: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        backgroundColor = Colors.cellBackground
        layer.cornerRadius = 8
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        backgroundColor = Colors.cellBackground
        layer.cornerRadius = 8
    }
}

// MARK: -

private class MediaGalleryStaticHeader: UICollectionViewCell {

    static let reuseIdentifier = "MediaGalleryStaticHeader"

    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(label)

        label.textColor = Theme.darkThemePrimaryColor
        label.textAlignment = .center
        label.numberOfLines = 0
        label.autoPinEdgesToSuperviewMargins(with: UIEdgeInsets(top: 0, leading: Values.largeSpacing, bottom: 0, trailing: Values.largeSpacing))
    }

    @available(*, unavailable, message: "Unimplemented")
    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    public func configure(title: String) {
        self.label.text = title
    }

    public override func prepareForReuse() {
        self.label.text = nil
    }
}

// MARK: -

class GalleryGridCellItem: PhotoGridItem {
    let galleryItem: MediaGalleryItem

    init(galleryItem: MediaGalleryItem) {
        self.galleryItem = galleryItem
    }

    var type: PhotoGridItemType {
        if galleryItem.isVideo {
            return .video
        }
        
        if galleryItem.isAnimated {
            return .animated
        }
        
        return .photo
    }

    func asyncThumbnail(completion: @escaping (UIImage?) -> Void) -> UIImage? {
        return galleryItem.thumbnailImage(async: completion)
    }
}

// MARK: - UIViewControllerTransitioningDelegate

extension MediaTileViewController: UIViewControllerTransitioningDelegate {
    public func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard self == presented || self.navigationController == presented else { return nil }
        guard let focusedItem = self.focusedItem else { return nil }
        
        return MediaDismissAnimationController(galleryItem: focusedItem)
    }

    public func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard self == dismissed || self.navigationController == dismissed else { return nil }
        guard let focusedItem = self.focusedItem else { return nil }

        return MediaZoomAnimationController(galleryItem: focusedItem)
    }
}

// MARK: - MediaPresentationContextProvider

extension MediaTileViewController: MediaPresentationContextProvider {
    func mediaPresentationContext(item: Media, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext? {
        guard case let .gallery(galleryItem) = item else { return nil }
        guard let indexPath: IndexPath = indexPath(galleryItem: galleryItem) else { return nil }
        
        guard let visibleIndex = collectionView.indexPathsForVisibleItems.firstIndex(of: indexPath) else {
            // This could happen if, after presenting media, you navigated within the gallery
            // to media not within the collectionView's visible bounds.
            return nil
        }
        guard let gridCell = collectionView.visibleCells[safe: visibleIndex] as? PhotoGridViewCell else {
            return nil
        }
        guard let mediaSuperview: UIView = gridCell.imageView.superview else { return nil }

        let presentationFrame = coordinateSpace.convert(gridCell.imageView.frame, from: mediaSuperview)
        
        return MediaPresentationContext(
            mediaView: gridCell.imageView,
            presentationFrame: presentationFrame,
            cornerRadius: 0,
            cornerMask: CACornerMask()
        )
    }

    func snapshotOverlayView(in coordinateSpace: UICoordinateSpace) -> (UIView, CGRect)? {
        return self.navigationController?.navigationBar.generateSnapshot(in: coordinateSpace)
    }
}
