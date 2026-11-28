import SwiftUI
import Charts

actor MarketHistoryService {
    static let shared=MarketHistoryService()
    private let session=URLSession(configuration:.ephemeral,delegate:RejectRedirects(),delegateQueue:nil)
    func fetch(asset:String,height:UInt64) async throws -> String {
        guard asset.count==64,asset.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw AppFailure("Invalid market identity.")}
        let url=URL(string:"https://tradedata.parano1d.org/history/\(asset)/\(height).json")!
        var request=URLRequest(url:url);request.timeoutInterval=20;request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode==200 else{throw AppFailure("Price history is unavailable. Try again later.")}
        var data=Data()
        for try await byte in stream {try Task.checkCancellation();guard data.count<512*1024 else{throw AppFailure("History exceeds its download limit.")};data.append(byte)}
        guard let text=String(data:data,encoding:.utf8) else{throw AppFailure("History encoding is invalid.")}
        return text
    }
}
struct MarketCandle:Identifiable {
    let height:UInt64
    let open:Double,high:Double,low:Double,close:Double
    var id:UInt64{height}
    init(_ value:[String:Any]) throws {
        guard let raw=value["height"] as? String,let height=UInt64(raw),
              let open=value["open"] as? Double,let high=value["high"] as? Double,
              let low=value["low"] as? Double,let close=value["close"] as? Double,
              [open,high,low,close].allSatisfy({$0.isFinite && $0>0}),low<=min(open,close),high>=max(open,close) else{throw AppFailure("Invalid history candle.")}
        self.height=height;self.open=open;self.high=high;self.low=low;self.close=close
    }
}
struct MarketHistoryView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let asset:String
    @EnvironmentObject private var node:DeviceNode
    @EnvironmentObject private var wallet:WalletState
    @Environment(\.scenePhase) private var phase
    @AppStorage("externalHistory") private var enabled=false
    @State private var candles:[MarketCandle]=[]
    @State private var range:String?
    @State private var failure:String?
    @State private var loading=false
    @State private var refresh=0
    private var available:Bool{enabled && !wallet.locked && !wallet.offlineMode && phase == .active}
    private var queryKey:String{"\(available)-\(asset)-\(node.verifiedHeight ?? 0)-\(node.verifiedHash ?? "")-\(refresh)"}
    var body:some View {
        Panel {
            Toggle("Trade history",isOn:$enabled)
            if !enabled {Text("Load historical prices from the ecosystem data service. It can see your IP address and the asset requested; your wallet address is not sent.").font(Theme.caption).foregroundStyle(Theme.secondary)}
            else if !available {Text("History is paused while offline or locked.").font(Theme.caption)}
            else {
                if loading {ProgressView("Checking price history…")}
                if !candles.isEmpty && !wallet.hideBalances {
                    Chart(candles) {c in
                        RuleMark(x:.value("Block",Double(c.height)),yStart:.value("Low",c.low),yEnd:.value("High",c.high)).foregroundStyle(c.close>=c.open ? Theme.mint : .orange)
                        BarMark(x:.value("Block",Double(c.height)),yStart:.value("Open",c.open),yEnd:.value("Close",c.close),width:.fixed(4)).foregroundStyle(c.close>=c.open ? Theme.mint : .orange)
                        if c.open==c.close {PointMark(x:.value("Block",Double(c.height)),y:.value("Price",c.close)).foregroundStyle(Theme.mint)}
                    }.chartXAxis{AxisMarks(values:.automatic(desiredCount:3))}.chartYAxis{AxisMarks(position:.trailing,values:.automatic(desiredCount:3))}.frame(height:180).accessibilityLabel("Historical NOID per token by block")
                }else if wallet.hideBalances {Text("••••••").font(.title)}
                if let range {Text(range).font(Theme.caption)}
                if let failure {Text(failure).font(Theme.caption).foregroundStyle(.orange)}
                Button("Refresh history"){refresh+=1}.disabled(loading)
                Text("Service-provided prices; block headers checked against your device node. This does not independently prove executions or complete historical coverage.").font(Theme.caption).foregroundStyle(Theme.secondary)
            }
        }.task(id:queryKey){await load()}
    }
    @MainActor private func load() async {
        candles=[];range=nil;failure=nil;loading=false
        guard available else{return}
        guard let height=node.verifiedHeight else{failure="Synchronize the device node to check history.";return}
        let key=queryKey;loading=true
        defer{if key==queryKey{loading=false}}
        do {
            let text=try await MarketHistoryService.shared.fetch(asset:asset,height:height)
            try Task.checkCancellation();guard key==queryKey,available else{return}
            let result=try await node.paymentOperation(["op":"market_history","asset":asset,"maximum_height":height,"history_json":text])
            try Task.checkCancellation();guard key==queryKey,available else{return}
            guard result["asset"] as? String==asset,result["headers_verified"] as? Bool==true,result["prices_verified"] as? Bool==false,
                  let values=result["candles"] as? [[String:Any]],values.count<=512,let through=result["through_height"] as? String else{throw AppFailure("History verification response is invalid.")}
            candles=try values.map{try MarketCandle($0)}
            let first=result["first_height"] as? String
            range=first.map{"Indexed blocks \($0)–\(through) · NOID per token"} ?? "No indexed blocks returned."
            if candles.isEmpty,first != nil {range="No trades reported in indexed blocks \(first!)–\(through)."}
        }catch is CancellationError {}catch{if key==queryKey{failure=error.localizedDescription}}
    }
}
