import Foundation
import Combine
@preconcurrency import CoreBluetooth

/// Event-driven BLE adapter with iOS background modes and state restoration. Each phone advertises and connects, giving two
/// independent acknowledged write streams. No website or seed reaches this class.
/// All delegates use the main queue. A link is a carrier, NOT an authenticated person.
@MainActor final class NearbyTransport:NSObject,ObservableObject,CBCentralManagerDelegate,CBPeripheralManagerDelegate,CBPeripheralDelegate {
    static let serviceID=CBUUID(string:"65D68A2D-F65A-4A18-AC79-D9DC654AE110")
    static let packetID=CBUUID(string:"65D68A2D-F65A-4A18-AC79-D9DC654AE111")
    static let packetArrived=Notification.Name("Parano1dNearbyPacketArrived")
    @Published private(set) var enabled=false
    @Published private(set) var status="Nearby is off"
    @Published private(set) var links=0
    @Published private(set) var packets:[ValidatedMessage]=[]
    @Published private(set) var receivedCount=0
    @Published private(set) var writtenCount=0
    private var ownID=""
    private var relayOthers=false
    private var central:CBCentralManager?
    private var peripheral:CBPeripheralManager?
    private var characteristic:CBMutableCharacteristic?
    private var connections:[UUID:CBPeripheral]=[:]
    private var writers:[UUID:CBCharacteristic]=[:]
    private var streams:[UUID:NearbyFrameDecoder]=[:]
    private var seenAt:[UUID:Date]=[:]
    private var sent:[UUID:Set<String>]=[:]
    /// Packets a given nearby phone refused; kept across reconnects so one refused
    /// packet never blocks the rest of the queue to that phone.
    private var refused:[UUID:Set<String>]=[:]
    private struct Transfer {let id:String;let bytes:Data;var offset=0;var pending=0;var lastProgress=Date()}
    private var transfers:[UUID:Transfer]=[:]
    private var generation=UUID()
    private var validating=Set<UUID>()
    private var timer:Timer?
    private var serviceAdded=false
    private var retryAfter:[UUID:Date]=[:]
    private var failures:[UUID:Int]=[:]

