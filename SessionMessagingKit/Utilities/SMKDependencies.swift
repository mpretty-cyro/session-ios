// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionSnodeKit
import SessionUtilitiesKit

public class SMKDependencies: Dependencies {
    internal var _requestApi: RequestAPIType.Type?
    public var requestApi: RequestAPIType.Type {
        get { Dependencies.getValueSettingIfNull(&_requestApi) { RequestAPI.self } }
        set { _requestApi = newValue }
    }
    
    internal var _sodium: SodiumType?
    public var sodium: SodiumType {
        get { Dependencies.getValueSettingIfNull(&_sodium) { Sodium() } }
        set { _sodium = newValue }
    }
    
    internal var _box: BoxType?
    public var box: BoxType {
        get { Dependencies.getValueSettingIfNull(&_box) { sodium.getBox() } }
        set { _box = newValue }
    }
    
    internal var _genericHash: GenericHashType?
    public var genericHash: GenericHashType {
        get { Dependencies.getValueSettingIfNull(&_genericHash) { sodium.getGenericHash() } }
        set { _genericHash = newValue }
    }
    
    internal var _sign: SignType?
    public var sign: SignType {
        get { Dependencies.getValueSettingIfNull(&_sign) { sodium.getSign() } }
        set { _sign = newValue }
    }
    
    internal var _aeadXChaCha20Poly1305Ietf: AeadXChaCha20Poly1305IetfType?
    public var aeadXChaCha20Poly1305Ietf: AeadXChaCha20Poly1305IetfType {
        get { Dependencies.getValueSettingIfNull(&_aeadXChaCha20Poly1305Ietf) { sodium.getAeadXChaCha20Poly1305Ietf() } }
        set { _aeadXChaCha20Poly1305Ietf = newValue }
    }
    
    internal var _ed25519: Ed25519Type?
    public var ed25519: Ed25519Type {
        get { Dependencies.getValueSettingIfNull(&_ed25519) { Ed25519Wrapper() } }
        set { _ed25519 = newValue }
    }
    
    internal var _nonceGenerator16: NonceGenerator16ByteType?
    public var nonceGenerator16: NonceGenerator16ByteType {
        get { Dependencies.getValueSettingIfNull(&_nonceGenerator16) { OpenGroupAPI.NonceGenerator16Byte() } }
        set { _nonceGenerator16 = newValue }
    }
    
    internal var _nonceGenerator24: NonceGenerator24ByteType?
    public var nonceGenerator24: NonceGenerator24ByteType {
        get { Dependencies.getValueSettingIfNull(&_nonceGenerator24) { OpenGroupAPI.NonceGenerator24Byte() } }
        set { _nonceGenerator24 = newValue }
    }
    
    // MARK: - Initialization
    
    public init(
        requestApi: RequestAPIType.Type? = nil,
        generalCache: Atomic<GeneralCacheType>? = nil,
        storage: Storage? = nil,
        sodium: SodiumType? = nil,
        box: BoxType? = nil,
        genericHash: GenericHashType? = nil,
        sign: SignType? = nil,
        aeadXChaCha20Poly1305Ietf: AeadXChaCha20Poly1305IetfType? = nil,
        ed25519: Ed25519Type? = nil,
        nonceGenerator16: NonceGenerator16ByteType? = nil,
        nonceGenerator24: NonceGenerator24ByteType? = nil,
        standardUserDefaults: UserDefaultsType? = nil,
        date: Date? = nil
    ) {
        _requestApi = requestApi
        _sodium = sodium
        _box = box
        _genericHash = genericHash
        _sign = sign
        _aeadXChaCha20Poly1305Ietf = aeadXChaCha20Poly1305Ietf
        _ed25519 = ed25519
        _nonceGenerator16 = nonceGenerator16
        _nonceGenerator24 = nonceGenerator24
        
        super.init(
            generalCache: generalCache,
            storage: storage,
            standardUserDefaults: standardUserDefaults,
            date: date
        )
    }
}
