import Foundation

enum ReviewDisplay {
    static func requestValue(_ value:Any,key:String,action:String)->String {
        if key=="units",action=="transfer_token",let raw=value as? String,
           let quantity=Amounts.format(raw) {
            return "\(quantity) tokens (\(raw) base units)"
        }
        return String(describing:value)
    }
    static func title(_ key:String)->String {
        let titles=["seller":"Seller","ask_micronoid":"NFT price","listing_expiry_height":"Listing expiry block","noid_debit_micronoid":"NOID debit","noid_credit_micronoid":"NOID credit","fee_micronoid":"Network fee","fee_limit_micronoid":"Maximum fee","reserve_deposit_micronoid":"Reserve deposit","initial_buy_cost_micronoid":"Initial purchase cost","redemption_micronoid":"Redemption","asset_id":"Asset","collection_id":"Collection","serial":"NFT serial","last_serial":"Last NFT serial","valid_until":"Valid through block","quoted_output":"Quoted output (base units)","minimum_output":"Minimum output (base units)"]
        return titles[key] ?? key.replacingOccurrences(of:"_",with:" ").capitalized
    }
    static func value(_ value:Any,key:String)->String {
        // Canonical SDK money fields are decimal strings, never floating point.
        if key.hasSuffix("_micronoid"),let raw=value as? String,let amount=Amounts.format(raw){return amount+" NOID"}
        return String(describing:value)
    }
}
