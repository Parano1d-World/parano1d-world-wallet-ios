import SwiftUI

/// Single source of truth for every selectable character value. The editor,
/// presets and the shared-avatar validator all read these lists, so a new
/// option can never be selectable but rejected when shared (or the reverse).
enum CharacterAvatarOptions {
    static let styles = ["Classic","Anonymous","Hooded","Cyber","Minimal"]
    static let presentations = ["Masculine","Feminine"]
    static let faces = ["Oval","Round","Angular","Alien","Cat","Robot"]
    /// Faces drawn without human hair, facial hair, ears or the Anonymous mask.
    static let nonHumanFaces: Set<String> = ["Alien","Cat","Robot"]
    static let skins = ["Porcelain","Fair","Warm","Tan","Brown","Deep","Mint","Lunar","Violet","Emerald"]
    static let expressions = ["Calm","Friendly","Focused","Wide","Wink","Sly","Glow"]
    static let hairstyles = ["Crop","Buzz","Undercut","Curls","Afro","Long","Bob","Ponytail","Bun","Braids","Mohawk","Spikes","Bald"]
    static let hairColors = ["Black","Brown","Blonde","Auburn","Copper","Silver","White","Pink","Violet","Blue","Mint","Neon"]
    static let facialHair = ["None","Stubble","Mustache","Goatee","Beard"]
    static let clothing = ["Jacket","Hoodie","T-shirt","Bomber","Turtleneck","Trench","Tactical","Lab Coat","Armor","Hero Armor","Suit","Spacesuit","Full Anonymous","Duster"]
    static let accessories = ["None","Glasses","Sunglasses","Shades","Visor","Cyber Eye","Monocle","Eyepatch","Mask","Bandana","Respirator","Piercing","Earpiece","Beanie","Cap","Headphones","Helmet","Cowboy Hat","Crown","Halo"]
    static let jewelry = ["None","Chain","Double chain","Pendant"]
    static let accents = ["Green","Mint","Lime","Cyan","Blue","Purple","Magenta","Pink","Red","Orange","Gold","Silver"]
    static let backgrounds = ["Midnight","Void","Ocean","Plum","Paper","Grid","Matrix","Exchange","Blockchain","Circuit","Vault","Skyline","Aurora","Sunset","Starlight","Rose"]
    static let pixelThemes = ["Neon","Arcade","Circuit","Shadow"]

    /// Older builds' values that saved or received recipes may still carry.
    static let legacyStyles: Set<String> = ["Pixel"]
    static let legacyPresentations: Set<String> = ["Androgynous"]
    static let legacyFaces: Set<String> = ["Ape"]
}

struct CharacterAvatarConfiguration: Codable, Equatable {
    var style = "Classic"
    var rendering: String? = nil
    var pixelTheme: String? = nil
    var presentation = "Masculine"
    var face = "Oval"
    var skin = "Warm"
    var hair = "Crop"
    var hairColor = "Black"
    var facialHair = "None"
    var eyes = "Calm"
    var accessory = "None"
    var jewelry: String? = nil
    var clothing = "Jacket"
    var accent = "Green"
    var background = "Midnight"
    /// Kept only so saved and shared recipes still decode; no artwork uses it.
    var branding = true
    static func decode(_ raw: String) -> Self {
        guard raw.utf8.count < 4096, let bytes = raw.data(using:.utf8),
              var value = try? JSONDecoder().decode(Self.self,from:bytes) else {return Self()}
        // Migrate retired choices so saved avatars stay editable.
        if value.presentation == "Androgynous" {value.presentation="Masculine"}
        if value.face == "Ape" {value.face="Oval"}
        if value.isNonHuman {value.removeHumanLayers()}
        return value
    }
    var isNonHuman: Bool {CharacterAvatarOptions.nonHumanFaces.contains(face)}
    /// Alien, cat and robot faces have no human hair, beard or Anonymous mask.
    mutating func removeHumanLayers() {
        hair="Bald";facialHair="None"
        if style == "Anonymous" {style="Classic"}
        if accessory == "Mask" {accessory="None"}
    }
    var encoded: String { (try? JSONEncoder().encode(self)).flatMap {String(data:$0,encoding:.utf8)} ?? "" }
    var isPixel: Bool {rendering == "Pixel" || (rendering == nil && style == "Pixel")}
    static let skinColors: [String: UInt32] = ["Porcelain":0xF3D8C5,"Fair":0xEBC3A2,"Warm":0xDCA577,"Tan":0xB97E54,"Brown":0x885636,"Deep":0x503426,"Mint":0x8ED8B9,"Lunar":0xAFC6C7,"Violet":0xA98CC6,"Emerald":0x67BE9C]
    static let hairColors: [String: UInt32] = ["Black":0x171922,"Brown":0x51372D,"Blonde":0xDAB777,"Auburn":0x954930,"Silver":0xCDD6DE,"Pink":0xE571A1,"Blue":0x4C83CE,"Mint":0x69E4BA,"Copper":0xC4642D,"Violet":0x8E5CD9,"White":0xEEF1F2,"Neon":0x3BF07A]
    static let backgroundColors: [String: UInt32] = ["Paper":0xDBE5DF,"Plum":0x30233F,"Ocean":0x153948,"Grid":0x102C2A,"Exchange":0x18232B,"Circuit":0x102D37,"Sunset":0x674337,"Starlight":0x253956,"Rose":0x4D2E4A,"Matrix":0x04140C,"Vault":0x1A2026,"Aurora":0x0D1F2A,"Skyline":0x121A33,"Blockchain":0x0C1A1F,"Void":0x030507]
    static let outfitColors: [String: UInt32] = ["Armor":0x344850,"Hero Armor":0x344850,"Spacesuit":0xDCE4E6,"Duster":0x69452E,"Suit":0x171E2C,"Trench":0x3B3428,"Turtleneck":0x1C1F26,"Bomber":0x2F3B2A,"Tactical":0x2C3328,"Lab Coat":0xE8EEF0]
    static let presets = ["Custom", "Astronaut", "Anonymous", "Cowboy", "Alien", "Paranoid Cat", "Cyber Pilot", "Space Ranger", "Crypto Trader", "Cyber Hero",
                          "Hacker", "Node Runner", "Miner", "Robot", "Ghost", "Vault Keeper", "Neon Ronin", "Whale"]
    static func preset(_ name:String, from current:Self) -> Self {
        guard name != "Custom" else {return current}
        // A look is a complete recipe. Never carry another look's face, mask or outfit into it.
        var result=Self()
        result.rendering=current.rendering ?? (current.style == "Pixel" ? "Pixel" : nil)
        result.pixelTheme=current.pixelTheme
        result.branding=current.branding
        switch name {
        case "Astronaut": result.clothing="Spacesuit";result.accessory="Helmet";result.background="Ocean";result.accent="Cyan"
        case "Anonymous": result.style="Anonymous";result.clothing="Full Anonymous";result.accessory="Mask";result.background="Midnight"
        case "Cowboy": result.clothing="Duster";result.accessory="Cowboy Hat";result.background="Paper";result.accent="Orange"
        case "Alien": result.face="Alien";result.hair="Bald";result.clothing="Spacesuit";result.accessory="None";result.skin="Mint";result.background="Plum"
        case "Paranoid Cat": result.face="Cat";result.hair="Bald";result.clothing="Jacket";result.accessory="None";result.background="Midnight"
        case "Cyber Pilot": result.style="Cyber";result.clothing="Armor";result.accessory="Visor";result.background="Grid";result.accent="Cyan"
        case "Space Ranger": result.clothing="Spacesuit";result.accessory="Helmet";result.background="Plum";result.accent="Purple"
        case "Crypto Trader": result.style="Cyber";result.clothing="Suit";result.accessory="Shades";result.jewelry="Chain";result.background="Exchange";result.accent="Gold"
        case "Cyber Hero": result.style="Cyber";result.clothing="Hero Armor";result.accessory="Visor";result.background="Circuit";result.accent="Cyan"
        case "Hacker": result.style="Hooded";result.clothing="Hoodie";result.hair="Undercut";result.eyes="Glow";result.accessory="Earpiece";result.background="Matrix"
        case "Node Runner": result.style="Cyber";result.presentation="Feminine";result.clothing="Bomber";result.hair="Ponytail";result.hairColor="Neon";result.accessory="Cyber Eye";result.background="Blockchain";result.accent="Mint"
        case "Miner": result.clothing="Tactical";result.accessory="Respirator";result.hair="Buzz";result.skin="Tan";result.background="Vault";result.accent="Orange"
        case "Robot": result.face="Robot";result.hair="Bald";result.clothing="Armor";result.eyes="Glow";result.background="Circuit";result.accent="Cyan"
        case "Ghost": result.style="Hooded";result.presentation="Feminine";result.clothing="Trench";result.accessory="Bandana";result.eyes="Sly";result.hair="Bob";result.hairColor="White";result.skin="Porcelain";result.background="Void";result.accent="Silver"
        case "Vault Keeper": result.presentation="Feminine";result.clothing="Turtleneck";result.accessory="Monocle";result.hair="Bun";result.hairColor="Silver";result.skin="Brown";result.background="Vault";result.accent="Gold"
        case "Neon Ronin": result.style="Cyber";result.clothing="Trench";result.hair="Bun";result.accessory="Bandana";result.facialHair="Goatee";result.skin="Fair";result.background="Skyline";result.accent="Magenta"
        case "Whale": result.clothing="Suit";result.accessory="Crown";result.jewelry="Double chain";result.eyes="Wink";result.hair="Afro";result.skin="Deep";result.background="Aurora";result.accent="Gold"
        default: break
        }
        return result
    }
}

