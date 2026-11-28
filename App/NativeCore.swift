import Foundation
#if canImport(ParanoidCore)
import ParanoidCore
#endif

/// The website bridge never has access to this actor or its secret-bearing methods.
actor NativeCore {
    static let shared = NativeCore()
    static var available: Bool {
        #if canImport(ParanoidCore)
        return true
        #else
        return false
        #endif
    }
    func call(_ request: [String: Any], master: Data? = nil) throws -> [String: Any] {
        #if canImport(ParanoidCore)
        var input = try JSONSerialization.data(withJSONObject: request)
        var key = master ?? Data()
        defer { input.resetBytes(in: 0..<input.count); key.resetBytes(in: 0..<key.count) }
        let ptr = input.withUnsafeBytes { raw in
            key.withUnsafeBytes { secret in
                paranoid_ios_call(raw.bindMemory(to: UInt8.self).baseAddress, input.count,
                                  secret.bindMemory(to: UInt8.self).baseAddress, key.count)
            }
        }
        guard let ptr else { throw AppFailure("Native engine did not return a result.") }
        defer { paranoid_ios_free(ptr) }
        var bytes = Data(bytes: ptr, count: strlen(ptr))
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw AppFailure("Invalid native response.") }
        if let error = envelope["error"] as? String { throw AppFailure(error) }
        guard let result = envelope["result"] as? [String: Any] else { throw AppFailure("Missing native result.") }
        return result
        #else
        throw AppFailure("The native wallet engine must be built and linked before creating or recovering a wallet.")
        #endif
    }
    func address(master: Data, index: UInt32 = 0) throws -> String {
        guard let address = try call(["op": "address", "account_index": index], master: master)["address"] as? String else { throw AppFailure("Missing address.") }
        return address
    }
}
extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count/2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(byte); index = end
        }
        self.init(bytes)
    }
}
