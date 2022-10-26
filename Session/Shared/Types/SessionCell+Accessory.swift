// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

extension SessionCell {
    public enum Accessory: Hashable, Equatable {
        case icon(
            UIImage?,
            size: IconSize,
            customTint: ThemeValue?,
            shouldFill: Bool
        )
        case iconAsync(
            size: IconSize,
            customTint: ThemeValue?,
            shouldFill: Bool,
            setter: (UIImageView) -> Void
        )
        case toggle(DataSource)
        case dropDown(DataSource)
        case radio(
            size: RadioSize,
            isSelected: () -> Bool,
            storedSelection: Bool
        )
        
        case highlightingBackgroundLabel(title: String)
        case profile(
            id: String,
            size: IconSize,
            profile: Profile?,
            additionalProfile: Profile?,
            threadVariant: SessionThread.Variant,
            openGroupProfilePictureData: Data?,
            useFallbackPicture: Bool,
            showMultiAvatarForClosedGroup: Bool
        )
        
        case button(
            style: SessionButton.Style,
            title: String,
            run: (SessionButton?) -> ()
        )
        case customView(viewGenerator: () -> UIView)
        
        // MARK: - Convenience Vatiables
        
        var shouldFitToEdge: Bool {
            switch self {
                case .icon(_, _, _, let shouldFill), .iconAsync(_, _, let shouldFill, _): return shouldFill
                default: return false
            }
        }
        
        var currentBoolValue: Bool {
            switch self {
                case .toggle(let dataSource), .dropDown(let dataSource): return dataSource.currentBoolValue
                case .radio(_, let isSelected, _): return isSelected()
                default: return false
            }
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            switch self {
                case .icon(let image, let size, let customTint, let shouldFill):
                    image.hash(into: &hasher)
                    size.hash(into: &hasher)
                    customTint.hash(into: &hasher)
                    shouldFill.hash(into: &hasher)
                    
                case .iconAsync(let size, let customTint, let shouldFill, _):
                    size.hash(into: &hasher)
                    customTint.hash(into: &hasher)
                    shouldFill.hash(into: &hasher)
                    
                case .toggle(let dataSource):
                    dataSource.hash(into: &hasher)
                
                case .dropDown(let dataSource):
                    dataSource.hash(into: &hasher)
                    
                case .radio(let size, let isSelected, let storedSelection):
                    size.hash(into: &hasher)
                    isSelected().hash(into: &hasher)
                    storedSelection.hash(into: &hasher)
                
                case .highlightingBackgroundLabel(let title):
                    title.hash(into: &hasher)
                    
                case .profile(
                    let profileId,
                    let size,
                    let profile,
                    let additionalProfile,
                    let threadVariant,
                    let openGroupProfilePictureData,
                    let useFallbackPicture,
                    let showMultiAvatarForClosedGroup
                ):
                    profileId.hash(into: &hasher)
                    size.hash(into: &hasher)
                    profile.hash(into: &hasher)
                    additionalProfile.hash(into: &hasher)
                    threadVariant.hash(into: &hasher)
                    openGroupProfilePictureData.hash(into: &hasher)
                    useFallbackPicture.hash(into: &hasher)
                    showMultiAvatarForClosedGroup.hash(into: &hasher)
                    
                case .customView: break
                    
                case .button(let style, let title, _):
                    style.hash(into: &hasher)
                    title.hash(into: &hasher)
            }
        }
        
