import Foundation

/// Display-only public summaries. Never supplies signing inputs or settlement authority.
actor LocalPaymentHistory {
    static let shared=LocalPaymentHistory()
    static let changed=Notification.Name("LocalPaymentHistoryChanged")
    /// Preserve the first independently verified wallet balance seen after a
    /// verified send. The block label makes clear when this balance was measured.
    func recordBalanceAtVerification(root:String,owner:String,id:String,transactionHeight:UInt64,balanceHeight:UInt64,micronoid:String) throws {
        guard balanceHeight>=transactionHeight,UInt64(micronoid) != nil,AddressValidator.valid(owner),
              id.count==64,Data(hex:id)?.count==32 else {return}
        let file=try PaymentStorage.directory(root:root).appendingPathComponent("display-"+id+".json")
        guard let bytes=try? Data(contentsOf:file),bytes.count<16384,
              var row=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              row["txid"] as? String == id,row["owner"] as? String == owner,
              row["chain_id"] as? String == (try DisplaySnapshotStore.chainID()),
              row["verified_balance_micronoid"] == nil else {return}
        row["verified_balance_micronoid"]=micronoid
        row["verified_balance_height"]=String(balanceHeight)
        let encoded=try JSONSerialization.data(withJSONObject:row,options:.sortedKeys)
        try encoded.write(to:file,options:[.atomic,.completeFileProtection])
        NotificationCenter.default.post(name:Self.changed,object:nil)
    }
    /// Update an existing local send only; a receipt for an unrelated payment
    /// must not create a wallet history row or change its recipient/amount.
    func verifiedStatus(root:String,id:String,status:String) throws {
        guard id.count==64,Data(hex:id)?.count==32 else {throw AppFailure("Invalid payment identity.")}
        let file=try PaymentStorage.directory(root:root).appendingPathComponent("display-"+id+".json")
        guard let bytes=try? Data(contentsOf:file),bytes.count<16384,
              var row=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              row["txid"] as? String == id,row["chain_id"] as? String == (try DisplaySnapshotStore.chainID()),
              (row["owner"] as? String).map(AddressValidator.valid) == true else { return }
        row["local_status"]=status
        let encoded=try JSONSerialization.data(withJSONObject:row,options:.sortedKeys)
        try encoded.write(to:file,options:[.atomic,.completeFileProtection])
        NotificationCenter.default.post(name:Self.changed,object:nil)
    }
    func record(root:String,owner:String,id:String,kind:String,amount:String?=nil,recipient:String?=nil,assetID:String?=nil,collectionID:String?=nil,serial:String?=nil,status:String) throws {
        guard id.count==64,Data(hex:id)?.count==32,AddressValidator.valid(owner) else{throw AppFailure("Invalid history identity.")}
        let directory=try PaymentStorage.directory(root:root)
        let file=directory.appendingPathComponent("display-"+id+".json")
        var row:[String:Any]=["txid":id,"owner":owner,"chain_id":try DisplaySnapshotStore.chainID(),"local_kind":kind,"local_status":status,"timestamp":Date().timeIntervalSince1970]
        if let bytes=try? Data(contentsOf:file),bytes.count<16384,let old=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] {
            row["timestamp"]=old["timestamp"]
            row["local_amount"]=old["local_amount"]
            row["recipient"]=old["recipient"]
            row["asset_id"]=old["asset_id"]
            row["collection_id"]=old["collection_id"]
            row["serial"]=old["serial"]
            row["verified_balance_micronoid"]=old["verified_balance_micronoid"]
            row["verified_balance_height"]=old["verified_balance_height"]
        }
        if let amount {row["local_amount"]=amount}
        if let recipient {row["recipient"]=recipient}
        if let assetID,assetID.count==64,Data(hex:assetID)?.count==32 {row["asset_id"]=assetID}
        if let collectionID,collectionID.count==64,Data(hex:collectionID)?.count==32 {row["collection_id"]=collectionID}
        if let serial,UInt64(serial) != nil {row["serial"]=serial}
        let bytes=try JSONSerialization.data(withJSONObject:row,options:.sortedKeys)
        guard bytes.count<16384 else{throw AppFailure("History summary too large.")}
        try bytes.write(to:file,options:[.atomic,.completeFileProtection])
        NotificationCenter.default.post(name:Self.changed,object:nil)
    }
    func load(root:String,owner:String) async throws -> [[String:Any]] {
        let directory=try PaymentStorage.directory(root:root)
        let chain=try DisplaySnapshotStore.chainID()
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey])
        var rows:[String:[String:Any]]=[:]
        let selected=files.filter{$0.lastPathComponent.hasPrefix("display-") || $0.lastPathComponent=="pending.json" || $0.lastPathComponent.hasPrefix("settled-") || $0.lastPathComponent.hasPrefix("expired-")}
        guard selected.count<=5000 else{throw AppFailure("Local history exceeded its display limit.")}
        var inspected = 0
        for file in selected {
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=3*1024*1024 else{continue}
            let bytes=try Data(contentsOf:file)
            guard let raw=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],raw["owner"] as? String==owner,raw["chain_id"] as? String==chain,
                  let id=raw["txid"] as? String,id.count==64,Data(hex:id)?.count==32 else{continue}
            var row=rows[id] ?? ["txid":id,"owner":owner]
            for key in ["local_kind","local_amount","recipient","asset_id","collection_id","serial"] { if let value=raw[key] { row[key]=value } }
            if file.lastPathComponent.hasPrefix("display-") {
                for key in ["local_kind","local_amount","recipient","asset_id","collection_id","serial","timestamp","verified_balance_micronoid","verified_balance_height"] {if let value=raw[key] {row[key]=value}}
                if let displayStatus=raw["local_status"] as? String,
                   displayStatus.hasPrefix("Finalized · verified") || displayStatus.hasPrefix("Included · awaiting") || row["local_status"] == nil {
                    row["local_status"]=displayStatus
                }
            } else {
                let state=raw["state"] as? String ?? "unknown"
                if state == "preparing" || state == "cancelled" {continue}
                let alreadyVerified=(row["local_status"] as? String)?.hasPrefix("Finalized · verified") == true
                if !alreadyVerified && (row["local_status"] == nil || state == "finalized" || state == "expired") {
                    row["local_status"]=state == "finalized" ? "Local record: previously finalized · reverify receipt" : state == "expired" ? "Authorization expired · prior settlement unknown" : "Authorized locally · settlement not verified"
                }
                if row["timestamp"] == nil {row["timestamp"]=values.contentModificationDate?.timeIntervalSince1970 ?? 0}
            }
            if row["local_amount"] == nil, inspected < 10, NativeCore.available,
               let intent = raw["intent_hex"] as? String, intent.utf8.count < 700_000 {
                inspected += 1
                if let result = try? await NativeCore.shared.call(["op":"payment_inspect","intent_hex":intent]),
                   let summary = HistoryRows.ordinaryTransfer(result,owner:owner,transactionID:id) {
                    for (key,value) in summary { row[key]=value }
                    var cached = row; cached["chain_id"]=chain
                    let destination = directory.appendingPathComponent("display-" + id + ".json")
                    if let encoded = try? JSONSerialization.data(withJSONObject:cached,options:.sortedKeys),encoded.count < 16384 {
                        try? encoded.write(to:destination,options:[.atomic,.completeFileProtection])
                    }
                }
            }
            rows[id]=row
        }
        return rows.values.sorted{($0["timestamp"] as? Double ?? 0)>($1["timestamp"] as? Double ?? 0)}
    }
}

