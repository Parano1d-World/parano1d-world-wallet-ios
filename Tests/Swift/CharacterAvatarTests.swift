import XCTest
@testable import Paranoid

final class CharacterAvatarTests: XCTestCase {
    func testAllPersonalizationFieldsSurviveStorageRoundTrip() {
        var selected = CharacterAvatarConfiguration()
        selected.style="Anonymous";selected.presentation="Feminine";selected.face="Angular"
        selected.skin="Deep";selected.hair="Braids";selected.hairColor="Silver"
        selected.facialHair="Beard";selected.eyes="Friendly";selected.accessory="Cap"
        selected.clothing="Hoodie";selected.accent="Purple";selected.background="Paper";selected.branding=false
        XCTAssertEqual(CharacterAvatarConfiguration.decode(selected.encoded),selected)
    }
    func testCorruptAndOversizedSavedDataFallBackWithoutCrashing() {
        XCTAssertEqual(CharacterAvatarConfiguration.decode("invalid"),CharacterAvatarConfiguration())
        XCTAssertEqual(CharacterAvatarConfiguration.decode(String(repeating:"a",count:4096)),CharacterAvatarConfiguration())
    }
    func testRetiredPresentationMigratesToSelectableValue() {
        var old=CharacterAvatarConfiguration()
        old.presentation="Androgynous"
        XCTAssertEqual(CharacterAvatarConfiguration.decode(old.encoded).presentation,"Masculine")
    }
    func testCowboyDoesNotInheritAnotherLookOrRetiredApeFace() {
        var previous=CharacterAvatarConfiguration()
        previous.face="Ape";previous.style="Anonymous";previous.accessory="Mask"
        previous.clothing="Full Anonymous";previous.facialHair="Beard"
        previous.rendering="Pixel";previous.pixelTheme="Circuit"
        let cowboy=CharacterAvatarConfiguration.preset("Cowboy",from:previous)
        XCTAssertEqual(cowboy.face,"Oval")
        XCTAssertEqual(cowboy.style,"Classic")
        XCTAssertEqual(cowboy.accessory,"Cowboy Hat")
        XCTAssertEqual(cowboy.facialHair,"None")
        XCTAssertEqual(cowboy.clothing,"Duster")
        XCTAssertTrue(cowboy.isPixel)
        XCTAssertEqual(cowboy.pixelTheme,"Circuit")
        XCTAssertFalse(CharacterAvatarConfiguration.presets.contains("Paranoid Ape"))
        XCTAssertEqual(CharacterAvatarConfiguration.decode(previous.encoded).face,"Oval")
    }
    func testRenderingChoicePreservesOlderPixelAvatarAndNewPalettes() {
        var legacy=CharacterAvatarConfiguration()
        legacy.style="Pixel"
        XCTAssertTrue(CharacterAvatarConfiguration.decode(legacy.encoded).isPixel)
        legacy.style="Classic";legacy.rendering="Pixel";legacy.pixelTheme="Circuit";legacy.hair="Spikes"
        let restored=CharacterAvatarConfiguration.decode(legacy.encoded)
        XCTAssertTrue(restored.isPixel)
        XCTAssertEqual(restored.pixelTheme,"Circuit")
        XCTAssertEqual(restored.hair,"Spikes")
    }
    func testSpeciesChoicesRemoveConflictingHumanLayersInSavedRecipes() {
        var cat=CharacterAvatarConfiguration()
        cat.face="Cat";cat.style="Anonymous";cat.accessory="Mask";cat.hair="Long";cat.facialHair="Beard"
        let normalized=CharacterAvatarConfiguration.decode(cat.encoded)
        XCTAssertEqual(normalized.face,"Cat")
        XCTAssertEqual(normalized.style,"Classic")
        XCTAssertEqual(normalized.accessory,"None")
        XCTAssertEqual(normalized.hair,"Bald")
        XCTAssertEqual(normalized.facialHair,"None")
        XCTAssertEqual(CharacterAvatarConfiguration.preset("Cyber Pilot",from:cat).face,"Oval")
    }
    func testTraderAndHeroPresetCanBeSharedWithBrandingOff() throws {
        for name in ["Crypto Trader","Cyber Hero"] {
            var choice=CharacterAvatarConfiguration.preset(name,from:CharacterAvatarConfiguration())
            choice.branding=false
            let packet=SharedAvatar(kind:"character",character:choice)
            XCTAssertTrue(packet.valid,name)
            XCTAssertEqual(SharedAvatar.parse(try packet.message())?.character?.branding,false)
        }
        let trader=CharacterAvatarConfiguration.preset("Crypto Trader",from:CharacterAvatarConfiguration())
        XCTAssertEqual(trader.accessory,"Shades")
        XCTAssertEqual(trader.jewelry,"Chain")
        XCTAssertEqual(trader.background,"Exchange")
    }
    func testEveryEditorOptionIsAcceptedWhenShared() {
        typealias O = CharacterAvatarOptions
        XCTAssertEqual(Set(O.skins),Set(CharacterAvatarConfiguration.skinColors.keys))
        XCTAssertEqual(Set(O.hairColors),Set(CharacterAvatarConfiguration.hairColors.keys))
        let fields:[(WritableKeyPath<CharacterAvatarConfiguration,String>,[String])] = [
            (\.style,O.styles),(\.presentation,O.presentations),(\.face,O.faces),(\.skin,O.skins),
            (\.eyes,O.expressions),(\.hair,O.hairstyles),(\.hairColor,O.hairColors),(\.facialHair,O.facialHair),
            (\.clothing,O.clothing),(\.accessory,O.accessories),(\.accent,O.accents),(\.background,O.backgrounds)]
        for (key,values) in fields {
            for value in values {
                var recipe=CharacterAvatarConfiguration()
                recipe[keyPath:key]=value
                XCTAssertTrue(SharedAvatar(kind:"character",character:CharacterAvatarConfiguration.decode(recipe.encoded)).valid,value)
            }
        }
        for value in O.jewelry where value != "None" {
            var recipe=CharacterAvatarConfiguration();recipe.jewelry=value
            XCTAssertTrue(SharedAvatar(kind:"character",character:recipe).valid,value)
        }
    }
    func testRobotFaceDropsHumanLayersAndNewLooksAreComplete() {
        var robot=CharacterAvatarConfiguration()
        robot.face="Robot";robot.hair="Afro";robot.facialHair="Goatee";robot.style="Anonymous";robot.accessory="Mask"
        let normalized=CharacterAvatarConfiguration.decode(robot.encoded)
        XCTAssertEqual(normalized.hair,"Bald")
        XCTAssertEqual(normalized.facialHair,"None")
        XCTAssertEqual(normalized.style,"Classic")
        XCTAssertEqual(normalized.accessory,"None")
        for name in ["Hacker","Node Runner","Miner","Robot","Ghost","Vault Keeper","Neon Ronin","Whale"] {
            XCTAssertTrue(CharacterAvatarConfiguration.presets.contains(name),name)
            let look=CharacterAvatarConfiguration.preset(name,from:normalized)
            XCTAssertEqual(CharacterAvatarConfiguration.decode(look.encoded),look,name)
        }
        XCTAssertEqual(CharacterAvatarConfiguration.preset("Whale",from:.init()).accessory,"Crown")
    }
}