        public static func == (lhs: Accessory, rhs: Accessory) -> Bool {
            switch (lhs, rhs) {
                case (.icon(let lhsImage, let lhsSize, let lhsCustomTint, let lhsShouldFill), .icon(let rhsImage, let rhsSize, let rhsCustomTint, let rhsShouldFill)):
                    return (
                        lhsImage == rhsImage &&
                        lhsSize == rhsSize &&
                        lhsCustomTint == rhsCustomTint &&
                        lhsShouldFill == rhsShouldFill
                    )
                    
                case (.iconAsync(let lhsSize, let lhsCustomTint, let lhsShouldFill, _), .iconAsync(let rhsSize, let rhsCustomTint, let rhsShouldFill, _)):
                    return (
                        lhsSize == rhsSize &&
                        lhsCustomTint == rhsCustomTint &&
                        lhsShouldFill == rhsShouldFill
                    )
                
                case (.toggle(let lhsDataSource), .toggle(let rhsDataSource)):
                    return (lhsDataSource == rhsDataSource)
                    
                case (.dropDown(let lhsDataSource), .dropDown(let rhsDataSource)):
                    return (lhsDataSource == rhsDataSource)
                    
                case (.radio(let lhsSize, let lhsIsSelected, let lhsStoredSelection), .radio(let rhsSize, let rhsIsSelected, let rhsStoredSelection)):
                    return (
                        lhsSize == rhsSize &&
                        lhsIsSelected() == rhsIsSelected() &&
                        lhsStoredSelection == rhsStoredSelection
                    )
                    
                case (.highlightingBackgroundLabel(let lhsTitle), .highlightingBackgroundLabel(let rhsTitle)):
                    return (lhsTitle == rhsTitle)
                    
                case (
                    .profile(
                        let lhsProfileId,
                        let lhsSize,
                        let lhsProfile,
                        let lhsAdditionalProfile,
                        let lhsThreadVariant,
                        let lhsOpenGroupProfilePictureData,
                        let lhsUseFallbackPicture,
                        let lhsShowMultiAvatarForClosedGroup
                    ),
                    .profile(
                        let rhsProfileId,
                        let rhsSize,
                        let rhsProfile,
                        let rhsAdditionalProfile,
                        let rhsThreadVariant,
                        let rhsOpenGroupProfilePictureData,
                        let rhsUseFallbackPicture,
                        let rhsShowMultiAvatarForClosedGroup
                    )
                ):
                    return (
                        lhsProfileId == rhsProfileId &&
                        lhsSize == rhsSize &&
                        lhsProfile == rhsProfile &&
                        lhsAdditionalProfile == rhsAdditionalProfile &&
                        lhsThreadVariant == rhsThreadVariant &&
                        lhsOpenGroupProfilePictureData == rhsOpenGroupProfilePictureData &&
                        lhsUseFallbackPicture == rhsUseFallbackPicture &&
                        lhsShowMultiAvatarForClosedGroup == rhsShowMultiAvatarForClosedGroup
                    )
                    
                case (.customView, .customView): return false
                    
                case (.button(let lhsStyle, let lhsTitle, _), .button(let rhsStyle, let rhsTitle, _)):
                    return (
                        lhsStyle == rhsStyle &&
                        lhsTitle == rhsTitle
                    )
                
                default: return false
            }
        }
    }
}

// MARK: - Convenience Types

/// These are here because XCode doesn't realy like default values within enums so auto-complete and syntax
/// highlighting don't work properly
extension SessionCell.Accessory {
    // MARK: - .icon Variants
    
    public static func icon(_ image: UIImage?) -> SessionCell.Accessory {
        return .icon(image, size: .medium, customTint: nil, shouldFill: false)
    }
    
    public static func icon(_ image: UIImage?, customTint: ThemeValue) -> SessionCell.Accessory {
        return .icon(image, size: .medium, customTint: customTint, shouldFill: false)
    }
    
    public static func icon(_ image: UIImage?, size: IconSize) -> SessionCell.Accessory {
        return .icon(image, size: size, customTint: nil, shouldFill: false)
    }
    
    public static func icon(_ image: UIImage?, size: IconSize, customTint: ThemeValue) -> SessionCell.Accessory {
        return .icon(image, size: size, customTint: customTint, shouldFill: false)
    }
    
    public static func icon(_ image: UIImage?, shouldFill: Bool) -> SessionCell.Accessory {
        return .icon(image, size: .medium, customTint: nil, shouldFill: shouldFill)
    }
    
    // MARK: - .iconAsync Variants
    