/// Original layered vector artwork, rendered locally without image downloads.
/// Coordinates are a 200×200 canvas. Scripts/avatar_preview.py mirrors this
/// drawing order for design review; keep the two in step.
struct VectorCharacterAvatarArt: View {
    let configuration: CharacterAvatarConfiguration
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width,size.height) / 200
            context.scaleBy(x:scale,y:scale)
            let c = CharacterAvatarConfiguration.decode(configuration.encoded)
            let accent = PersonalAvatar.tint(c.accent)
            let skin = Color(hex:CharacterAvatarConfiguration.skinColors[c.skin] ?? 0xDCA577)
            let hairHex = CharacterAvatarConfiguration.hairColors[c.hairColor] ?? 0x171922
            let hair = Color(hex:hairHex)
            // Brows are a deeper shade of the hair colour, so light and vivid hair
            // (white, silver, neon) still reads as brows on every skin tone.
            func hairShade(_ amount:Double) -> Color {
                func mix(_ shift:UInt32) -> Double {
                    let a = Double((hairHex >> shift) & 0xFF), b = Double((0x18212B >> shift) & 0xFF)
                    return (a+(b-a)*amount)/255
                }
                return Color(red:mix(16),green:mix(8),blue:mix(0))
            }
            let brows = hairShade(0.5)
            // Facial hair is a little deeper than the hair; stubble is a shadow in the brow shade.
            let facial = hairShade(0.25)
            let ink = Color(hex:0x18212B)
            let gold = Color(hex:0xE4B94C)
            let special = c.isNonHuman
            let faceWidth: Double = c.face == "Round" ? 83 : c.face == "Angular" ? 71 : 75
            /// Hand-drawn hair art (HairArt.swift), fitted to this face shape.
            // Hair stays under whatever covers the head: a hat's brim or band, a
            // helmet visor, a hood or a spacesuit collar.
            let hairClip: Path? = {
                if c.clothing == "Spacesuit" {return Path(ellipseIn:CGRect(x:45,y:32,width:110,height:120))}
                if c.style == "Hooded" || c.style == "Anonymous" || c.clothing == "Hoodie" || c.clothing == "Full Anonymous" {
                    return Path(ellipseIn:CGRect(x:48,y:32,width:104,height:126))
                }
                switch c.accessory {
                case "Beanie","Cap": return Path(CGRect(x:0,y:60,width:200,height:140))
                case "Cowboy Hat": return Path(CGRect(x:0,y:56,width:200,height:144))
                case "Crown": return Path(CGRect(x:0,y:44,width:200,height:156))
                case "Helmet": return Path(roundedRect:CGRect(x:54,y:47,width:92,height:91),cornerRadius:30)
                default: return nil
                }
            }()
            func drawHairArt(_ layers:[HairArt.Layer]) {
                let fit = HairArt.fit(face:c.face,width:faceWidth)
                var context = context
                if let hairClip {context.clip(to:hairClip)}
                for layer in layers {
                    let shape = HairArt.path(layer.path).applying(fit)
                    switch layer.role {
                    case .hair:
                        context.fill(shape,with:.color(hair))
                        // A soft darker edge keeps light hair defined against skin and background.
                        context.stroke(shape,with:.color(.black.opacity(0.16)),lineWidth:0.9)
                    case .fill: context.fill(shape,with:.color(hair))
                    case .stubble: context.fill(shape,with:.color(hair.opacity(0.4)))
                    case .shade: context.fill(shape,with:.color(.black.opacity(0.22)))
                    case .light: context.fill(shape,with:.color(.white.opacity(0.16)))
                    case .lightLine: context.stroke(shape,with:.color(.white.opacity(0.16)),style:StrokeStyle(lineWidth:1.6,lineCap:.round))
                    case .shadeLine: context.stroke(shape,with:.color(.black.opacity(0.22)),style:StrokeStyle(lineWidth:1.6,lineCap:.round))
                    }
                }
            }
            func ellipse(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:Color) {
                context.fill(Path(ellipseIn:CGRect(x:x,y:y,width:w,height:h)),with:.color(color))
            }
            func ring(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:Color,_ width:CGFloat) {
                context.stroke(Path(ellipseIn:CGRect(x:x,y:y,width:w,height:h)),with:.color(color),lineWidth:width)
            }
            func rect(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:Color) {
                context.fill(Path(CGRect(x:x,y:y,width:w,height:h)),with:.color(color))
            }
            func roundedBox(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ r:Double,fill:Color? = nil,stroke:Color? = nil,width:CGFloat = 0) {
                let shape = Path(roundedRect:CGRect(x:x,y:y,width:w,height:h),cornerRadius:r)
                if let fill {context.fill(shape,with:.color(fill))}
                if let stroke {context.stroke(shape,with:.color(stroke),lineWidth:width)}
            }
            func polygon(_ points:[CGPoint],_ color:Color) {
                guard let first = points.first else{return}
                var path = Path();path.move(to:first)
                for point in points.dropFirst() {path.addLine(to:point)}
                path.closeSubpath();context.fill(path,with:.color(color))
            }
            func line(_ points:[CGPoint],_ color:Color,_ width:CGFloat = 2) {
                guard let first = points.first else{return}
                var path = Path();path.move(to:first)
                for point in points.dropFirst() {path.addLine(to:point)}
                context.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:width,lineCap:.round,lineJoin:.round))
            }
            func p(_ x:Double,_ y:Double) -> CGPoint {CGPoint(x:x,y:y)}
            /// Closed organic shape: quadratic curves through each edge midpoint,
            /// using the listed points as control points.
            func smooth(_ points:[CGPoint],_ color:Color,clip:Path? = nil) {
                guard points.count > 2 else{return}
                func mid(_ a:CGPoint,_ b:CGPoint) -> CGPoint {CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2)}
                var path = Path()
                path.move(to:mid(points[points.count-1],points[0]))
                for index in points.indices {
                    path.addQuadCurve(to:mid(points[index],points[(index+1)%points.count]),control:points[index])
                }
                path.closeSubpath()
                var target = context
                if let clip {target.clip(to:clip)}
                target.fill(path,with:.color(color))
            }
            /// Open curve from the first to the last point, rounding the corners between.
            func curve(_ points:[CGPoint],_ color:Color,_ width:CGFloat) {
                guard points.count > 2 else {line(points,color,width);return}
                func mid(_ a:CGPoint,_ b:CGPoint) -> CGPoint {CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2)}
                var path = Path();path.move(to:points[0])
                for index in 1..<points.count-1 {
                    let end = index == points.count-2 ? points[index+1] : mid(points[index],points[index+1])
                    path.addQuadCurve(to:end,control:points[index])
                }
                context.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:width,lineCap:.round,lineJoin:.round))
            }

            // Background
            rect(0,0,200,200,Color(hex:CharacterAvatarConfiguration.backgroundColors[c.background] ?? 0x0A151B))
            switch c.background {
            case "Grid": for x in stride(from:0,through:200,by:20) {line([p(Double(x),0),p(Double(x),200)],accent.opacity(0.16),1)}
            case "Exchange":
                for x in stride(from:0,through:200,by:25) {line([p(Double(x),0),p(Double(x),200)],accent.opacity(0.08),1)}
                line([p(0,125),p(35,108),p(70,117),p(104,75),p(143,88),p(200,42)],accent.opacity(0.55),2)
            case "Circuit":
                for y in stride(from:8,through:200,by:24) {line([p(0,Double(y)),p(200,Double(y))],accent.opacity(0.12),1)}
                for x in stride(from:12,through:200,by:24) {line([p(Double(x),0),p(Double(x),200)],accent.opacity(0.12),1)}
            case "Starlight": for x in stride(from:18,through:185,by:33) {ellipse(Double(x),Double((x*31)%170),3,3,.white.opacity(0.7))}
            case "Matrix":
                for column in 0..<13 {
                    let x = Double(6+column*16), top = (column*37)%60
                    for k in 0..<9 where top+k*16 < 200 {rect(x,Double(top+k*16),3,8,accent.opacity(0.10+0.05*Double((column+k)%3)))}
                }
            case "Vault":
                ring(10,10,180,180,accent.opacity(0.22),3);ring(30,30,140,140,accent.opacity(0.14),2)
                for k in 0..<12 {
                    let a = Double(k) * .pi / 6
                    line([p(100+70*cos(a),100+70*sin(a)),p(100+90*cos(a),100+90*sin(a))],accent.opacity(0.20),3)
                }
            case "Aurora":
                polygon([p(0,70),p(40,40),p(90,62),p(140,30),p(200,52),p(200,88),p(140,66),p(90,96),p(40,76),p(0,104)],accent.opacity(0.22))
                polygon([p(0,104),p(50,84),p(100,104),p(150,80),p(200,96),p(200,118),p(150,102),p(100,124),p(50,106),p(0,126)],Color(hex:0x8E5CD9).opacity(0.18))
            case "Skyline":
                let towers:[(Double,Double)] = [(0,70),(22,105),(44,80),(70,120),(98,90),(124,130),(150,85),(174,110)]
                for (index,tower) in towers.enumerated() {
                    rect(tower.0,200-tower.1,24,tower.1,Color(hex:0x0A1022))
                    for wy in stride(from:Int(200-tower.1)+8,to:196,by:12) {
                        rect(tower.0+6,Double(wy),3,4,accent.opacity((index+wy)%3 != 0 ? 0.35 : 0.12))
                        rect(tower.0+14,Double(wy),3,4,accent.opacity((index+wy)%2 != 0 ? 0.12 : 0.30))
                    }
                }
            case "Blockchain":
                let blocks:[(Double,Double)] = [(14,22),(60,12),(112,26),(158,14)]
                for (index,block) in blocks.enumerated() {
                    roundedBox(block.0,block.1,30,22,4,stroke:accent.opacity(0.35),width:2)
                    if index < 3 {line([p(block.0+30,block.1+11),p(block.0+46,block.1+11+(index%2 == 0 ? 4 : -4))],accent.opacity(0.30),2)}
                }
            case "Void": ring(20,20,160,160,accent.opacity(0.10),1)
            default: break
            }
            if c.style != "Minimal" { ellipse(16,10,168,168,accent.opacity(0.14)) }
            if c.style == "Cyber" {
                for x in stride(from:12,through:188,by:16) {line([p(Double(x),0),p(Double(x),200)],accent.opacity(0.12),1)}
                for y in stride(from:8,through:200,by:16) {line([p(0,Double(y)),p(200,Double(y))],accent.opacity(0.12),1)}
            }

            // Body
            let shoulders: Double = c.presentation == "Masculine" ? 154 : c.presentation == "Feminine" ? 130 : 142
            // Hair that falls behind the head and shoulders goes under the body.
            if !special {drawHairArt(HairArt.styles[c.hair]?.back ?? [])}
            let outfit = c.clothing == "T-shirt" ? accent.opacity(0.8) : Color(hex:CharacterAvatarConfiguration.outfitColors[c.clothing] ?? 0x26333F)
            ellipse((200-shoulders)/2,141,shoulders,112,outfit)
            ellipse((200-shoulders)/2+8,176,shoulders-16,70,.black.opacity(0.12))
            let hood = c.style == "Hooded" || c.style == "Anonymous" || c.clothing == "Hoodie" || c.clothing == "Full Anonymous"
            if hood {ellipse(39,22,122,148,Color(hex:0x25323A));ellipse(48,32,104,126,Color(hex:0x101A21))}
            if c.clothing == "Spacesuit" {ellipse(31,18,138,151,Color(hex:0xB9C8CB));ellipse(37,24,126,137,accent.opacity(0.5));ellipse(45,32,110,120,Color(hex:0x101A21))}
            if !special {
                polygon([p(88,120),p(112,120),p(115,154),p(85,154)],skin)
                smooth([p(87,122),p(113,122),p(113,134),p(100,139),p(87,134)],.black.opacity(0.16))
            }
            let width = faceWidth
            let left = (200-width)/2
            let headRight = left+width
            // Skull outline: the top of every human head is this ellipse (Angular
            // has its own rounded crown on a sharp jaw), so hair and caps hug it.
            let skullCY: Double = c.face == "Round" ? 92 : c.face == "Angular" ? 77 : 96
            let skullRY: Double = c.face == "Round" ? 47 : c.face == "Angular" ? 32 : 51
            let skullRX = width/2
            /// Half-width of the skull at height y (straight sides below an Angular crown).
            func skullHalf(_ y:Double) -> Double {
                if y >= skullCY {return skullRX}
                let q = (skullCY-y)/skullRY
                return skullRX*(max(0,1-q*q)).squareRoot()
            }
            /// Skull outline from the left temple over the top to the right temple.
            /// With taper, the padding grows from 0 at the temples to full at the
            /// crown, so hair meets the side of the head instead of sticking out.
            func arcPoints(_ temple:Double,_ padX:Double,_ padY:Double,taper:Bool = true) -> [CGPoint] {
                let s0 = min(1,max(0,(skullCY-temple)/skullRY)), t0 = asin(s0)
                var points:[CGPoint] = []
                for i in 0...24 {
                    let t = t0+(Double.pi-2*t0)*Double(i)/24
                    let k = !taper ? 1 : s0 >= 1 ? 0 : max(0,(sin(t)-s0)/(1-s0)).squareRoot()
                    points.append(p(100-(skullRX+padX*k)*cos(t),skullCY-(skullRY+padY*k)*sin(t)))
                }
                if temple > skullCY {points = [p(100-skullRX,temple)]+points+[p(100+skullRX,temple)]}
                return points
            }
            /// Hair hugging the skull, closed along a natural hairline that starts
            /// just inside the head at the temples and flattens across the forehead.
            func capPoints(_ temple:Double,_ hairline:Double,_ padX:Double = 1.5,_ padY:Double = 1.5,sweep:Double = 0) -> [CGPoint] {
                var points = arcPoints(temple,padX,padY)
                let half = skullHalf(temple-4)-1
                for i in 0...16 {
                    let u = 1-2*Double(i)/16
                    // A soft arch that curves down into the temples (no flat headband
                    // edge); sweep drops the left side for a side part.
                    points.append(p(100+half*u,hairline+(temple-4-hairline)*u*u+sweep*(1-u*u)*(1-u)/2))
                }
                return points
            }
            if !special {ellipse(left-7,84,16,25,skin);ellipse(left+width-9,84,16,25,skin)}

            // Head
            switch c.face {
            case "Cat":
                polygon([p(59,79),p(57,28),p(79,56),p(121,56),p(143,28),p(141,79),p(133,129),p(100,144),p(67,129)],skin)
                polygon([p(62,39),p(68,67),p(78,57)],accent.opacity(0.7))
                polygon([p(138,39),p(132,67),p(122,57)],accent.opacity(0.7))
            case "Alien":
                // Broad upper cranium tapering to a narrow, pointed chin.
                polygon([p(100,27),p(129,38),p(148,65),p(145,94),p(128,121),p(111,139),p(100,149),p(89,139),p(72,121),p(55,94),p(52,65),p(71,38)],skin)
                ellipse(61,46,78,50,skin)
            case "Robot":
                let metal = Color(hex:0x9AA8B2), seam = Color(hex:0x6E7C86)
                rect(90,128,20,26,Color(hex:0x5E6B74))
                for y in [133.0,141.0,149.0] {rect(90,y,20,2,.black.opacity(0.25))}
                roundedBox(58,40,84,96,18,fill:metal,stroke:seam,width:3)
                rect(52,76,8,26,seam);rect(140,76,8,26,seam)
                line([p(100,40),p(100,24)],seam,3);ellipse(95,17,10,10,accent)
                roundedBox(68,78,64,22,8,fill:ink)
                rect(80,116,40,8,ink)
                for k in 0..<4 {rect(84+Double(k)*8,116,2,8,metal)}
                line([p(62,50),p(70,44)],.white.opacity(0.5),3)
            case "Angular":
                ellipse(left,45,width,64,skin)
                context.fill(HairArt.path(angularJaw(left,width,c.presentation == "Feminine")),with:.color(skin))
            default:
                context.fill(HairArt.path(headOutline(left,width,c.face == "Round" ? 47 : 51,c.presentation == "Feminine")),with:.color(skin))
            }
            if !special && c.presentation == "Feminine" {
                ellipse(left+7,98,15,9,Color(hex:0xE0736B).opacity(0.20));ellipse(left+width-22,98,15,9,Color(hex:0xE0736B).opacity(0.20))
            }

            // Hair: hand-drawn art from HairArt.swift
            if !special {drawHairArt(HairArt.styles[c.hair]?.front ?? [])}

            // Face features drawn from vector paths: eyes with whites, iris, pupil and
            // catchlight under a lid line, natural arched brows, a soft nose and a gently
            // curved mouth. Scripts/avatar_preview.py mirrors this for review.
            let fem = c.presentation == "Feminine"
            func fillPath(_ d:String,_ color:Color) {context.fill(HairArt.path(d),with:.color(color))}
            func strokePath(_ d:String,_ color:Color,_ w:CGFloat) {
                context.stroke(HairArt.path(d),with:.color(color),style:StrokeStyle(lineWidth:w,lineCap:.round,lineJoin:.round))
            }
            func eye(_ cx:Double,_ cy:Double,_ kind:String,_ side:Double) {
                if kind == "Wink" && side > 0 {
                    strokePath("M\(cx-5.5) \(cy) C\(cx-2) \(cy+3) \(cx+2) \(cy+3) \(cx+5.5) \(cy)",ink.opacity(0.9),2)
                    return
                }
                // Feminine: larger, rounder eyes with lashes. Masculine: narrower eyes, a flatter lid and a lower-lid shadow.
                let rx: Double = fem ? 5.6 : 5.0
                let ry: Double = kind == "Wide" ? (fem ? 4.6 : 3.7) : (fem ? 3.9 : 2.9)
                let ir: Double = fem ? 3.3 : 2.8
                let glow = kind == "Glow"
                if glow {ellipse(cx-8,cy-7.5,16,15,accent.opacity(0.35))}
                ellipse(cx-rx,cy-ry,rx*2,ry*2,Color(hex:0xF5F0EA))
                ellipse(cx-ir,cy+0.2-ir,ir*2,ir*2,glow ? accent : Color(hex:0x3A2B22))
                ellipse(cx-ir/2,cy+0.2-ir/2,ir,ir,glow ? accent.opacity(0.6) : Color(hex:0x0D1116))
                ellipse(cx+1.1-0.95,cy-1-0.95,1.9,1.9,.white)
                let top = cy-ry
                let drop: Double = kind == "Focused" ? 1.6 : kind == "Sly" ? 2.6 : 0
                fillPath("M\(cx-rx-1.5) \(cy-ry-3) L\(cx+rx+1.5) \(cy-ry-3) L\(cx+rx+1.5) \(cy-ry+drop+0.3) C\(cx+rx*0.5) \(top-0.8+drop) \(cx-rx*0.5) \(top-0.8+drop) \(cx-rx-1.5) \(cy-ry+drop+0.3) Z",skin)
                if kind == "Friendly" {
                    fillPath("M\(cx-rx-1.5) \(cy+ry+3) L\(cx+rx+1.5) \(cy+ry+3) L\(cx+rx+1.5) \(cy+1.2) C\(cx+rx*0.5) \(cy-0.6) \(cx-rx*0.5) \(cy-0.6) \(cx-rx-1.5) \(cy+1.2) Z",skin)
                }
                let lidArch: Double = fem ? 1 : 0.2
                strokePath("M\(cx-rx-0.6) \(cy+0.4+drop*0.4) C\(cx-rx*0.6) \(top-lidArch+drop) \(cx+rx*0.6) \(top-lidArch+drop) \(cx+rx+0.6) \(cy+0.4+drop*0.4)",ink.opacity(0.92),fem ? 2.4 : 2.0)
                if fem {
                    let ox = cx+side*(rx+0.3)
                    strokePath("M\(ox) \(cy-0.8) L\(ox+side*3.0) \(cy-2.8) M\(ox-side*1.8) \(cy-2.9) L\(ox+side*0.4) \(cy-5.2) M\(ox-side*4.0) \(cy-3.6) L\(ox-side*3.2) \(cy-6.0)",ink.opacity(0.92),1.4)
                } else {
                    strokePath("M\(cx-rx+0.8) \(cy+ry+0.9) C\(cx-1.5) \(cy+ry+1.9) \(cx+1.5) \(cy+ry+1.9) \(cx+rx-0.8) \(cy+ry+0.9)",.black.opacity(0.12),1.2)
                }
            }
            if !special {
                // Brows: a gentle arch, finer and higher for Feminine.
                for side in [-1.0,1.0] {
                    let cx = 100+side*15
                    let y: Double = (fem ? 78.6 : 80.6)+(c.eyes == "Focused" ? 0.6 : 0)
                    let lift: Double = c.eyes == "Sly" && side > 0 ? -1.6 : 0
                    let arch: Double = fem ? 2.8 : 0.5
                    let tail: Double = fem ? 1.8 : 0.6
                    strokePath("M\(cx-side*6.8) \(y+1.0+lift*0.3) Q\(cx+side*2.5) \(y-arch+lift-0.8) \(cx+side*7.4) \(y+tail+lift)",brows,fem ? 2.0 : 3.6)
                }
                eye(85,89,c.eyes,-1)
                eye(115,89,c.eyes,1)
            }
            switch c.face {
            case "Alien":
                polygon([p(63,82),p(82,75),p(93,88),p(83,108),p(69,102)],ink)
                polygon([p(137,82),p(118,75),p(107,88),p(117,108),p(131,102)],ink)
                ellipse(76,85,5,7,accent.opacity(0.55));ellipse(119,85,5,7,accent.opacity(0.55))
                line([p(94,119),p(106,119)],ink.opacity(0.7),2)
            case "Robot":
                ellipse(76,83,14,12,accent.opacity(0.95));ellipse(110,83,14,12,accent.opacity(0.95))
                ellipse(80,86,4,4,.white.opacity(0.85));ellipse(114,86,4,4,.white.opacity(0.85))
            case "Cat":
                ellipse(76,87,10,11,ink);ellipse(114,87,10,11,ink)
                polygon([p(92,105),p(108,105),p(100,114)],ink)
                line([p(100,114),p(100,121)],ink,2)
                line([p(87,117),p(100,122),p(113,117)],ink,2)
                for y in [106.0,113.0] {line([p(62,y),p(86,y+3)],ink.opacity(0.6),1);line([p(114,y+3),p(138,y)],ink.opacity(0.6),1)}
            default:
                // Inner-ear shadow and a soft nose: bridge shade, nostrils, tip highlight.
                strokePath("M\(left-4) 92 C\(left-4.5) 89 \(left-2) 87.5 \(left) 89 C\(left+1) 93 \(left+0.5) 99 \(left-1) 103",.black.opacity(0.14),1.3)
                strokePath("M\(left+width+4) 92 C\(left+width+4.5) 89 \(left+width+2) 87.5 \(left+width) 89 C\(left+width-1) 93 \(left+width-0.5) 99 \(left+width+1) 103",.black.opacity(0.14),1.3)
                strokePath("M101.5 95 C102.5 99.5 103.5 103 103.8 105.5",.black.opacity(0.13),1.3)
                strokePath("M95.8 106.2 C97 108.4 99 108.8 100 108.2 C101 108.8 103 108.4 104.2 106.2",ink.opacity(0.35),1.5)
                ellipse(96.4,102.4,7.2,4.8,.white.opacity(0.10))
                // Facial hair follows the jaw and sits under the mouth, so the
                // expression always reads. Stubble is a soft shadow, not marks.
                let right = left+width
                let bottom: Double = c.face == "Round" ? 151 : c.face == "Angular" ? 147 : 153
                let mustache = [p(85,117),p(92,112.5),p(100,114.5),p(108,112.5),p(115,117),p(110,119.5),p(100,117.5),p(90,119.5)]
                switch c.facialHair {
                case "Beard","Stubble":
                    let beard = [p(left+1,84),p(left+5,103),p(75,113),p(86,110),p(100,112),p(114,110),p(125,113),p(right-5,103),p(right-1,84),
                                 p(right+1,112),p(130,136),p(116,bottom-4),p(100,bottom),p(84,bottom-4),p(70,136),p(left-1,112)]
                    if c.facialHair == "Beard" {
                        smooth(beard,facial)
                        smooth([p(70,128),p(84,142),p(100,bottom-6),p(116,142),p(130,128),p(126,142),p(100,bottom),p(74,142)],.black.opacity(0.18))
                        smooth(mustache,facial)
                    } else {
                        // Stubble is shading on the skin, so it never spills past the jaw.
                        let head = c.face == "Angular" ? HairArt.path(angularJaw(left,width,fem)) : HairArt.path(headOutline(left,width,c.face == "Round" ? 47 : 51,fem))
                        smooth(beard,brows.opacity(0.17),clip:head)
                        smooth(mustache,brows.opacity(0.22))
                    }
                case "Mustache": smooth(mustache,facial)
                case "Goatee":
                    smooth(mustache,facial)
                    smooth([p(90,127),p(100,126),p(110,127),p(109,136),p(104,bottom-7),p(96,bottom-7),p(91,136)],facial)
                default: break
                }
                let covered = c.accessory == "Bandana" || c.accessory == "Respirator" || c.accessory == "Mask"
                let mouthInk = ink.opacity(c.facialHair == "Beard" ? 0.85 : 0.72)
                if c.facialHair == "Beard" {fillPath("M90 120.5 C95 119 105 119 110 120.5 C106 125 94 125 90 120.5 Z",Color(hex:0x8C4F45).opacity(0.9))}
                if c.eyes == "Friendly" {
                    fillPath("M90.5 119.5 C94 126.5 106 126.5 109.5 119.5 C103 121 97 121 90.5 119.5 Z",Color(hex:0x5A2328))
                    fillPath("M92.5 120.4 C97 121.6 103 121.6 107.5 120.4 L107 122 C102.5 123 97.5 123 93 122 Z",Color.white.opacity(0.92))
                } else {
                    if fem && c.facialHair != "Beard" && !covered {
                        fillPath("M91 121 C94 119 97 118.6 100 119.6 C103 118.6 106 119 109 121 C106 125.6 94 125.6 91 121 Z",Color(hex:0xB4505A).opacity(0.55))
                    }
                    if c.eyes == "Sly" {strokePath("M91 122 C95 123 101 122.6 104 121.4 C106 120.6 108 119.4 109.5 118.2",mouthInk,1.9)}
                    else if fem {strokePath("M91.5 121 C95.5 123.3 104.5 123.3 108.5 121",mouthInk,1.9)}
                    else {strokePath("M91.5 121.6 C95.5 122.8 104.5 122.8 108.5 121.6",mouthInk,2.1)}
                }
                if c.facialHair != "Beard" {strokePath("M96.5 126.8 C98.5 127.5 101.5 127.5 103.5 126.8",.black.opacity(0.07),1.1)}
            }

            // Face accessories
            if c.style == "Anonymous" || c.accessory == "Mask" {
                // The mask is drawn for a 68-wide face; widen it to this face so no cheek or jaw shows past its edges.
                let maskScale = max(1.0, (width + 6) / 68)
                func mq(_ x: Double, _ y: Double) -> CGPoint { p(100 + (x - 100) * maskScale, y) }
                let porcelain=Color(hex:0xE6EBE5)
                let contour=Color(hex:0xB7C6C1)
                polygon([mq(66,69),mq(79,61),mq(100,58),mq(121,61),mq(134,69),mq(132,113),mq(119,136),mq(100,148),mq(81,136),mq(68,113)],porcelain)
                polygon([mq(68,75),mq(75,70),mq(76,119),mq(91,140),mq(81,133),mq(69,109)],contour.opacity(0.5))
                polygon([mq(132,75),mq(125,70),mq(124,119),mq(109,140),mq(119,133),mq(131,109)],contour.opacity(0.5))
                line([mq(73,85),mq(89,82),mq(94,87)],ink,4)
                line([mq(106,87),mq(111,82),mq(127,85)],ink,4)
                polygon([mq(75,91),mq(88,89),mq(93,94),mq(85,98)],ink)
                polygon([mq(107,94),mq(112,89),mq(125,91),mq(115,98)],ink)
                line([mq(100,93),mq(95,110),mq(100,113),mq(105,110)],contour,2)
                ellipse(100+(75.0-100)*maskScale,108,13.0*maskScale,5,Color(hex:0xB97982).opacity(0.5));ellipse(100+(112.0-100)*maskScale,108,13.0*maskScale,5,Color(hex:0xB97982).opacity(0.5))
                polygon([mq(78,119),mq(87,118),mq(96,116),mq(100,119),mq(104,116),mq(113,118),mq(122,119),mq(112,123),mq(103,122),mq(100,125),mq(97,122),mq(88,123)],ink)
                line([mq(83,118),mq(76,115)],ink,2);line([mq(117,118),mq(124,115)],ink,2)
                line([mq(89,130),mq(100,133),mq(111,130)],ink.opacity(0.75),2)
                polygon([mq(94,136),mq(100,139),mq(106,136),mq(100,147)],ink)
            } else {
                switch c.accessory {
                case "Glasses","Shades","Sunglasses":
                    for x in [68.0,108.0] {roundedBox(x,83,26,20,6,fill:c.accessory == "Glasses" ? accent.opacity(0.15) : ink,stroke:accent,width:2)}
                    line([p(94,90),p(108,90)],accent)
                case "Visor":
                    roundedBox(65,82,70,22,7,fill:accent.opacity(0.85))
                    line([p(72,88),p(124,88)],.white.opacity(0.7),2)
                case "Piercing": ellipse(57,105,6,9,accent)
                case "Monocle":
                    ring(108,81,24,24,gold,2.5);ellipse(110,83,20,20,.white.opacity(0.12))
                    line([p(132,96),p(138,118),p(134,150)],gold,1.5)
                case "Eyepatch":
                    line([p(60,74),p(140,98)],ink,3);ellipse(108,80,26,22,ink)
                case "Cyber Eye":
                    roundedBox(106,80,28,22,6,fill:Color(hex:0x2A3640),stroke:accent,width:2)
                    ellipse(114,85,12,12,accent);ellipse(118,89,4,4,.white.opacity(0.9))
                    line([p(134,91),p(146,91),p(150,104)],accent.opacity(0.8),2)
                case "Bandana":
                    polygon([p(64,106),p(136,106),p(132,128),p(100,146),p(68,128)],accent.opacity(0.9))
                    for x in stride(from:74,to:128,by:10) {ellipse(Double(x),116,4,4,.white.opacity(0.35))}
                case "Respirator":
                    roundedBox(76,108,48,30,12,fill:Color(hex:0x2C3338))
                    ellipse(64,114,20,20,Color(hex:0x4A555D));ellipse(116,114,20,20,Color(hex:0x4A555D))
                    ellipse(69,119,10,10,accent.opacity(0.7));ellipse(121,119,10,10,accent.opacity(0.7))
                    for y in [116.0,122.0,128.0] {line([p(88,y),p(112,y)],.black.opacity(0.5),1.5)}
                default: break
                }
            }

            // Headwear
            switch c.accessory {
            case "Beanie":
                let dome = arcPoints(68,7,18,taper:false)
                polygon(dome+[p(headRight+4,68),p(left-4,68)],accent)
                // Folded cuff across the forehead, with knit ribs.
                let cuff = [p(left-5,58),p(100,53),p(headRight+5,58),p(headRight+5,71),p(100,67),p(left-5,71)]
                smooth(cuff,accent);smooth(cuff,.black.opacity(0.14))
                for k in 1...11 {
                    let x = left-3+(width+6)*Double(k)/12
                    line([p(x,58-4*cos((x-100)/50)),p(x,68-2*cos((x-100)/50))],.black.opacity(0.12),1)
                }
            case "Cap":
                let crown = arcPoints(66,6,20,taper:false)
                polygon(crown+[p(headRight+4,66),p(left-4,66)],accent)
                polygon(crown+[p(headRight+4,66),p(left-4,66)],.black.opacity(0.10))
                line([p(100,skullCY-skullRY-20),p(100,64)],.black.opacity(0.18),1.2);ellipse(97,skullCY-skullRY-22,6,4,accent)
                // Brim seen from the front: a curved band across the forehead.
                smooth([p(left-7,63),p(100,57),p(headRight+7,63),p(headRight+6,70),p(100,75),p(left-6,70)],accent)
                smooth([p(left-6,68),p(100,71),p(headRight+6,68),p(headRight+6,70),p(100,75),p(left-6,70)],.black.opacity(0.28))
            case "Cowboy Hat": ellipse(40,40,120,24,Color(hex:0x69452E));rect(70,20,60,29,Color(hex:0x69452E));rect(72,41,56,5,accent)
            case "Helmet":
                roundedBox(50,43,100,99,34,stroke:Color(hex:0xDCE4E6),width:9)
                line([p(60,64),p(70,49),p(90,42)],.white.opacity(0.65),4)
            case "Headphones":
                ellipse(48,61,12,53,accent);ellipse(140,61,12,53,accent)
                line([p(54,68),p(60,38),p(100,28),p(140,38),p(146,68)],accent,4)
            case "Crown":
                polygon([p(66,44),p(66,18),p(80,32),p(90,12),p(100,28),p(110,12),p(120,32),p(134,18),p(134,44)],gold)
                rect(66,38,68,8,Color(hex:0xC99B2E))
                ellipse(78,37,7,7,accent);ellipse(97,37,7,7,Color(hex:0xF06C73));ellipse(116,37,7,7,accent)
            case "Halo": ring(64,8,72,20,Color(hex:0xF4D899),4);ring(66,10,68,16,.white.opacity(0.5),1.5)
            case "Earpiece":
                ellipse(left+width-6,92,10,12,ink);ellipse(left+width-3,95,4,4,accent)
                line([p(left+width+2,104),p(left+width-8,120),p(112,122)],ink.opacity(0.8),1.5)
            default: break
            }

            // Necklines and garment details. Everything here belongs to the
            // garment and never depends on the NOID badge, so turning branding
            // off leaves a finished outfit rather than orphaned lines.
            let tee = Color(hex:0x161D24)
            func openNeck(_ depth:Double) {
                polygon([p(82,145),p(118,145),p(100,145+depth)],tee)
                smooth([p(86,143),p(114,143),p(100,145+depth*0.55)],skin)
                smooth([p(88,144),p(112,144),p(100,150)],.black.opacity(0.10))
            }
            switch c.clothing {
            case "Jacket":
                openNeck(36)
                polygon([p(72,148),p(84,143),p(99,180),p(95,200),p(78,200),p(82,168)],.black.opacity(0.20))
                polygon([p(128,148),p(116,143),p(101,180),p(105,200),p(122,200),p(118,168)],.black.opacity(0.20))
                line([p(84,143),p(99,180)],.white.opacity(0.14),1.2);line([p(116,143),p(101,180)],.white.opacity(0.14),1.2)
            case "T-shirt":
                smooth([p(81,144),p(119,144),p(116,153),p(100,158),p(84,153)],.black.opacity(0.22))
                polygon([p(86,140),p(114,140),p(114,150),p(100,154),p(86,150)],skin)
            case "Turtleneck":
                // Rolled collar sits under the chin rather than over the jaw.
                smooth([p(80,142),p(120,142),p(122,161),p(100,164),p(78,161)],Color(hex:0x2A2E38))
                for y in [149.0,155.0] {line([p(82,y),p(118,y)],.black.opacity(0.28),1.3)}
            case "Suit":
                polygon([p(80,146),p(120,146),p(100,184)],Color(hex:0xEFF2F3))
                smooth([p(89,143),p(111,143),p(100,152)],skin)
                polygon([p(84,144),p(93,146),p(100,156),p(90,158)],Color(hex:0xDCE2E5))
                polygon([p(116,144),p(107,146),p(100,156),p(110,158)],Color(hex:0xDCE2E5))
                smooth([p(97,156),p(103,156),p(105,176),p(100,184),p(95,176)],accent)
                polygon([p(72,148),p(82,144),p(99,186),p(95,200),p(78,200),p(80,168)],.black.opacity(0.30))
                polygon([p(128,148),p(118,144),p(101,186),p(105,200),p(122,200),p(120,168)],.black.opacity(0.30))
            case "Duster","Trench":
                let coat = Color(hex:c.clothing == "Trench" ? 0x4A4133 : 0x7A5236)
                openNeck(33)
                polygon([p(68,147),p(85,142),p(100,178),p(94,200),p(76,200),p(80,166)],coat)
                polygon([p(132,147),p(115,142),p(100,178),p(106,200),p(124,200),p(120,166)],coat)
                line([p(85,143),p(99,176)],.white.opacity(0.12),1.2);line([p(115,143),p(101,176)],.white.opacity(0.12),1.2)
            case "Bomber":
                smooth([p(80,143),p(120,143),p(118,152),p(100,157),p(82,152)],accent.opacity(0.55))
                for x in stride(from:84,through:116,by:4) {line([p(Double(x),145),p(Double(x),151)],.black.opacity(0.18),1)}
                line([p(100,156),p(100,200)],Color(hex:0xC7D2DD).opacity(0.8),1.6)
            case "Tactical":
                openNeck(18)
                smooth([p(70,156),p(130,156),p(132,200),p(68,200)],Color(hex:0x3A4434))
                line([p(80,148),p(78,200)],.black.opacity(0.35),4);line([p(120,148),p(122,200)],.black.opacity(0.35),4)
                for x in [82.0,103.0] {roundedBox(x,168,15,13,3,fill:Color(hex:0x48543F))}
            case "Lab Coat":
                polygon([p(82,145),p(118,145),p(100,176)],Color(hex:0x2A3640))
                smooth([p(86,143),p(114,143),p(100,162)],skin)
                polygon([p(70,148),p(85,143),p(99,178),p(95,200),p(78,200),p(82,166)],Color(hex:0xF4F7F8))
                polygon([p(130,148),p(115,143),p(101,178),p(105,200),p(122,200),p(118,166)],Color(hex:0xF4F7F8))
                line([p(85,143),p(99,178)],.black.opacity(0.14),1.2);line([p(115,143),p(101,178)],.black.opacity(0.14),1.2)
                rect(72,170,2,10,accent.opacity(0.9))
            case "Armor","Hero Armor":
                smooth([p(78,142),p(122,142),p(128,158),p(100,166),p(72,158)],Color(hex:0x4C6470))
                smooth([p(82,145),p(118,145),p(122,155),p(100,161),p(78,155)],Color(hex:0x3A505B))
                line([p(76,158),p(100,165),p(124,158)],accent.opacity(0.55),1.5)
                if c.clothing == "Hero Armor" {smooth([p(100,168),p(108,177),p(100,186),p(92,177)],accent.opacity(0.85))}
            case "Spacesuit":
                smooth([p(78,140),p(122,140),p(126,152),p(100,158),p(74,152)],Color(hex:0xB9C8CB))
                line([p(80,148),p(100,153),p(120,148)],.black.opacity(0.18),1.5)
            default: break
            }
            if hood {
                // The hood's opening: a soft dark V from the jaw down into the hood, so the neck
                // flows into the garment instead of sitting on a ring.
                smooth([p(76,149),p(124,149),p(127,157),p(100,170),p(73,157)],Color(hex:0x101A21))
                smooth([p(70,150),p(84,152),p(100,170),p(116,152),p(130,150),p(126,160),p(100,176),p(74,160)],Color(hex:0x1B252C))
                let cord = Color(hex:0xC7D2DD).opacity(0.85)
                line([p(92,160),p(89,176)],cord,1.6);line([p(108,160),p(111,176)],cord,1.6)
                roundedBox(87.5,175,3,6,1.5,fill:cord);roundedBox(109.5,175,3,6,1.5,fill:cord)
            }
            if c.jewelry == "Chain" || c.jewelry == "Double chain" || c.jewelry == "Pendant" {curve([p(84,146),p(88,160),p(100,166),p(112,160),p(116,146)],gold,2.4)}
            if c.jewelry == "Double chain" {curve([p(81,148),p(86,168),p(100,176),p(114,168),p(119,148)],Color(hex:0xF4D899),2)}
            if c.jewelry == "Pendant" {line([p(100,166),p(100,169)],gold,1.5);smooth([p(100,168),p(105,174),p(100,181),p(95,174)],accent)}

            // Finish: soft edge vignette and accent rim light inside the circular crop.
            context.fill(Path(CGRect(x:0,y:0,width:200,height:200)),
                         with:.radialGradient(Gradient(colors:[.clear,.black.opacity(0.22)]),center:p(100,100),startRadius:78,endRadius:101))
            ring(1.5,1.5,197,197,accent.opacity(0.35),2)
        }.aspectRatio(1,contentMode:.fit).clipShape(Circle()).accessibilityLabel("Customized \(configuration.style) avatar")
    }
}

