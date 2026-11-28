import Foundation

enum NodeRefresh {
    /// Must match `SYNC_FAILURE_PREFIX` in Node/src/balance.rs.
    static let syncFailurePrefix = "Chain sync failed: "

    static func execute(_ request:[String:Any], call:([String:Any]) throws -> [String:Any]) throws -> [String:Any] {
        do { return try call(request) }
        catch {
            guard request["op"] as? String == "wallet_balance" else { throw error }
            let balanceError=error.localizedDescription
            // wallet_balance already ran the full chain sync and it failed.
            // Running sync_once again would repeat the same (possibly full
            // history) download and double the time to the next retry.
            if balanceError.hasPrefix(syncFailurePrefix) {
                throw AppFailure(String(balanceError.dropFirst(syncFailurePrefix.count)))
            }
            var fallback=request
            fallback["op"]="sync_once"
            fallback.removeValue(forKey:"owner")
            var result=try call(fallback)
            result["balance_error"]=balanceError
            return result
        }
    }
}