    public static func iconAsync(_ setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: .medium, customTint: nil, shouldFill: false, setter: setter)
    }
    
    public static func iconAsync(customTint: ThemeValue, _ setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: .medium, customTint: customTint, shouldFill: false, setter: setter)
    }
    
    public static func iconAsync(size: IconSize, setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: size, customTint: nil, shouldFill: false, setter: setter)
    }
    
    public static func iconAsync(shouldFill: Bool, setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: .medium, customTint: nil, shouldFill: shouldFill, setter: setter)
    }
    
    public static func iconAsync(size: IconSize, customTint: ThemeValue, setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: size, customTint: customTint, shouldFill: false, setter: setter)
    }
    
    public static func iconAsync(size: IconSize, shouldFill: Bool, setter: @escaping (UIImageView) -> Void) -> SessionCell.Accessory {
        return .iconAsync(size: size, customTint: nil, shouldFill: shouldFill, setter: setter)
    }
    
    // MARK: - .profile Variants
    
    public static func profile(id: String, profile: Profile?) -> SessionCell.Accessory {
        return .profile(
            id: id,
            size: .large,
            profile: profile,
            additionalProfile: nil,
            threadVariant: .contact,
            openGroupProfilePictureData: nil,
            useFallbackPicture: false,
            showMultiAvatarForClosedGroup: false
        )
    }
    
    public static func profile(id: String, size: IconSize, profile: Profile?) -> SessionCell.Accessory {
        return .profile(
            id: id,
            size: size,
            profile: profile,
            additionalProfile: nil,
            threadVariant: .contact,
            openGroupProfilePictureData: nil,
            useFallbackPicture: false,
            showMultiAvatarForClosedGroup: false
        )
    }
    
    // MARK: - .radio Variants
    
    public static func radio(isSelected: @escaping () -> Bool) -> SessionCell.Accessory {
        return .radio(size: .medium, isSelected: isSelected, storedSelection: false)
    }
    
    public static func radio(isSelected: @escaping () -> Bool, storedSelection: Bool) -> SessionCell.Accessory {
        return .radio(size: .medium, isSelected: isSelected, storedSelection: storedSelection)
    }
}

// MARK: - SessionCell.Accessory.DataSource

extension SessionCell.Accessory {
    public enum DataSource: Hashable, Equatable {
        case boolValue(Bool)
        case dynamicString(() -> String?)
        case userDefaults(UserDefaults, key: String)
        case settingBool(key: Setting.BoolKey)
        
        // MARK: - Convenience
        
        public var currentBoolValue: Bool {
            switch self {
                case .boolValue(let value): return value
                case .dynamicString: return false
                case .userDefaults(let defaults, let key): return defaults.bool(forKey: key)
                case .settingBool(let key): return Storage.shared[key]
            }
        }
        
        public var currentStringValue: String? {
            switch self {
                case .dynamicString(let value): return value()
                default: return nil
            }
        }
        
        // MARK: - Conformance
        
        public func hash(into hasher: inout Hasher) {
            switch self {
                case .boolValue(let value): value.hash(into: &hasher)
                case .dynamicString(let generator): generator().hash(into: &hasher)
                case .userDefaults(_, let key): key.hash(into: &hasher)
                case .settingBool(let key): key.hash(into: &hasher)
            }
        }
        
        public static func == (lhs: DataSource, rhs: DataSource) -> Bool {
            switch (lhs, rhs) {
                case (.boolValue(let lhsValue), .boolValue(let rhsValue)):
                    return (lhsValue == rhsValue)
                    
                case (.dynamicString(let lhsGenerator), .dynamicString(let rhsGenerator)):
                    return (lhsGenerator() == rhsGenerator())
                    
                case (.userDefaults(_, let lhsKey), .userDefaults(_, let rhsKey)):
                    return (lhsKey == rhsKey)
                
                case (.settingBool(let lhsKey), .settingBool(let rhsKey)):
                    return (lhsKey == rhsKey)
                    
                default: return false
            }
        }
    }
}

// MARK: - SessionCell.Accessory.RadioSize

extension SessionCell.Accessory {
    public enum RadioSize {
        case small
        case medium
        
        var borderSize: CGFloat {
            switch self {
                case .small: return 20
                case .medium: return 26
            }
        }
        
        var selectionSize: CGFloat {
            switch self {
                case .small: return 15
                case .medium: return 20
            }
        }
    }
}
