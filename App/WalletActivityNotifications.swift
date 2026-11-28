import Foundation
import UserNotifications

/// Local alerts from independently observed wallet state. No key or address is
/// sent to a notification server. iOS may defer delivery while the app sleeps.
@MainActor enum WalletActivityNotifications {
    static let balanceKey="notifyVerifiedBalanceIncrease"
    static let sendKey="notifyFinalizedSends"
    static let assetsKey="notifyVerifiedAssets"
    static let foregroundKey="notifyWhileAppOpen"
    static let messageKey="notifyPrivateMessages"
    static let nftChangeKey="notifyNFTOwnershipChanges"
    static func authorize() async -> Bool {
        do {return try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.badge,.sound])}
        catch {return false}
    }
    private static func post(id:String,title:String,body:String,route:String?=nil,contactID:String?=nil) {
        let content=UNMutableNotificationContent()
        content.title=title;content.body=body;content.sound = .default
        if let route {content.userInfo=["route":route,"contactID":contactID ?? ""]}
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:id,content:content,trigger:nil))
    }
    static func messageReceived(id:String,contactID:String) {
        guard !PrivateChatBlocks.contains(contactID) else {return}
        WatchBridge.shared.chatArrived(contactID:contactID)
        guard UserDefaults.standard.bool(forKey:messageKey),contactID.count==64 else{return}
        post(id:"private-message-"+id,title:"Private message received",body:"Open your conversation to read it.",route:"chat",contactID:contactID)
    }
    static func observeVerifiedBalance(owner:String,micronoid:String,height:UInt64) {
        guard AddressValidator.valid(owner),let current=UInt64(micronoid),height>0 else{return}
        let key="verified-balance-alert-"+owner
        let previous=UserDefaults.standard.string(forKey:key).flatMap(UInt64.init)
        guard previous != current else{return}
        UserDefaults.standard.set(micronoid,forKey:key)
        if let previous,current>previous,UserDefaults.standard.bool(forKey:balanceKey) {
            post(id:"balance-\(owner)-\(height)",title:"NOID balance increased",body:"A newer on-device verification shows a higher NOID balance. Open the wallet for details.")
        }
    }
    static func finalizedSend(txid:String) {
        guard UserDefaults.standard.bool(forKey:sendKey) else{return}
        post(id:"send-final-"+txid,title:"Payment confirmed",body:"Your phone verified the saved payment's final receipt. Open transaction history for details.")
    }
    static func observeVerifiedAssets(owner:String,holdings:[NativeItem],height:UInt64) {
        guard AddressValidator.valid(owner),height>0 else{return}
        var tokens:[String:UInt64]=[:]
        var nfts=Set<String>()
        for item in holdings {
            if item.type=="token",item.asset.count==64,let units=UInt64(item.text("units")) {
                let (sum,overflow)=(tokens[item.asset] ?? 0).addingReportingOverflow(units)
                guard !overflow else{return}
                tokens[item.asset]=sum
            } else if item.type=="nft",item.collection.count==64,!item.text("serial").isEmpty {
                nfts.insert(item.nftDisplayID)
            }
        }
        let key="verified-assets-alert-"+owner
        let old=UserDefaults.standard.dictionary(forKey:key)
        let formerTokens=old?["tokens"] as? [String:NSNumber] ?? [:]
        let formerNFTs=Set(old?["nfts"] as? [String] ?? [])
        let snapshot:[String:Any]=["tokens":tokens.mapValues {NSNumber(value:$0)},"nfts":Array(nfts).sorted()]
        UserDefaults.standard.set(snapshot,forKey:key)
        guard old != nil,UserDefaults.standard.bool(forKey:assetsKey) else{return}
        if tokens.contains(where:{$0.value>(formerTokens[$0.key]?.uint64Value ?? 0)}) {
            post(id:"token-increase-\(owner)-\(height)",title:"Verified token balance increased",body:"The on-device node found more tokens in your wallet. Open Your assets to review.")
        }
        if !nfts.subtracting(formerNFTs).isEmpty {
            post(id:"nft-added-\(owner)-\(height)",title:"NFT added to your wallet",body:"The on-device node verified an NFT in Your assets. Open the gallery to review.")
        }
        if !formerNFTs.subtracting(nfts).isEmpty,UserDefaults.standard.bool(forKey:nftChangeKey) {
            post(id:"nft-changed-\(owner)-\(height)",title:"NFT ownership changed",body:"A previously held NFT is absent from the newly verified holdings. Review its transaction and listing status before treating it as sold.")
        }
    }
}
