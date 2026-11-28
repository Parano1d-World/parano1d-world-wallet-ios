import SwiftUI

enum ContactFavorites {
    static let storageKey="contacts.favorites.v1"
    static func read(_ raw:String)->Set<String> {
        guard raw.utf8.count<=20000,let values=try? JSONDecoder().decode([String].self,from:Data(raw.utf8)) else{return []}
        return Set(values.filter{$0.count==64 && Data(hex:$0)?.count==32}.prefix(250))
    }
    static func toggled(_ id:String,in raw:String)->String {
        guard id.count==64,Data(hex:id)?.count==32 else{return raw}
        var ids=read(raw)
        if ids.contains(id) {ids.remove(id)} else if ids.count<250 {ids.insert(id)}
        guard let bytes=try? JSONEncoder().encode(ids.sorted()),let value=String(data:bytes,encoding:.utf8) else{return raw}
        return value
    }
}
struct ContactFavoriteButton:View {
    let identity:String
    let name:String
    @AppStorage(ContactFavorites.storageKey) private var raw="[]"
    private var starred:Bool {ContactFavorites.read(raw).contains(identity)}
    var body:some View {
        Button {raw=ContactFavorites.toggled(identity,in:raw)} label: {
            Image(systemName:starred ? "star.fill" : "star").font(.system(size:20))
                .foregroundStyle(starred ? Color.yellow : Theme.secondary).frame(width:44,height:44)
        }.buttonStyle(.borderless)
            .accessibilityLabel((starred ? "Remove " : "Add ")+name+(starred ? " from favorites" : " to favorites"))
            .accessibilityValue(starred ? "Favorite" : "Not a favorite")
    }
}