enum HistoryRows {
    static func merge(_ previous:[[String:Any]],_ current:[[String:Any]]) -> [[String:Any]] {
        var rows:[String:[String:Any]]=[:]
        for row in previous+current {
            guard let id=row["txid"] as? String,id.count==64,Data(hex:id)?.count==32 else{continue}
            var combined=rows[id] ?? [:]
            for (key,value) in row {combined[key]=value}
            rows[id]=combined
        }
        return rows.values.sorted {
            let a=($0["timestamp"] as? NSNumber)?.doubleValue ?? 0,b=($1["timestamp"] as? NSNumber)?.doubleValue ?? 0
            return a==b ? ($0["txid"] as? String ?? "")<($1["txid"] as? String ?? "") : a>b
        }
    }
    static func ordinaryTransfer(_ inspection:[String:Any],owner:String,transactionID:String)->[String:String]? {
        guard inspection["authorized"] as? Bool == true, inspection["owner"] as? String == owner,
              inspection["txid"] as? String == transactionID,
              let outputs=inspection["outputs"] as? [[String:Any]] else { return nil }
        var recipient:String?; var total:UInt64=0
        for output in outputs {
            guard let address=output["address"] as? String,AddressValidator.valid(address),
                  let raw=output["amount_micronoid"] as? String,let amount=UInt64(raw) else { return nil }
            if address == owner { continue }
            if let recipient,recipient != address { return nil }
            recipient=address
            let (sum,overflow)=total.addingReportingOverflow(amount);guard !overflow else{return nil};total=sum
        }
        guard let recipient,total>0 else{return nil}
        return ["local_kind":"NOID transfer","local_amount":String(total),"recipient":recipient]
    }
    static func summary(_ row:[String:Any],hideAmounts:Bool=false)->String {
        if row["local_kind"] as? String == "NFT sent" {
            return "Sent NFT" + ((row["serial"] as? String).map {" #"+$0} ?? "")
        }
        if row["local_kind"] as? String == "Token sent" {return "Sent native token"}
        if row["local_kind"] as? String == "NOID transfer",let raw=row["local_amount"] as? String,let amount=Amounts.format(raw) {
            return hideAmounts ? "Sent NOID" : "Sent " + amount + " NOID"
        }
        if let received=UInt64(row["address_received_micronoid"] as? String ?? ""),
           let spent=UInt64(row["address_spent_micronoid"] as? String ?? ""), spent==0,received>0,
           row["coinbase"] as? Bool != true,let amount=Amounts.format(String(received)) {
            return hideAmounts ? "Received NOID" : "Received " + amount + " NOID"
        }
        return title(row)
    }
    static func counterparty(_ row:[String:Any])->(String,String)? {
        if let recipient=row["recipient"] as? String,AddressValidator.valid(recipient) {return ("To ",recipient)}
        // Only display explicit valid addresses; never infer a sender from aggregate inputs.
        if let sender=row["sender"] as? String,AddressValidator.valid(sender) {return ("From ",sender)}
        return nil
    }
    static func title(_ row:[String:Any])->String {
        if let kind=row["local_kind"] as? String {return kind}
        if row["coinbase"] as? Bool == true {return "Mining reward"}
        if let received=UInt64(row["address_received_micronoid"] as? String ?? ""),let spent=UInt64(row["address_spent_micronoid"] as? String ?? "") {
            if received>spent {return "NOID received"}
            if spent>received {return "NOID sent"}
        }
        return "Transaction"
    }
}
