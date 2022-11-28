// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble

@testable import Session

class ThreadSettingsViewModelSpec: QuickSpec {
    typealias ViewModelType = SessionTableViewModel<ThreadSettingsViewModel.NavButton, ThreadSettingsViewModel.Section, ThreadSettingsViewModel.Setting>
    
    // MARK: - Spec
    
    override func spec() {
        var mockStorage: Storage!
        var mockGeneralCache: MockGeneralCache!
        var cancellables: [AnyCancellable] = []
        var dependencies: Dependencies!
        var viewModel: ThreadSettingsViewModel!
        var didTriggerSearchCallbackTriggered: Bool = false
        var transitionInfo: (viewController: UIViewController, transitionType: TransitionType)!
        
        describe("a ThreadSettingsViewModel") {
            // MARK: - Configuration
            
            beforeEach {
                mockStorage = SynchronousStorage(
                    customWriter: try! DatabaseQueue(),
                    customMigrations: [
                        SNUtilitiesKit.migrations(),
                        SNSnodeKit.migrations(),
                        SNMessagingKit.migrations(),
                        SNUIKit.migrations()
                    ]
                )
                mockGeneralCache = MockGeneralCache()
                dependencies = Dependencies(
                    generalCache: Atomic(mockGeneralCache),
                    storage: mockStorage,
                    scheduler: .immediate
                )
                mockGeneralCache.when { $0.encodedPublicKey }.thenReturn("05\(TestConstants.publicKey)")
                mockStorage.write { db in
                    try SessionThread(
                        id: "TestId",
                        variant: .contact
                    ).insert(db)
                    
                    try Identity(
                        variant: .x25519PublicKey,
                        data: Data(hex: TestConstants.publicKey)
                    ).insert(db)
                    
                    try Profile(
                        id: "05\(TestConstants.publicKey)",
                        name: "TestMe"
                    ).insert(db)
                    
                    try Profile(
                        id: "TestId",
                        name: "TestUser"
                    ).insert(db)
                }
                viewModel = ThreadSettingsViewModel(
                    dependencies: dependencies,
                    threadId: "TestId",
                    threadVariant: .contact,
                    didTriggerSearch: {
                        didTriggerSearchCallbackTriggered = true
                    }
                )
                setupStandardBinding()
            }
            
            func setupStandardBinding() {
                cancellables.append(
                    viewModel.observableTableData
                        .receiveOnMain(immediately: true)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateTableData($0.0) }
                        )
                )
                cancellables.append(
                    viewModel.transitionToScreen
                        .receiveOnMain(immediately: true)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { transitionInfo = $0 }
                        )
                )
            }
            
            afterEach {
                cancellables.forEach { $0.cancel() }
                
                mockStorage = nil
                cancellables = []
                dependencies = nil
                viewModel = nil
                didTriggerSearchCallbackTriggered = false
                transitionInfo = nil
            }
            
            // MARK: - Basic Tests
            
            context("with any conversation type") {
                it("triggers the search callback when tapping search") {
                    viewModel.tableData
                        .first(where: { $0.model == .content })?
                        .elements
                        .first(where: { $0.id == .searchConversation })?
                        .onTap?()
                    
                    expect(didTriggerSearchCallbackTriggered).to(beTrue())
                }
                
                it("takes the user to notification settings") {
                    typealias ViewControllerType = SessionTableViewController<ThreadNotificationSettingsViewModel.NavButton, ThreadNotificationSettingsViewModel.Section, ThreadNotificationSettingsViewModel.Item>
                    
                    viewModel.tableData
                        .first(where: { $0.model == .content })?
                        .elements
                        .first(where: { $0.id == .notifications })?
                        .onTap?()
                    
                    expect(transitionInfo.transitionType).to(equal(.push))
                    expect((transitionInfo.viewController as? ViewControllerType)?.viewModelType)
                        .to(beAKindOf(ThreadNotificationSettingsViewModel.Type.self))
                }
            }
            
            context("with a note-to-self conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "05\(TestConstants.publicKey)",
                            variant: .contact
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        dependencies: dependencies,
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        }
                    )
                    setupStandardBinding()
                }
                
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_settings_title".localized()))
                }
                
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue())
                        .to(equal([
                            ViewModelType.NavItem(
                                id: .edit,
                                systemItem: .edit,
                                accessibilityIdentifier: "Edit button"
                            )
                        ]))
                }
                
                it("has no notifications item") {
                    expect(
                        viewModel.tableData
                            .first(where: { $0.model == .content })?
                            .elements
                            .first(where: { $0.id == .notifications })
                    ).to(beNil())
                }
                
                context("when entering edit mode") {
                    beforeEach {
                        viewModel.rightNavItems.firstValue()??.first?.action?()
                        viewModel.textChanged("TestNew", for: .nickname)
                        // TODO: Enter edit mode by pressing on the first item
//                        viewModel.tableData.first?
//                            .elements.first?
//                            .onTap?()
                    }
                    
                    it("enters the editing state") {
                        expect(viewModel.navState.firstValue())
                            .to(equal(.editing))
                        
                        expect(viewModel.leftNavItems.firstValue())
                            .to(equal([
                                ViewModelType.NavItem(
                                    id: .cancel,
                                    systemItem: .cancel,
                                    accessibilityIdentifier: "Cancel button"
                                )
                            ]))
                        expect(viewModel.rightNavItems.firstValue())
                            .to(equal([
                                ViewModelType.NavItem(
                                    id: .done,
                                    systemItem: .done,
                                    accessibilityIdentifier: "Done button"
                                )
                            ]))
                    }
                    
                    context("when cancelling edit mode") {
                        beforeEach {
                            viewModel.leftNavItems.firstValue()??.first?.action?()
                        }
                        
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    ViewModelType.NavItem(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        it("does not update the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in
                                        try Profile.fetchOne(db, id: "05\(TestConstants.publicKey)")
                                    }?
                                    .nickname
                            )
                            .to(beNil())
                        }
                    }
                    
                    context("when saving edit mode") {
                        beforeEach {
                            viewModel.rightNavItems.firstValue()??.first?.action?()
                        }
                        
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    ViewModelType.NavItem(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        it("updates the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in
                                        try Profile.fetchOne(db, id: "05\(TestConstants.publicKey)")
                                    }?
                                    .nickname
                            )
                            .to(equal("TestNew"))
                        }
                    }
                }
            }
            
            context("with a one-to-one conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .contact
                        ).insert(db)
                    }
                }
                
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_settings_title".localized()))
                }
                
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue())
                        .to(equal([
                            ViewModelType.NavItem(
                                id: .edit,
                                systemItem: .edit,
                                accessibilityIdentifier: "Edit button"
                            )
                        ]))
                }
                
                context("when entering edit mode") {
                    beforeEach {
                        viewModel.rightNavItems.firstValue()??.first?.action?()
                        viewModel.textChanged("TestUserNew", for: .nickname)
                        
                        // TODO: Enter edit mode by pressing on the first item
//                       viewModel.tableData.first?
//                           .elements.first?
//                           .onTap?()
                    }
                    
                    it("enters the editing state") {
                        expect(viewModel.navState.firstValue())
                            .to(equal(.editing))
                        
                        expect(viewModel.leftNavItems.firstValue())
                            .to(equal([
                                ViewModelType.NavItem(
                                    id: .cancel,
                                    systemItem: .cancel,
                                    accessibilityIdentifier: "Cancel button"
                                )
                            ]))
                        expect(viewModel.rightNavItems.firstValue())
                            .to(equal([
                                ViewModelType.NavItem(
                                    id: .done,
                                    systemItem: .done,
                                    accessibilityIdentifier: "Done button"
                                )
                            ]))
                    }
                    
                    context("when cancelling edit mode") {
                        beforeEach {
                            viewModel.leftNavItems.firstValue()??.first?.action?()
                        }
                        
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    ViewModelType.NavItem(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        it("does not update the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in try Profile.fetchOne(db, id: "TestId") }?
                                    .nickname
                            )
                            .to(beNil())
                        }
                    }
                    
                    context("when saving edit mode") {
                        beforeEach {
                            viewModel.rightNavItems.firstValue()??.first?.action?()
                        }
                        
                        it("exits editing mode") {
                            expect(viewModel.navState.firstValue())
                                .to(equal(.standard))
                            
                            expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                            expect(viewModel.rightNavItems.firstValue())
                                .to(equal([
                                    ViewModelType.NavItem(
                                        id: .edit,
                                        systemItem: .edit,
                                        accessibilityIdentifier: "Edit button"
                                    )
                                ]))
                        }
                        
                        it("updates the nickname for the current user") {
                            expect(
                                mockStorage
                                    .read { db in try Profile.fetchOne(db, id: "TestId") }?
                                    .nickname
                            )
                            .to(equal("TestUserNew"))
                        }
                    }
                }
            }
            
            context("with a group conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .closedGroup
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        dependencies: dependencies,
                        threadId: "TestId",
                        threadVariant: .closedGroup,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        }
                    )
                    setupStandardBinding()
                }
                
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_group_settings_title".localized()))
                }
                
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue()).to(equal([]))
                }
            }
            
            context("with a community conversation") {
                beforeEach {
                    mockStorage.write { db in
                        try SessionThread.deleteAll(db)
                        
                        try SessionThread(
                            id: "TestId",
                            variant: .openGroup
                        ).insert(db)
                    }
                    
                    viewModel = ThreadSettingsViewModel(
                        dependencies: dependencies,
                        threadId: "TestId",
                        threadVariant: .openGroup,
                        didTriggerSearch: {
                            didTriggerSearchCallbackTriggered = true
                        }
                    )
                    setupStandardBinding()
                }
                
                it("has the correct title") {
                    expect(viewModel.title).to(equal("vc_group_settings_title".localized()))
                }
                
                it("starts in the standard nav state") {
                    expect(viewModel.navState.firstValue())
                        .to(equal(.standard))
                    
                    expect(viewModel.leftNavItems.firstValue()).to(equal([]))
                    expect(viewModel.rightNavItems.firstValue()).to(equal([]))
                }
            }
        }
    }
}
