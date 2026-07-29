//
//  PTVSignature.swift
//  PapaTransport
//
//  Request signing for the PTV Timetable API v3.
//
//  Every request must carry a HMAC-SHA1 signature computed over the request
//  path *including* the devid query parameter. The signature covers the
//  path and query only — never the scheme or host.
//

import Foundation
import CryptoKit

nonisolated enum PTVSignature {

    /// Returns `path` with `devid` and `signature` appended, ready to be
    /// joined onto the base URL.
    ///
    /// The `devid` must be part of the signed string, so it is appended
    /// before the HMAC is computed rather than added afterwards.
    static func signedPath(for path: String, devid: String, apiKey: String) -> String {
        let separator = path.contains("?") ? "&" : "?"
        let request = "\(path)\(separator)devid=\(devid)"

        let key = SymmetricKey(data: Data(apiKey.utf8))
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(request.utf8), using: key)
        let signature = code.map { String(format: "%02X", $0) }.joined()

        return "\(request)&signature=\(signature)"
    }
}