struct CharacterAvatarEditor: View {
    let root: String
    @AppStorage private var raw: String
    @AppStorage private var mode: String
    init(root: String) {
        self.root=root
        _raw=AppStorage(wrappedValue:"", "profile.avatar.character."+root)
        _mode=AppStorage(wrappedValue:"legacy", "profile.avatar.mode."+root)
    }
    private var configuration: CharacterAvatarConfiguration {CharacterAvatarConfiguration.decode(raw)}
    @State private var selectedPreset="Custom"
    private func selection(_ key: WritableKeyPath<CharacterAvatarConfiguration,String>) -> Binding<String> {
        Binding(get:{configuration[keyPath:key]},set:{value in
            var updated=configuration
            if updated.style == "Pixel" && updated.rendering == nil {updated.rendering="Pixel"}
            updated[keyPath:key]=value
            if key == \.face && updated.isNonHuman {updated.removeHumanLayers()}
            if key == \.style && value == "Anonymous" && updated.isNonHuman {updated.face="Oval"}
            if key == \.accessory && value == "Mask" && updated.isNonHuman {updated.face="Oval"}
            // Choosing hair or facial hair on a non-human face switches back to a human face.
            if (key == \.hair && value != "Bald") || (key == \.facialHair && value != "None"), updated.isNonHuman {updated.face="Oval"}
            raw=updated.encoded;mode="character";selectedPreset="Custom"
        })
    }
    private func option(_ title:String,_ key:WritableKeyPath<CharacterAvatarConfiguration,String>,_ values:[String]) -> some View {
        Picker(title,selection:selection(key)) {ForEach(values,id:\.self) {Text($0).tag($0)}}
    }
    private var rendering:Binding<String> {
        Binding(get:{configuration.isPixel ? "Pixel" : "Vector"},set:{value in
            var updated=configuration
            updated.rendering=value
            if updated.style == "Pixel" {updated.style="Classic"}
            raw=updated.encoded;mode="character"
        })
    }
    private var pixelTheme:Binding<String> {
        Binding(get:{configuration.pixelTheme ?? "Neon"},set:{value in
            var updated=configuration;updated.pixelTheme=value;raw=updated.encoded;mode="character"
        })
    }
    private var jewelry:Binding<String> {
        Binding(get:{configuration.jewelry ?? "None"},set:{value in
            var updated=configuration;updated.jewelry=value == "None" ? nil : value
            raw=updated.encoded;mode="character";selectedPreset="Custom"
        })
    }
    var body: some View {
        Form {
            Section {
                HStack {Spacer();PersonalAvatar(root:root,size:180);Spacer()}
                HStack {Spacer();Text("Changes appear instantly").font(Theme.caption).foregroundStyle(Theme.secondary);Spacer()}
                Button(mode == "character" ? "Character avatar selected" : "Use this character avatar") {mode="character"}.buttonStyle(ThemedButtonStyle(prominent: true))
            }.themedRow()
            Section("Start with a character") {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:12) {
                        ForEach(CharacterAvatarConfiguration.presets.filter{$0 != "Custom"},id:\.self) {name in
                            Button {
                                raw=CharacterAvatarConfiguration.preset(name,from:configuration).encoded
                                mode="character";selectedPreset=name
                            } label: {
                                VStack(spacing:6) {
                                    CharacterAvatarArt(configuration:CharacterAvatarConfiguration.preset(name,from:configuration))
                                        .frame(width:66,height:66)
                                    Text(name).font(Theme.caption2).lineLimit(1).minimumScaleFactor(0.75)
                                }.frame(width:94).padding(.vertical,8)
                                    .background(selectedPreset == name ? Theme.mint.opacity(0.18) : Theme.panel,in:RoundedRectangle(cornerRadius:18))
                            }.buttonStyle(.plain).accessibilityLabel("Use \(name) avatar")
                        }
                    }.padding(.vertical,5)
                }
                Button("Reset to classic") {raw=CharacterAvatarConfiguration().encoded;mode="character";selectedPreset="Custom"}
            }.themedRow()
            Section("Artwork") {
                Picker("Rendering",selection:rendering) {Text("Vector").tag("Vector");Text("Pixel").tag("Pixel")}
                if configuration.isPixel {
                    Picker("Pixel palette",selection:pixelTheme) {ForEach(CharacterAvatarOptions.pixelThemes,id:\.self) {Text($0).tag($0)}}
                }
            }.themedRow()
            Section("Style and face") {
                option("Style",\.style,CharacterAvatarOptions.styles)
                option("Presentation",\.presentation,CharacterAvatarOptions.presentations)
                option("Face shape",\.face,CharacterAvatarOptions.faces)
                option("Skin tone",\.skin,CharacterAvatarOptions.skins)
                option("Expression",\.eyes,CharacterAvatarOptions.expressions)
            }.themedRow()
            Section("Hair") {
                option("Hairstyle",\.hair,CharacterAvatarOptions.hairstyles)
                option("Hair color",\.hairColor,CharacterAvatarOptions.hairColors)
                option("Facial hair",\.facialHair,CharacterAvatarOptions.facialHair)
            }.themedRow()
            Section("Clothing and accessories") {
                option("Clothing",\.clothing,CharacterAvatarOptions.clothing)
                option("Head, face or eyewear",\.accessory,CharacterAvatarOptions.accessories)
                Picker("Jewelry",selection:jewelry) {ForEach(CharacterAvatarOptions.jewelry,id:\.self) {Text($0).tag($0)}}
                option("Accent",\.accent,CharacterAvatarOptions.accents)
                option("Background",\.background,CharacterAvatarOptions.backgrounds)
            }.themedRow()
            Section {Text("Edits save and select this character automatically on this device. Share your selected avatar in chat when you want others to receive it. People using builds before 157 see newer options as the default avatar. These options describe the artwork, not verified identity or personal information.").font(Theme.footnote)}.themedRow()
        }.scrollContentBackground(.hidden).background(AmbientBackground()).navigationTitle("Create your avatar").disabled(root.isEmpty)
    }
}

