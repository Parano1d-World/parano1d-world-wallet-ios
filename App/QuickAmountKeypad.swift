import SwiftUI

enum QuickRecipientOrder {
    static func unique(_ addresses:[String])->[String] {
        var seen=Set<String>()
        return addresses.filter {seen.insert($0).inserted}
    }
}

enum QuickAmountInput {
    static func apply(_ key:String,to current:String)->String {
        if key == "delete" {return current.isEmpty ? "" : String(current.dropLast())}
        if key == "." {return current.isEmpty ? "0." : current.contains(".") ? current : current + "."}
        guard key.count == 1,key.first.map({"0123456789".contains($0)}) == true,current.count<18 else{return current}
        if let dot=current.firstIndex(of:"."),current[current.index(after:dot)...].count>=6 {return current}
        return current == "0" ? key : current + key
    }
}

struct QuickAmountKeypad:View {
    let onPress:(String)->Void
    private let keys=["1","2","3","4","5","6","7","8","9",".","0","delete"]
    private let columns=Array(repeating:GridItem(.flexible(),spacing:8),count:3)
    var body:some View {
        LazyVGrid(columns:columns,spacing:8) {
            ForEach(keys,id:\.self) {key in
                Button {onPress(key)} label: {
                    Group {
                        if key == "delete" {Image(systemName:"delete.left")}
                        else {Text(key)}
                    }
                    .font(Theme.editorial(25)).frame(maxWidth:.infinity,minHeight:50)
                    .foregroundStyle(Theme.text)
                    .background(Theme.background.opacity(0.6),in:RoundedRectangle(cornerRadius:12))
                    .overlay(RoundedRectangle(cornerRadius:12).stroke(Theme.line))
                }.buttonStyle(.plain)
                    .accessibilityLabel(key == "delete" ? "Delete last digit" : key == "." ? "Decimal point" : key)
            }
        }
    }
}
