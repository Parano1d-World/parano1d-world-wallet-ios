import Foundation

enum CollectionSearch {
    static func normalized(_ value:String)->String {
        value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            .split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
    }
    static func matches(query:String,name:String,id:String)->Bool {
        let terms=normalized(query).split(separator:" ")
        let name=normalized(name),id=normalized(id)
        return terms.allSatisfy{name.contains($0) || id.contains($0)}
    }
}
