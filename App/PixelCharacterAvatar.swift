import SwiftUI

/// Original 48-cell pixel portrait; no copied NFT artwork or external downloads.
/// Scripts/pixel_preview.py mirrors this drawing order for design review.
struct PixelCharacterAvatarArt: View {
    let configuration: CharacterAvatarConfiguration
    var body: some View {
        Canvas { context, size in
            let c=CharacterAvatarConfiguration.decode(configuration.encoded)
            let unit=min(size.width,size.height)/48
            func box(_ x:Int,_ y:Int,_ w:Int,_ h:Int,_ color:Color) {
                let rect=CGRect(x:CGFloat(x)*unit,y:CGFloat(y)*unit,width:CGFloat(w)*unit,height:CGFloat(h)*unit)
                context.fill(Path(rect),with:.color(color),style:FillStyle(antialiased:false))
            }
            let accent=PersonalAvatar.tint(c.accent)
            let palette=c.pixelTheme ?? "Neon"
            let skin=Color(hex:CharacterAvatarConfiguration.skinColors[c.skin] ?? 0xDCA577)
            let hairHex=CharacterAvatarConfiguration.hairColors[c.hairColor] ?? 0x171922
            let hair=Color(hex:hairHex)
            // Brows: a deeper shade of the hair colour (same rule as the vector avatar).
            let brows: Color = {
                func mix(_ shift:UInt32) -> Double {let a=Double((hairHex>>shift)&0xFF), b=Double((0x18212B>>shift)&0xFF); return (a+(b-a)*0.5)/255}
                return Color(red:mix(16),green:mix(8),blue:mix(0))
            }()
            let ink=Color(hex:0x111A22)
            let gold=Color(hex:0xE4B94C)
            let special=c.isNonHuman
            let backgrounds:[String:UInt32]=["Paper":0xD6E5DC,"Ocean":0x16394B,"Plum":0x30213F,"Grid":0x102C2A,"Exchange":0x18232B,"Circuit":0x102D37,"Sunset":0x674337,"Starlight":0x253956,"Rose":0x4D2E4A,"Matrix":0x04140C,"Vault":0x1A2026,"Aurora":0x0D1F2A,"Skyline":0x121A33,"Blockchain":0x0C1A1F,"Void":0x030507]
            let back=Color(hex:backgrounds[c.background] ?? 0x09141D)
            box(0,0,48,48,back)
            if palette != "Shadow" {for y in stride(from:4,to:48,by:8) {box(0,y,48,1,accent.opacity(0.14))}}
            if palette == "Circuit" || c.background == "Grid" {for x in stride(from:4,to:48,by:8){box(x,0,1,48,accent.opacity(0.12))}}
            if palette == "Arcade" {for x in stride(from:2,to:48,by:8){box(x,5,3,2,accent.opacity(0.24));box(x+3,42,2,2,accent.opacity(0.24))}}
            if palette == "Shadow" {box(0,0,5,48,ink.opacity(0.35));box(43,0,5,48,ink.opacity(0.35))}
            switch c.background {
            case "Exchange": for x in stride(from:2,to:48,by:7) {box(x,36-x/3,5,1,accent.opacity(0.35))}
            case "Starlight": for x in stride(from:3,to:48,by:9) {box(x,(x*17)%34,1,1,.white.opacity(0.8))}
            case "Matrix": for x in stride(from:2,to:48,by:5) {for k in 0..<4 {box(x,(x*7+k*12)%44,1,3,accent.opacity(0.25))}}
            case "Vault":
                for (x,y) in [(4,4),(40,4),(4,40),(40,40)] {box(x,y,4,4,accent.opacity(0.22))}
                box(2,22,3,4,accent.opacity(0.22));box(43,22,3,4,accent.opacity(0.22))
            case "Aurora":
                for x in stride(from:0,to:48,by:2) {box(x,8+(x%8)/2,2,3,accent.opacity(0.22));box(x,14+((x+4)%8)/2,2,2,Color(hex:0x8E5CD9).opacity(0.25))}
            case "Skyline":
                for (x,h) in [(0,14),(6,20),(40,18),(44,12)] {box(x,48-h,5,h,Color(hex:0x0A1022));box(x+2,48-h+3,1,1,accent.opacity(0.5))}
            case "Blockchain":
                for x in [2,14,28,40] {box(x,3,6,4,accent.opacity(0.30));box(x+1,4,4,2,back)}
                for x in [8,20,34] {box(x,5,6,1,accent.opacity(0.25))}
            default: break
            }
            box(8,8,32,29,accent.opacity(0.10));box(5,13,3,19,accent.opacity(0.07));box(40,13,3,19,accent.opacity(0.07))
            let shoulder=c.presentation == "Masculine" ? 7 : c.presentation == "Feminine" ? 11 : 9
            let outfits:[String:UInt32]=["Spacesuit":0xDCE4E6,"Duster":0x69452E,"Trench":0x3B3428,"Turtleneck":0x1C1F26,"Bomber":0x2F3B2A,"Tactical":0x2C3328,"Lab Coat":0xE8EEF0]
            box(shoulder,38,48-shoulder*2,10,ink);box(shoulder+3,35,42-shoulder*2,13,Color(hex:outfits[c.clothing] ?? 0x253744))
            if c.clothing == "Spacesuit" {box(9,9,30,27,accent);box(11,10,26,25,Color(hex:0xB9C8CB));box(13,12,22,22,ink)}
            if !special {box(21,31,7,8,skin);box(21,32,7,3,Color.black.opacity(0.15))}
            if c.clothing == "Hoodie" || c.style == "Anonymous" || c.style == "Hooded" || c.clothing == "Full Anonymous" {box(11,9,26,27,ink);box(13,7,22,30,Color(hex:0x253744));box(15,10,18,24,ink)}
            if !special {
                if c.hair == "Long" || c.hair == "Braids" {box(13,12,22,25,hair)}
                if c.hair == "Bob" {box(13,11,22,19,hair)}
                if c.hair == "Afro" {box(15,3,18,2,hair);box(12,5,24,2,hair);box(11,7,26,12,hair);box(12,19,24,2,hair)}
                if c.hair == "Ponytail" {box(33,12,4,6,hair);box(35,17,3,12,hair)}
            }
            let left=c.face == "Round" ? 14 : 15
            let width=48-left*2
            switch c.face {
            case "Alien":
                box(12,12,24,14,skin);box(14,9,20,4,skin);box(17,7,14,3,skin)
                box(15,26,18,4,skin);box(18,30,12,3,skin);box(22,33,4,2,skin)
            case "Cat":
                box(13,16,22,15,skin);box(16,30,16,4,skin)
                box(13,8,6,10,skin);box(29,8,6,10,skin);box(15,11,2,5,accent);box(31,11,2,5,accent)
            case "Robot":
                let metal=Color(hex:0x9AA8B2),seam=Color(hex:0x6E7C86)
                box(21,31,7,7,Color(hex:0x5E6B74));box(21,33,7,1,Color.black.opacity(0.25));box(21,35,7,1,Color.black.opacity(0.25))
                box(14,10,20,22,metal);box(14,10,20,1,seam);box(14,31,20,1,seam);box(14,10,1,22,seam);box(33,10,1,22,seam)
                box(12,18,2,7,seam);box(34,18,2,7,seam);box(24,6,1,4,seam);box(23,4,3,2,accent)
                box(16,18,16,6,ink);box(18,27,12,2,ink);box(20,27,1,2,metal);box(23,27,1,2,metal);box(26,27,1,2,metal)
                box(16,12,3,1,.white.opacity(0.5))
            default:
                box(left,14,width,15,skin);box(left+2,29,width-4,4,skin);box(left+4,33,width-8,1,skin)
                box(left-2,20,2,6,skin);box(48-left,20,2,6,skin)
                box(left,16,2,12,Color.white.opacity(0.12));box(46-left,17,2,12,Color.black.opacity(0.14))
            }
            if c.face == "Angular" {box(left,28,2,3,ink);box(46-left,28,2,3,ink)}
            if c.hair != "Bald" && !special {
                switch c.hair {
                case "Buzz": box(15,11,18,4,hair.opacity(0.9));box(16,10,16,1,hair.opacity(0.9))
                case "Undercut": box(15,12,18,3,hair.opacity(0.45));box(17,8,14,5,hair);box(26,7,7,3,hair);box(29,12,4,4,hair)
                case "Afro": box(13,9,22,6,hair)
                case "Mohawk": box(15,13,18,2,hair.opacity(0.35));box(14,14,2,4,hair.opacity(0.35));box(32,14,2,4,hair.opacity(0.35))
                default: box(14,10,20,5,hair);box(16,8,16,3,hair);box(14,14,4,4,hair);box(30,13,4,5,hair)
                }
                if c.hair == "Crop" {box(18,14,9,2,hair);box(18,10,10,1,Color.white.opacity(0.15))}
                if c.hair == "Curls" {for x in stride(from:12,to:35,by:4){box(x,9+(x%3),4,5,hair);box(x,9+(x%3),2,1,Color.white.opacity(0.12))}}
                if c.hair == "Mohawk" {box(21,5,7,10,hair);box(22,3,5,2,hair);box(22,5,2,3,Color.white.opacity(0.15))}
                if c.hair == "Spikes" {for x in stride(from:12,to:37,by:5){box(x,7-(x%3),3,7,hair)}}
                if c.hair == "Braids" {for y in stride(from:15,to:36,by:4){box(12,y,3,3,hair);box(33,y,3,3,hair)}}
                if c.hair == "Long" {box(13,14,3,21,hair);box(32,14,3,21,hair)}
                if c.hair == "Bob" {box(13,14,3,15,hair);box(32,14,3,15,hair)}
                if c.hair == "Bun" {box(21,4,7,5,hair);box(22,5,2,1,Color.white.opacity(0.15))}
            }
            switch c.face {
            case "Cat":
                box(18,21,4,3,ink);box(27,21,4,3,ink);box(23,27,3,2,ink)
                box(17,28,6,1,ink.opacity(0.6));box(26,28,6,1,ink.opacity(0.6))
                box(12,26,6,1,ink.opacity(0.4));box(30,26,6,1,ink.opacity(0.4))
            case "Alien":
                box(14,19,9,4,ink);box(16,23,5,2,ink)
                box(25,19,9,4,ink);box(27,23,5,2,ink)
                box(22,30,4,1,ink.opacity(0.7))
            case "Robot":
                box(18,19,4,4,accent);box(26,19,4,4,accent);box(18,19,1,1,.white.opacity(0.85));box(26,19,1,1,.white.opacity(0.85))
            default:
                box(17,19,5,1,brows);box(27,19,5,1,brows)
                switch c.eyes {
                case "Glow": box(17,20,5,4,accent.opacity(0.35));box(27,20,5,4,accent.opacity(0.35));box(18,21,3,2,accent);box(28,21,3,2,accent)
                case "Sly": box(18,22,3,1,ink);box(28,22,3,1,ink)
                case "Wink": box(18,21,3,2,ink);box(18,21,1,1,.white);box(28,22,3,1,ink)
                default: box(18,21,3,2,ink);box(28,21,3,2,ink);box(18,21,1,1,.white);box(28,21,1,1,.white)
                }
                if c.eyes == "Wide" {box(18,20,3,1,ink);box(28,20,3,1,ink)}
                if c.eyes == "Focused" {box(20,20,2,1,hair);box(26,20,2,1,hair)}
                if c.presentation == "Feminine" {box(17,20,1,1,ink);box(31,20,1,1,ink)}
                box(24,23,1,4,Color.black.opacity(0.18));box(23,26,3,1,Color.black.opacity(0.22))
                // Facial hair follows the jaw and sits under the mouth.
                switch c.facialHair {
                case "Beard":
                    box(left,23,2,7,hair);box(46-left,23,2,7,hair)
                    box(left+1,28,width-2,4,hair);box(left+2,32,width-4,1,hair);box(left+4,33,width-8,2,hair)
                    box(left+2,33,width-4,1,Color.black.opacity(0.18));box(20,27,9,1,hair)
                    box(21,29,7,1,Color(hex:0x8C4F45))
                case "Stubble":
                    for y in 27..<34 {for x in stride(from:left+1+(y%2),to:47-left,by:2) {box(x,y,1,1,hair.opacity(0.2))}}
                case "Mustache": box(20,27,9,1,hair);box(21,26,7,1,hair.opacity(0.6))
                case "Goatee": box(20,27,9,1,hair);box(21,26,7,1,hair.opacity(0.6));box(22,31,5,2,hair);box(23,33,3,1,hair)
                default: break
                }
                box(21,29,7,1,ink.opacity(c.facialHair == "Beard" ? 0.55 : 0.7));if c.eyes == "Friendly" || c.eyes == "Wink" {box(22,30,5,1,ink.opacity(0.7))}
            }
            if c.style == "Anonymous" || c.accessory == "Mask" {
                box(15,17,19,14,Color(hex:0xE7EBE5));box(17,31,15,3,Color(hex:0xC4D1CA))
                box(19,34,11,2,Color(hex:0xDCE5DE));box(22,36,5,1,Color(hex:0xDCE5DE))
                box(17,20,6,1,ink);box(26,20,6,1,ink)
                box(18,22,5,2,ink);box(26,22,5,2,ink)
                box(23,24,3,4,Color(hex:0xA9B9B4))
                box(17,27,3,1,Color(hex:0xB97982));box(29,27,3,1,Color(hex:0xB97982))
                box(20,29,9,1,ink);box(18,28,2,1,ink);box(29,28,2,1,ink)
                box(22,32,5,1,ink);box(23,34,3,2,ink);box(24,36,1,2,ink)
            }
            if ["Glasses","Shades","Sunglasses","Visor"].contains(c.accessory) {
                box(15,20,19,1,accent);box(16,21,7,4,ink);box(26,21,7,4,ink);box(23,22,3,1,accent)
                if c.accessory == "Glasses" {box(17,21,5,3,skin.opacity(0.65));box(27,21,5,3,skin.opacity(0.65))}
                if c.accessory == "Visor" {box(16,20,17,5,accent);box(17,21,13,1,.white.opacity(0.7))}
            }
            switch c.accessory {
            case "Monocle": box(26,19,6,1,gold);box(26,24,6,1,gold);box(26,19,1,6,gold);box(31,19,1,6,gold);box(31,25,1,8,gold)
            case "Eyepatch": box(15,16,18,1,ink);box(26,19,6,5,ink)
            case "Cyber Eye": box(25,19,8,6,Color(hex:0x2A3640));box(27,20,4,4,accent);box(29,21,1,1,.white.opacity(0.9));box(33,22,3,1,accent.opacity(0.8))
            case "Bandana": box(15,26,19,6,accent.opacity(0.9));box(17,32,15,2,accent.opacity(0.9));box(19,28,1,1,.white.opacity(0.4));box(24,29,1,1,.white.opacity(0.4));box(29,28,1,1,.white.opacity(0.4))
            case "Respirator": box(18,27,13,7,Color(hex:0x2C3338));box(15,28,4,4,Color(hex:0x4A555D));box(30,28,4,4,Color(hex:0x4A555D));box(16,29,2,2,accent.opacity(0.7));box(31,29,2,2,accent.opacity(0.7))
            case "Earpiece": box(34,22,2,3,ink);box(34,23,1,1,accent)
            case "Beanie": box(14,9,20,7,accent);box(16,7,16,3,accent);box(14,15,20,2,ink)
            case "Cap": box(14,10,20,6,ink);box(16,8,16,3,ink);box(13,15,25,2,accent)
            case "Cowboy Hat": box(15,7,18,8,Color(hex:0x69452E));box(9,15,30,3,Color(hex:0x69452E));box(15,13,18,2,accent)
            case "Helmet": box(9,10,4,24,.white);box(35,10,4,24,.white);box(13,7,22,4,.white);box(13,34,22,3,.white);box(14,11,4,2,accent.opacity(0.7))
            case "Piercing": box(34,24,1,3,accent)
            case "Headphones": box(10,19,4,11,accent);box(34,19,4,11,accent);box(13,12,3,3,accent);box(32,12,3,3,accent);box(16,10,16,2,accent)
            case "Crown":
                box(16,5,16,4,gold);box(16,2,2,3,gold);box(23,1,2,4,gold);box(30,2,2,3,gold)
                box(19,6,2,2,accent);box(27,6,2,2,accent);box(23,6,2,2,Color(hex:0xF06C73))
            case "Halo":
                let light=Color(hex:0xF4D899)
                box(17,2,14,1,light);box(16,3,1,1,light);box(31,3,1,1,light);box(17,4,14,1,light)
            default: break
            }
            switch c.clothing {
            case "Armor","Hero Armor":
                box(8,38,32,4,accent.opacity(0.55));box(14,42,20,2,accent)
                if c.clothing == "Hero Armor" {box(21,39,6,5,accent);box(23,40,2,3,ink)}
            case "Suit": box(12,38,24,10,Color(hex:0x171E2C));box(19,38,10,8,.white);box(23,40,2,7,accent)
            case "Trench": box(shoulder+3,37,6,11,Color(hex:0x4A4133));box(39-shoulder,37,6,11,Color(hex:0x4A4133));box(shoulder+3,44,42-shoulder*2,1,Color(hex:0x2A251C))
            case "Turtleneck": box(20,33,9,5,Color(hex:0x2A2E38));box(20,35,9,1,Color.black.opacity(0.35))
            case "Bomber": box(18,36,13,2,accent.opacity(0.8));box(24,38,1,10,Color(hex:0xC7D2DD));box(shoulder+5,41,3,2,accent.opacity(0.6))
            case "Tactical":
                box(15,38,19,10,Color(hex:0x3A4434))
                for x in [16,22,28] {box(x,41,4,3,Color(hex:0x48543F))}
                box(15,38,19,1,accent.opacity(0.8))
            case "Lab Coat": box(19,37,11,11,Color(hex:0x2A3640));box(19,37,1,11,Color(hex:0xB8C4C8));box(29,37,1,11,Color(hex:0xB8C4C8));box(31,41,3,1,accent)
            default: break
            }
            if c.clothing == "T-shirt" {box(shoulder+3,39,42-shoulder*2,9,accent.opacity(0.75))}
            else if ["Jacket","Duster","Hoodie","Full Anonymous"].contains(c.clothing) {
                // Collar opening and lapels in garment tones; no accent stripes
                // that could read as part of the NOID badge.
                let tee=Color(hex:0x161D24)
                box(21,37,7,2,tee);box(22,39,5,2,tee);box(23,41,3,2,tee)
                box(22,37,5,1,skin);box(23,38,3,1,skin)
                if c.clothing == "Hoodie" || c.clothing == "Full Anonymous" {
                    box(21,39,1,5,Color(hex:0xC7D2DD).opacity(0.85));box(27,39,1,5,Color(hex:0xC7D2DD).opacity(0.85))
                } else {box(18,37,3,9,Color.black.opacity(0.22));box(28,37,3,9,Color.black.opacity(0.22))}
                box(shoulder+4,43,5,1,.white.opacity(0.12))
            }
            if c.jewelry == "Chain" || c.jewelry == "Double chain" || c.jewelry == "Pendant" {
                for (x,y) in [(17,37),(20,38),(23,39),(26,38),(29,37)] {box(x,y,3,1,gold)}
            }
            if c.jewelry == "Double chain" {box(20,40,9,1,Color(hex:0xF4D899))}
            if c.jewelry == "Pendant" {box(23,40,3,3,accent)}
        }.accessibilityLabel("Pixel character avatar")
    }
}
struct CharacterAvatarArt: View {
    let configuration: CharacterAvatarConfiguration
    var body: some View {
        if configuration.isPixel {PixelCharacterAvatarArt(configuration:configuration)}
        else {VectorCharacterAvatarArt(configuration:configuration)}
    }
}