/// Human head outline: an elliptical crown (cubic quarter arcs, top at y 45)
/// and a drawn jaw. Masculine has a broader, squarer chin; feminine a narrower,
/// softer one. Neither reads as a round egg or a double chin.
func headOutline(_ left:Double,_ width:Double,_ ry:Double,_ fem:Bool) -> String {
    let rx = width/2, cx = left+rx, cy = 45+ry, r = left+width, k = 0.5523, b = 45+ry*2
    func f(_ v:Double) -> String {String(format:"%.2f",v)}
    func side(_ m:Double) -> String {
        // m = +1 right half, -1 left half; points run temple -> chin centre.
        let x = {(dx:Double) in f(cx+m*dx)}
        if fem {
            return "C\(x(rx)) \(f(cy+ry*0.42)) \(x(rx-5.5)) \(f(b-13)) \(x(12.5)) \(f(b-4.2)) C\(x(7.5)) \(f(b-0.9)) \(x(3.5)) \(f(b)) \(f(cx)) \(f(b))"
        }
        return "C\(x(rx)) \(f(cy+ry*0.36)) \(x(rx-3.5)) \(f(b-15)) \(x(rx-13)) \(f(b-6.5)) C\(x(rx-18.5)) \(f(b-2)) \(x(7.5)) \(f(b)) \(f(cx)) \(f(b))"
    }
    let right = side(1)
    // Left half is traced chin -> temple, so mirror the control points in reverse.
    let lx = {(dx:Double) in f(cx-dx)}
    let left2 = fem
        ? "C\(lx(3.5)) \(f(b)) \(lx(7.5)) \(f(b-0.9)) \(lx(12.5)) \(f(b-4.2)) C\(lx(rx-5.5)) \(f(b-13)) \(lx(rx)) \(f(cy+ry*0.42)) \(f(left)) \(f(cy))"
        : "C\(lx(7.5)) \(f(b)) \(lx(rx-18.5)) \(f(b-2)) \(lx(rx-13)) \(f(b-6.5)) C\(lx(rx-3.5)) \(f(b-15)) \(lx(rx)) \(f(cy+ry*0.36)) \(f(left)) \(f(cy))"
    return "M\(f(left)) \(f(cy)) C\(f(left)) \(f(cy-ry*k)) \(f(cx-rx*k)) 45 \(f(cx)) 45 C\(f(cx+rx*k)) 45 \(f(r)) \(f(cy-ry*k)) \(f(r)) \(f(cy)) "+right+" "+left2+" Z"
}

/// Angular jaw: straight cheeks, a defined jaw corner and a short flat chin
/// with rounded corners (no knife-point and no notch).
func angularJaw(_ left:Double,_ width:Double,_ fem:Bool) -> String {
    let r = left+width
    func f(_ v:Double) -> String {String(format:"%.2f",v)}
    let chin: Double = fem ? 9 : 13, b: Double = fem ? 143 : 142
    return "M\(f(left)) 77 L\(f(r)) 77 L\(f(r-1.5)) 111 C\(f(r-2.5)) 118 \(f(100+chin+6)) 136 \(f(100+chin)) \(f(b-2)) C\(f(100+chin-3)) \(f(b)) \(f(100+3)) \(f(b+0.5)) 100 \(f(b+0.5)) C\(f(100-3)) \(f(b+0.5)) \(f(100-chin+3)) \(f(b)) \(f(100-chin)) \(f(b-2)) C\(f(100-chin-6)) 136 \(f(left+2.5)) 118 \(f(left+1.5)) 111 Z"
}

