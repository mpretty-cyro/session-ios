// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public enum LibSession {
    public static let logLevel: config_log_level = LOG_LEVEL_INFO
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}