    func start(identity:String,carryOthers:Bool) {
        guard !enabled,identity.count==64 else{return}
        generation=UUID();ownID=identity;relayOthers=carryOthers;enabled=true;status="Starting Bluetooth…"
        central=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionRestoreIdentifierKey:"Parano1d.mesh.central.v1"])
        peripheral=CBPeripheralManager(delegate:self,queue:.main,options:[CBPeripheralManagerOptionRestoreIdentifierKey:"Parano1d.mesh.peripheral.v1"])
        reloadStoredPackets()
        timer=Timer.scheduledTimer(withTimeInterval:5,repeats:true){[weak self] _ in Task { @MainActor [weak self] in self?.maintenance() }}
    }
    func reloadStoredPackets() {
        guard enabled else{return}
        let token=generation
        Task { @MainActor in
            do {
                let stored=try await NearbyPacketStore.shared.packets()
                for data in stored {
                    guard self.enabled,self.generation==token else{return}
                    // Stored data is not trusted merely because it was on disk.
                    if let packet=try? await ValidatedMessage.inspect(data) {
                        guard self.enabled,self.generation==token else{return}
                        if self.eligible(packet),!self.packets.contains(where:{$0.id==packet.id}) {self.packets.append(packet)}
                    }
                }
                self.pumpAll()
            } catch {if self.generation==token {self.status=error.localizedDescription}}
        }
    }
    func centralManager(_ manager:CBCentralManager,willRestoreState state:[String:Any]) {
        guard enabled else{return}
        let restored=state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for device in restored.prefix(2) {
            connections[device.identifier]=device;device.delegate=self
            if device.state == .connected {device.discoverServices([Self.serviceID])}
            else if device.state == .disconnected {manager.connect(device,options:nil)}
        }
        status="Restoring mesh connections…"
    }
    func peripheralManager(_ manager:CBPeripheralManager,willRestoreState state:[String:Any]) {
        guard enabled else{return}
        let restored=state[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        if let service=restored.first(where:{$0.uuid==Self.serviceID}),
           let value=service.characteristics?.first(where:{$0.uuid==Self.packetID}) as? CBMutableCharacteristic {
            characteristic=value;serviceAdded=true
        }
        status="Restoring mesh advertisement…"
    }
    func stop() {
        generation=UUID();enabled=false;timer?.invalidate();timer=nil
        central?.stopScan()
        for device in connections.values {central?.cancelPeripheralConnection(device)}
        peripheral?.stopAdvertising();peripheral?.removeAllServices()
        central?.delegate=nil;peripheral?.delegate=nil;central=nil;peripheral=nil;characteristic=nil
        connections.removeAll();writers.removeAll();streams.removeAll();seenAt.removeAll();sent.removeAll();transfers.removeAll();validating.removeAll();retryAfter.removeAll();failures.removeAll()
        packets=[];links=0;ownID="";relayOthers=false;serviceAdded=false;refused.removeAll();status="Nearby is off"
    }
    private func eligible(_ packet:ValidatedMessage)->Bool {relayOthers || packet.senderID==ownID || packet.recipientID==ownID}
    /// Queues a verified packet. Returns nil (without error) when the packet is
    /// valid but outside this phone's carrying scope, so the sender can move on.
    @discardableResult
    func offer(_ data:Data) async throws -> ValidatedMessage? {
        guard enabled else{throw AppFailure("Turn Nearby on first.")}
        let token=generation
        let packet=try await ValidatedMessage.inspect(data)
        guard enabled,token==generation else{throw AppFailure("Nearby stopped.")}
        guard eligible(packet) else{return nil}
        if packets.contains(where:{$0.id==packet.id}) {pumpAll();return packet}
        var evict=try Self.makeRoom(for:packet,in:packets,ownID:ownID)
        do {try await NearbyPacketStore.shared.save(packet,evicting:evict)}
        catch {
            // Another packet may have been added while this one was being checked; make room
            // again against the current queue and retry once.
            guard enabled,token==generation else{throw error}
            evict=try Self.makeRoom(for:packet,in:packets,ownID:ownID)
            try await NearbyPacketStore.shared.save(packet,evicting:evict)
        }
        guard enabled,token==generation else{return packet}
        // Concurrent validation can finish while the disk write is suspended.
        guard !packets.contains(where:{$0.id==packet.id}) else{return packet}
        packets.removeAll{evict.contains($0.id)}
        packets.append(packet);pumpAll()
        return packet
    }
    nonisolated static let queueLimit=128, perSenderLimit=16, othersLimit=96
    /// Raw bytes; the store's 8 MB file limit holds base64, which is a third larger.
    nonisolated static let queueBytes=5*1024*1024+512*1024
    /// Fair carry queue: one sender can't fill it. When there's no room, the oldest packet of
    /// the busiest other sender makes way (never your own). Nothing new is refused, so no
    /// nearby phone marks a packet as permanently rejected.
    nonisolated static func makeRoom(for packet:ValidatedMessage,in queue:[ValidatedMessage],ownID:String) throws -> Set<String> {
        var kept=queue,evict=Set<String>()
        let own=packet.senderID==ownID
        func dropOldest(from sender:String?) -> Bool {
            let pool=kept.filter{$0.senderID != ownID && (sender == nil || $0.senderID == sender)}
            let target:String
            if let sender {target=sender}
            else {
                var counts:[String:Int]=[:];for p in pool {counts[p.senderID,default:0]+=1}
                guard let busiest=counts.max(by:{$0.value == $1.value ? $0.key > $1.key : $0.value < $1.value})?.key else{return false}
                target=busiest
            }
            guard let oldest=kept.filter({$0.senderID==target && $0.senderID != ownID}).min(by:{$0.expires<$1.expires}) else{return false}
            evict.insert(oldest.id);kept.removeAll{$0.id==oldest.id};return true
        }
        if !own {while kept.filter({$0.senderID==packet.senderID}).count>=perSenderLimit {guard dropOldest(from:packet.senderID) else{break}}}
        if !own {while kept.filter({$0.senderID != ownID}).count>=othersLimit {guard dropOldest(from:nil) else{break}}}
        while kept.count>=queueLimit || kept.reduce(packet.data.count,{$0+$1.data.count})>queueBytes {
            guard dropOldest(from:nil) else{throw AppFailure("Nearby queue is full.")}
        }
        return evict
    }
    func clearStoredPackets() async throws {
        guard !enabled else{throw AppFailure("Turn Nearby off before clearing carried packets.")}
        try await NearbyPacketStore.shared.clear()
    }
    private func maintenance() {
        guard enabled else{return}
        let now=Date();let milliseconds=UInt64(now.timeIntervalSince1970*1000)
        packets.removeAll{$0.expires<=milliseconds}
        for (id,date) in seenAt where now.timeIntervalSince(date)>30 {streams.removeValue(forKey:id);seenAt.removeValue(forKey:id)}
        for (id,transfer) in transfers where now.timeIntervalSince(transfer.lastProgress)>30 {
            if let device=connections[id] {central?.cancelPeripheralConnection(device)}
        }
        pumpAll()
    }
    func centralManagerDidUpdateState(_ manager:CBCentralManager) {
        guard enabled else{return}
        if manager.state == .poweredOn {manager.scanForPeripherals(withServices:[Self.serviceID],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false]);status="Searching for nearby iPhones…"}
        else {status=manager.state == .unauthorized ? "Allow Bluetooth in iOS Settings." : "Bluetooth unavailable. Turn Nearby off, enable Bluetooth, then retry."}
    }
    func peripheralManagerDidUpdateState(_ manager:CBPeripheralManager) {
        guard enabled else{return}
        if manager.state == .poweredOn,!serviceAdded {
            serviceAdded=true
            let value=CBMutableCharacteristic(type:Self.packetID,properties:[.write],value:nil,permissions:[.writeable])
            characteristic=value
            let service=CBMutableService(type:Self.serviceID,primary:true);service.characteristics=[value];manager.add(service)
        } else if manager.state != .poweredOn {serviceAdded=false}
    }
    func peripheralManager(_ manager:CBPeripheralManager,didAdd service:CBService,error:Error?) {
        guard enabled else{return}
        if let error {status=error.localizedDescription;return}
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey:[Self.serviceID]])
    }
    func peripheralManagerDidStartAdvertising(_ manager:CBPeripheralManager,error:Error?) {if let error,enabled {status=error.localizedDescription}}
    func centralManager(_ manager:CBCentralManager,didDiscover device:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard enabled,connections.count<2,connections[device.identifier]==nil,
              (retryAfter[device.identifier] ?? .distantPast)<=Date() else{return}
        connections[device.identifier]=device;device.delegate=self
        manager.connect(device,options:nil)
        let token=generation
        DispatchQueue.main.asyncAfter(deadline:.now()+15){[weak self,weak device] in
            guard let self,let device,self.generation==token,self.writers[device.identifier]==nil else{return}
            self.central?.cancelPeripheralConnection(device)
        }
    }
    func centralManager(_ manager:CBCentralManager,didConnect device:CBPeripheral) {guard enabled else{return};device.discoverServices([Self.serviceID])}
    func centralManager(_ manager:CBCentralManager,didFailToConnect device:CBPeripheral,error:Error?) {remove(device)}
    func centralManager(_ manager:CBCentralManager,didDisconnectPeripheral device:CBPeripheral,error:Error?) {remove(device)}
    private func remove(_ device:CBPeripheral) {
        connections.removeValue(forKey:device.identifier);writers.removeValue(forKey:device.identifier);transfers.removeValue(forKey:device.identifier);sent.removeValue(forKey:device.identifier)
        links=writers.count
        guard enabled else{return}
        // Re-discover after a bounded backoff; never treat a broken ATT write as
        // delivery. The signed packet remains in the local queue for retry.
        if failures[device.identifier] == nil,failures.count>=32,
           let oldest=retryAfter.min(by:{$0.value<$1.value})?.key {
            failures.removeValue(forKey:oldest);retryAfter.removeValue(forKey:oldest)
        }
        let count=min(6,(failures[device.identifier] ?? 0)+1)
        failures[device.identifier]=count
        let delay=Double(min(60,1<<count))
        retryAfter[device.identifier]=Date().addingTimeInterval(delay)
        status="Link ended. Reconnecting when nearby; saved packets are retained."
        let token=generation
        let id=device.identifier
        DispatchQueue.main.asyncAfter(deadline:.now()+delay){[weak self] in
            guard let self,self.enabled,self.generation==token,
                  self.connections[id]==nil,self.central?.state == .poweredOn else{return}
            self.central?.stopScan()
            self.central?.scanForPeripherals(withServices:[Self.serviceID],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        }
    }
    func peripheral(_ device:CBPeripheral,didDiscoverServices error:Error?) {
        guard enabled,error==nil,let service=device.services?.first(where:{$0.uuid==Self.serviceID}) else{central?.cancelPeripheralConnection(device);return}
        device.discoverCharacteristics([Self.packetID],for:service)
    }
    func peripheral(_ device:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard enabled,error==nil,let value=service.characteristics?.first(where:{$0.uuid==Self.packetID && $0.properties.contains(.write)}) else{central?.cancelPeripheralConnection(device);return}
        writers[device.identifier]=value;links=writers.count;retryAfter.removeValue(forKey:device.identifier);failures.removeValue(forKey:device.identifier)
        status="Mesh connected · background availability is managed by iOS";pump(device.identifier)
    }
    private func pumpAll(){
        let now=UInt64(Date().timeIntervalSince1970*1000)
        packets.removeAll{$0.expires<=now}
        for id in Array(writers.keys){pump(id)}
    }
    private func pump(_ id:UUID) {
        guard enabled,let device=connections[id],let value=writers[id] else{return}
        if transfers[id]==nil {
            let now=UInt64(Date().timeIntervalSince1970*1000)
            guard let packet=packets.first(where:{$0.expires>now && !(sent[id] ?? []).contains($0.id) && !(refused[id] ?? []).contains($0.id)}),let frame=try? NearbyFrameDecoder.encode(packet.data) else{return}
            transfers[id]=Transfer(id:packet.id,bytes:frame)
        }
        guard var transfer=transfers[id],transfer.pending==0 else{return}
        let length=min(512,device.maximumWriteValueLength(for:.withResponse),transfer.bytes.count-transfer.offset)
        guard length>0 else{return}
        transfer.pending=length;transfers[id]=transfer
        device.writeValue(transfer.bytes.subdata(in:transfer.offset..<transfer.offset+length),for:value,type:.withResponse)
    }
    func peripheral(_ device:CBPeripheral,didWriteValueFor characteristic:CBCharacteristic,error:Error?) {
        guard enabled,characteristic.uuid==Self.packetID,var transfer=transfers[device.identifier] else{return}
        guard error==nil else{
            // A refusal on the final fragment means the phone rejected this packet;
            // skip it for that phone. An earlier failure is a broken link: retry later.
            if transfer.offset+transfer.pending==transfer.bytes.count {
                if refused[device.identifier,default:[]].count>=256 {refused[device.identifier]=[]}
                refused[device.identifier,default:[]].insert(transfer.id)
            }
            status="Nearby write interrupted; retry after reconnecting.";central?.cancelPeripheralConnection(device);return
        }
        transfer.offset+=transfer.pending;transfer.pending=0;transfer.lastProgress=Date()
        if transfer.offset==transfer.bytes.count {
            sent[device.identifier,default:[]].insert(transfer.id);transfers.removeValue(forKey:device.identifier);writtenCount+=1
        }else{transfers[device.identifier]=transfer}
        pump(device.identifier)
    }
    func peripheralManager(_ manager:CBPeripheralManager,didReceiveWrite requests:[CBATTRequest]) {
        guard let first=requests.first else{return}
        // This protocol uses one short write per ATT request; reject prepared batches.
        guard enabled,requests.count==1,first.offset==0,first.characteristic.uuid==Self.packetID,let data=first.value,data.count<=512,!validating.contains(first.central.identifier) else{manager.respond(to:first,withResult:.unlikelyError);return}
        let id=first.central.identifier
        guard streams[id] != nil || streams.count<4 else{manager.respond(to:first,withResult:.insufficientResources);return}
        do {
            var decoder=streams[id] ?? NearbyFrameDecoder();let frames=try decoder.feed(data)
            guard frames.count<=1 else{throw AppFailure("One packet at a time is required.")}
            streams[id]=decoder;seenAt[id]=Date()
            guard let packet=frames.first else{manager.respond(to:first,withResult:.success);return}
            validating.insert(id);let token=generation
            Task { @MainActor in
                do {
                    let accepted=try await self.offer(packet)
                    guard self.enabled,self.generation==token else{return}
                    self.validating.remove(id);self.receivedCount+=1
                    manager.respond(to:first,withResult:.success)
                    // Lets the app import a message for this wallet right away (and notify),
                    // instead of waiting for a chat screen to open.
                    if accepted != nil {NotificationCenter.default.post(name:Self.packetArrived,object:nil)}
                } catch {
                    guard self.enabled,self.generation==token else{return}
                    self.validating.remove(id);self.streams.removeValue(forKey:id);self.status="Packet rejected: \(error.localizedDescription)"
                    manager.respond(to:first,withResult:.unlikelyError)
                }
            }
        }catch{streams.removeValue(forKey:id);manager.respond(to:first,withResult:.invalidAttributeValueLength)}
    }
}
