import Foundation

/// Decimal-only offer arithmetic. Quotes are explanatory; the exact total
/// microunits saved in OTCOffer remain the agreement, never a floating rate.
enum OTCPricing {
    static func positive(_ text:String)->Decimal? {
        let normalized=text.replacingOccurrences(of:",",with:".")
        guard normalized.range(of:"^[0-9]+(?:\\.[0-9]{1,12})?$",options:.regularExpression) != nil,
              let value=Decimal(string:normalized,locale:Locale(identifier:"en_US_POSIX")),value>0 else{return nil}
        return value
    }
    static func text(_ value:Decimal,scale:Int=12)->String {
        guard !value.isNaN else{return ""}
        var input=value,result=Decimal()
        NSDecimalRound(&result,&input,scale,.plain)
        return NSDecimalNumber(decimal:result).stringValue
    }
    static func total(quantity:String,unitPrice:String)->String? {
        guard let quantity=positive(quantity),let price=positive(unitPrice) else{return nil}
        let total=text(quantity*price,scale:6)
        guard (try? OTCOffer.amount(total)) != nil else{return nil}
        return total
    }
    static func unitPrice(quantity:String,total:String)->String? {
        guard let quantity=positive(quantity),let total=positive(total) else{return nil}
        let result=text(total/quantity)
        return positive(result) == nil ? nil : result
    }
    static func adjusted(reference:String,percent:Int)->String? {
        guard percent > -100,percent<=1000,let reference=positive(reference) else{return nil}
        let result=text(reference*Decimal(100+percent)/100)
        return positive(result) == nil ? nil : result
    }
}
