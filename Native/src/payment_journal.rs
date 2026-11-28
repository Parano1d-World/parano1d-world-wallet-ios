//! Local ledger of unsettled authorizations for one wallet (build 165).
//! Several ordinary NOID payments may be unsettled at once when they claim different
//! coins and output slots. Each entry's claims are read from its own intent bytes.
//! Native asset operations still reserve everything (exclusive) until they settle,
//! because the native planner cannot yet project pending asset changes.
//! A timeout or restart never clears an entry; only verified finality or a verified
//! finalized expiry boundary releases it. This does not replace chain consensus.
use std::{collections::BTreeSet,fs::{self,File,OpenOptions},io::{Read,Write},path::{Path,PathBuf}};
use serde_json::{json,Value};
use sha3::{Digest,Sha3_256};

const MAX_BYTES:u64=3*1024*1024;
const MAX_LEDGER_BYTES:u64=24*1024*1024;
/// Unsettled entries allowed at once (the node planner accepts up to 100 per epoch).
pub const MAX_UNRESOLVED:usize=20;
const KEEP_TERMINAL:usize=10;
pub struct Journal {directory:PathBuf,_lock:File,entries:Vec<Value>,active:Option<String>}
fn hash(value:&Value,key:&str)->Result<String,String> {
    let text=value[key].as_str().ok_or("Missing journal identity")?;
    if text.len()!=64 || !text.bytes().all(|b|b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {return Err("Invalid journal identity".into());}
    Ok(text.to_owned())
}
fn unresolved(value:&Value)->bool {matches!(value["state"].as_str(),Some("preparing"|"authorized"))}
/// What an entry reserves: exact input coins (slot, creation id) and output slots,
/// or everything (`exclusive`) when they cannot be read from ordinary NOID bytes.
fn validate_claims(value:&Value)->Result<(),String> {
    let claims=&value["claims"];
    if claims["exclusive"]==true {return if claims.as_object().is_some_and(|o|o.len()==1) {Ok(())} else {Err("Invalid exclusive claim".into())};}
    let inputs=claims["inputs"].as_array().ok_or("Missing input claims")?;
    let outputs=claims["outputs"].as_array().ok_or("Missing output claims")?;
    if inputs.is_empty() || inputs.len()>504 || outputs.len()>126 {return Err("Claim size outside limits".into());}
    let mut seen=BTreeSet::new();
    for item in inputs {
        let pair=item.as_array().filter(|a|a.len()==2).ok_or("Invalid input claim")?;
        let slot=pair[0].as_u64().filter(|n|*n<=u64::from(u32::MAX)).ok_or("Invalid input slot")?;
        pair[1].as_u64().ok_or("Invalid input identity")?;
        if !seen.insert(slot) {return Err("Repeated input claim".into());}
    }
    let mut seen=BTreeSet::new();
    for item in outputs {
        let slot=item.as_u64().filter(|n|*n<=u64::from(u32::MAX)).ok_or("Invalid output claim")?;
        if !seen.insert(slot) {return Err("Repeated output claim".into());}
    }
    hash(claims,"epoch_anchor").map(|_|())
}
fn validate(value:&Value)->Result<(),String> {
    if value["version"]!=1 {return Err("Unsupported payment journal".into());}
    for key in ["review_hash","txid","chain_id"] {hash(value,key)?;}
    if !value["owner"].as_str().is_some_and(|s|s.starts_with("o1") && s.len()<=128) {return Err("Invalid journal owner".into());}
    validate_claims(value)?;
    match value["state"].as_str() {
        Some("preparing"|"cancelled") if value.get("intent_hex").is_none()=>Ok(()),
        Some("authorized"|"finalized"|"expired")=>{
            let encoded=value["intent_hex"].as_str().ok_or("Missing saved intent")?;
            if encoded.is_empty() || encoded.len()>2*1024*1024 {return Err("Invalid saved intent size".into());}
            let bytes=hex::decode(encoded).map_err(|_|"Invalid saved intent")?;
            if hex::encode(Sha3_256::digest(&bytes))!=hash(value,"intent_digest")? {return Err("Saved intent integrity check failed".into());}
            // Non-exclusive claims must be exactly the signed intent's own claims.
            if value["claims"]["exclusive"]!=true && intent_claims(&bytes)?!=value["claims"] {return Err("Saved claims differ from the signed payment".into());}
            if value["state"]=="finalized" && !value["finalized_height"].as_u64().is_some_and(|h|h>0) {return Err("Invalid settlement record".into());}
            if value["state"]=="expired" {
                let last=value["last_valid_height"].as_u64().ok_or("Missing expiry boundary")?;
                if last==0 || !value["verified_finalized_height"].as_u64().is_some_and(|h|h>=last) || value["settlement_status"]!="unknown" {return Err("Invalid expiry evidence".into());}
            }
            Ok(())
        },
        _=>Err("Invalid payment journal state".into())
    }
}
/// Exact slots any intent this wallet signs will use: ordinary NOID payments and native
/// token/NFT intents share the same page format. Trades reserve everything.
pub fn intent_claims(intent:&[u8])->Result<Value,String> {
    use noid_tx::native_assets::{wire::{NativeIntent,NATIVE_INTENT_MAGIC},trade::wire::TRADE_OWNER_INTENT_MAGIC};
    if intent.starts_with(TRADE_OWNER_INTENT_MAGIC) {return Ok(json!({"exclusive":true}));}
    if intent.starts_with(NATIVE_INTENT_MAGIC) {
        let native=NativeIntent::from_bytes(intent).map_err(|e|e.to_string())?;
        return page_claims(&native.pages);
    }
    noid_claims(intent)
}
/// Reads the exact coins and output slots an ordinary NOID intent (signed or not) uses.
pub fn noid_claims(intent:&[u8])->Result<Value,String> {
    let intent=noid_tx::PagedSpendIntent::from_bytes(intent).map_err(|e|e.to_string())?;
    page_claims(&intent.pages)
}
fn page_claims(pages:&[noid_tx::TxPage])->Result<Value,String> {
    let first=pages.first().ok_or("Empty payment")?;
    let anchor=first.body.epoch_anchor;
    let mut inputs=std::collections::BTreeMap::new();let mut outputs=BTreeSet::new();
    for page in pages {
        if page.body.epoch_anchor!=anchor {return Err("Payment pages disagree on epoch".into());}
        for (_,input) in page.body.live_inputs() {
            if inputs.insert(input.slot_index,input.creation_id).is_some() {return Err("Repeated input slot".into());}
        }
        for (_,output) in page.body.live_outputs() {
            if !outputs.insert(output.slot_index) {return Err("Repeated output slot".into());}
        }
    }
    if inputs.is_empty() {return Err("Payment spends no coin".into());}
    Ok(json!({"inputs":inputs.into_iter().map(|(s,c)|json!([s,c])).collect::<Vec<_>>(),
              "outputs":outputs.into_iter().collect::<Vec<_>>(),"epoch_anchor":hex::encode(anchor)}))
}
fn claim_sets(claims:&Value)->(bool,BTreeSet<u64>,BTreeSet<u64>) {
    if claims["exclusive"]==true {return (true,BTreeSet::new(),BTreeSet::new());}
    let inputs=claims["inputs"].as_array().map(|a|a.iter().filter_map(|i|i[0].as_u64()).collect()).unwrap_or_default();
    let outputs=claims["outputs"].as_array().map(|a|a.iter().filter_map(Value::as_u64).collect()).unwrap_or_default();
    (false,inputs,outputs)
}
/// Two entries conflict if either reserves everything or they share an input coin or an output slot.
pub fn conflicts(a:&Value,b:&Value)->bool {
    let (ea,ia,oa)=claim_sets(a);let (eb,ib,ob)=claim_sets(b);
    ea || eb || !ia.is_disjoint(&ib) || !oa.is_disjoint(&ob)
}
fn ordinary(path:&Path)->Result<(),String> {
    match fs::symlink_metadata(path) {
        Ok(m) if !m.file_type().is_file()=>Err("Payment journal path is not an ordinary file".into()),
        Ok(_)=>Ok(()),Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(()),
        Err(_)=>Err("Cannot inspect payment journal".into())
    }
}
fn read_bounded(path:&Path,limit:u64)->Result<Option<Vec<u8>>,String> {
    ordinary(path)?;
    match File::open(path) {
        Ok(file)=>{
            if file.metadata().map_err(|_|"Cannot inspect payment journal")?.len()>limit {return Err("Payment journal too large".into());}
            let mut bytes=Vec::new();file.take(limit+1).read_to_end(&mut bytes).map_err(|_|"Cannot read payment journal")?;
            if bytes.len() as u64>limit {return Err("Payment journal too large".into());}
            Ok(Some(bytes))
        },
        Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(None),
        Err(_)=>Err("Cannot read payment journal".into())
    }
}
impl Journal {
    pub fn open(directory:&Path)->Result<Self,String> {
        if !directory.is_absolute() {return Err("Payment journal requires an absolute app-owned path".into());}
        let meta=fs::symlink_metadata(directory).map_err(|_|"Create protected payment storage first")?;
        if !meta.is_dir() || meta.file_type().is_symlink() {return Err("Invalid payment storage directory".into());}
        let directory=directory.canonicalize().map_err(|_|"Invalid payment storage")?;
        let lock_path=directory.join("payment.lock");ordinary(&lock_path)?;
        let lock=OpenOptions::new().read(true).write(true).create(true).truncate(false).open(lock_path).map_err(|_|"Cannot open payment lock")?;
        lock.lock().map_err(|_|"Cannot lock payment journal")?;
        let mut journal=Self{directory:directory.clone(),_lock:lock,entries:Vec::new(),active:None};
        if let Some(bytes)=read_bounded(&directory.join("ledger.json"),MAX_LEDGER_BYTES)? {
            let ledger:Value=serde_json::from_slice(&bytes).map_err(|_|"Payment ledger is damaged; do not overwrite it")?;
            if ledger["version"]!=2 {return Err("Unsupported payment ledger".into());}
            let entries=ledger["entries"].as_array().ok_or("Invalid payment ledger")?.clone();
            let mut ids=BTreeSet::new();
            for entry in &entries {validate(entry)?;if !ids.insert(hash(entry,"txid")?) {return Err("Repeated payment in ledger".into());}}
            if entries.iter().filter(|e|unresolved(e)).count()>MAX_UNRESOLVED {return Err("Payment ledger exceeds its limit".into());}
            journal.entries=entries;
            // A migration that committed the ledger but stopped before retiring the old file.
            if directory.join("pending.json").exists() {fs::rename(directory.join("pending.json"),directory.join("pending.migrated.json")).map_err(|_|"Cannot finish payment migration")?;}
        } else if let Some(bytes)=read_bounded(&directory.join("pending.json"),MAX_BYTES)? {
            // One-time, crash-safe migration from the single pending record.
            let mut record:Value=serde_json::from_slice(&bytes).map_err(|_|"Payment journal is damaged; do not overwrite it")?;
            let claims=match (record["operation_kind"].as_str(),record["intent_hex"].as_str()) {
                (Some("ordinary"|"native"),Some(encoded))=>intent_claims(&hex::decode(encoded).map_err(|_|"Invalid saved intent")?).unwrap_or(json!({"exclusive":true})),
                _=>json!({"exclusive":true}),
            };
            record["claims"]=claims;
            validate(&record)?;
            journal.entries=vec![record];
            journal.commit()?;
            fs::rename(directory.join("pending.json"),directory.join("pending.migrated.json")).map_err(|_|"Cannot finish payment migration")?;
        }
        Ok(journal)
    }
    fn commit(&mut self)->Result<(),String> {
        for entry in &self.entries {validate(entry)?;}
        // Keep every unsettled entry and the most recent settled ones for display.
        let terminal:Vec<usize>=self.entries.iter().enumerate().filter(|(_,e)|!unresolved(e)).map(|(i,_)|i).collect();
        if terminal.len()>KEEP_TERMINAL {
            let drop:BTreeSet<usize>=terminal[..terminal.len()-KEEP_TERMINAL].iter().copied().collect();
            let active=self.active.clone();
            let mut index=0;self.entries.retain(|e|{let keep=!drop.contains(&index) || active.as_deref()==e["txid"].as_str();index+=1;keep});
        }
        let bytes=serde_json::to_vec(&json!({"version":2,"entries":self.entries})).map_err(|_|"Cannot encode payment ledger")?;
        if bytes.len() as u64>MAX_LEDGER_BYTES {return Err("Payment ledger too large".into());}
        let temp=self.directory.join("ledger.next");ordinary(&temp)?;
        let mut file=OpenOptions::new().write(true).create(true).truncate(true).open(&temp).map_err(|_|"Cannot stage payment ledger")?;
        file.write_all(&bytes).and_then(|_|file.sync_all()).map_err(|_|"Cannot durably save pending payment")?;
        fs::rename(&temp,self.directory.join("ledger.json")).map_err(|_|"Cannot commit pending payment")?;
        File::open(&self.directory).and_then(|f|f.sync_all()).map_err(|_|"Cannot synchronize payment storage")?;
        Ok(())
    }
    fn index(&self,txid:&str)->Option<usize> {self.entries.iter().position(|e|e["txid"]==txid)}
    fn active_index(&self)->Result<usize,String> {self.active.as_deref().and_then(|t|self.index(t)).ok_or_else(||"No reserved payment".into())}
    fn put(&mut self,record:Value)->Result<(),String> {
        validate(&record)?;
        let txid=hash(&record,"txid")?;
        let previous=match self.index(&txid) {Some(i)=>Some(std::mem::replace(&mut self.entries[i],record)),None=>{self.entries.push(record);None}};
        if let Err(error)=self.commit() {
            match previous {Some(old)=>{if let Some(i)=self.index(&txid){self.entries[i]=old;}},None=>{self.entries.retain(|e|e["txid"]!=txid.as_str());}}
            return Err(error);
        }
        Ok(())
    }
    /// Starts (or resumes) an authorization that reserves everything until it settles.
    pub fn begin(&mut self,review_hash:&str,txid:&str,chain:&str,owner:&str)->Result<Option<String>,String> {
        self.begin_claims(review_hash,txid,chain,owner,json!({"exclusive":true}))
    }
    /// Starts (or resumes) an authorization with its exact claims. Refused while any
    /// unsettled entry shares a coin or an output slot with it, under the file lock.
    pub fn begin_claims(&mut self,review_hash:&str,txid:&str,chain:&str,owner:&str,claims:Value)->Result<Option<String>,String> {
        if let Some(i)=self.index(txid) {
            let record=&self.entries[i];
            if unresolved(record) {
                if record["review_hash"]!=review_hash || record["chain_id"]!=chain || record["owner"]!=owner {return Err("An unresolved payment already exists. Reconcile it before authorizing another payment".into());}
                self.active=Some(txid.to_owned());
                return Ok(record["intent_hex"].as_str().map(str::to_owned));
            }
        }
        let candidate=json!({"version":1,"state":"preparing","review_hash":review_hash,"txid":txid,"chain_id":chain,"owner":owner,"claims":claims});
        validate(&candidate)?;
        let open:Vec<&Value>=self.entries.iter().filter(|e|unresolved(e)).collect();
        if open.len()>=MAX_UNRESOLVED {return Err("Too many unsettled payments. Wait for some to confirm".into());}
        if open.iter().any(|e|conflicts(&e["claims"],&candidate["claims"])) {
            return Err(if open.iter().any(|e|e["claims"]["exclusive"]==true) || candidate["claims"]["exclusive"]==true
                {"An unresolved payment already exists. Reconcile it before authorizing another payment".into()}
                else {"This payment would reuse coins held by a pending payment. Review it again to choose other coins".into()});
        }
        self.put(candidate)?;
        self.active=Some(txid.to_owned());
        Ok(None)
    }
    pub fn note_noid_transfer(&mut self,txid:&str,recipient:&str,amount:&str,fee:&str)->Result<(),String> {
        let i=self.index(txid).ok_or("Payment display identity mismatch")?;
        let mut record=self.entries[i].clone();
        if !matches!(record["state"].as_str(),Some("preparing"|"authorized")) {return Err("Payment display identity mismatch".into());}
        noid_poseidon2b::primitives::Address::parse(recipient).map_err(|_|"Invalid display recipient")?;
        let units=amount.parse::<u64>().map_err(|_|"Invalid display amount")?;
        if units==0 || units.to_string()!=amount {return Err("Invalid display amount".into());}
        let fee_units=fee.parse::<u64>().map_err(|_|"Invalid display fee")?;
        if fee_units.to_string()!=fee {return Err("Invalid display fee".into());}
        let total=units.checked_add(fee_units).ok_or("Reserved total overflow")?;
        record["local_kind"]=json!("NOID transfer");record["local_amount"]=json!(amount);
        record["local_fee"]=json!(fee);record["local_reserved_total"]=json!(total.to_string());record["recipient"]=json!(recipient);
        self.put(record)
    }
    /// Display metadata from the SDK-reviewed plan, never used as spendability evidence.
    pub fn note_native_review(&mut self,txid:&str,review:&Value)->Result<(),String> {
        let i=self.index(txid).ok_or("Native review identity mismatch")?;
        let mut record=self.entries[i].clone();
        if record["state"]!="preparing" {return Err("Native review identity mismatch".into());}
        let request=review["request"].as_object().ok_or("Missing native review request")?;
        let action=request.get("action").and_then(Value::as_str).ok_or("Missing native action")?;
        if action.len()>64 || !action.bytes().all(|b|b.is_ascii_lowercase() || b==b'_') {return Err("Invalid native action".into())}
        let fee=review["fee_micronoid"].as_str().ok_or("Missing native network fee")?;
        let fee_units=fee.parse::<u64>().map_err(|_|"Invalid native network fee")?;
        if fee_units.to_string()!=fee {return Err("Noncanonical native network fee".into());}
        record["local_kind"]=json!("Native asset operation");
        record["local_fee"]=json!(fee);
        record["local_native_request"]=json!(request);
        self.put(record)
    }
    pub fn cancel_preparing(&mut self,txid:&str)->Result<(),String> {
        let i=self.index(txid).ok_or("No preparation to cancel")?;
        let mut record=self.entries[i].clone();
        if record["state"]!="preparing" || record.get("intent_hex").is_some(){return Err("A signed payment cannot be cancelled by this action".into());}
        // The file lock waits for any active prover. Signed bytes only leave the FFI
        // after authorized() persists them, so preparing means nothing was exported.
        record["state"]=json!("cancelled");self.put(record)
    }
    /// The entry this journal is working on; else the oldest unsettled entry; else the
    /// most recent settled one (kept for display).
    pub fn current(&self)->Option<Value> {
        if let Some(i)=self.active.as_deref().and_then(|t|self.index(t)) {return Some(self.entries[i].clone());}
        self.entries.iter().find(|e|unresolved(e)).or_else(||self.entries.last()).cloned()
    }
    pub fn entry(&self,txid:&str)->Option<Value> {self.index(txid).map(|i|self.entries[i].clone())}
    pub fn entries(&self)->Vec<Value> {self.entries.clone()}
    pub fn unresolved_entries(&self)->Vec<Value> {self.entries.iter().filter(|e|unresolved(e)).cloned().collect()}
    /// Only the node adapter calls this after independent FINALIZED receipt verification.
    pub fn mark_finalized(&mut self,txid:&str,height:u64)->Result<(),String> {
        let i=self.index(txid).ok_or("No pending payment")?;
        let mut record=self.entries[i].clone();
        if !matches!(record["state"].as_str(),Some("authorized"|"finalized")) || height==0 {return Err("Settlement does not match authorized payment".into());}
        record["state"]=json!("finalized");record["finalized_height"]=json!(height);validate(&record)?;
        self.active=Some(txid.to_owned());
        self.archive_terminal(record, &format!("settled-{txid}.json"))
    }
    /// Node-only transition after the old epoch's last eligible block is finalized.
    /// This releases local reservations; it does NOT assert that payment failed.
    pub fn mark_expired(&mut self,txid:&str,last:u64,finalized:u64)->Result<(),String> {
        let i=self.index(txid).ok_or("No pending payment")?;
        let mut record=self.entries[i].clone();
        if record["state"]!="authorized" || last==0 || finalized<last {return Err("Expiry does not match a finalized authorization boundary".into());}
        record["state"]=json!("expired");record["last_valid_height"]=json!(last);record["verified_finalized_height"]=json!(finalized);record["settlement_status"]=json!("unknown");
        self.active=Some(txid.to_owned());
        self.archive_terminal(record,&format!("expired-{txid}.json"))
    }
    fn archive_terminal(&mut self,record:Value,name:&str)->Result<(),String> {
        validate(&record)?;
        let bytes=serde_json::to_vec(&record).map_err(|_|"Cannot encode settlement")?;
        let history=self.directory.join(name);ordinary(&history)?;
        // Stage and fsync before publishing: a power loss must not leave a
        // partial immutable archive which prevents all subsequent reconciliation.
        let staged=self.directory.join("settlement.next");ordinary(&staged)?;
        let mut file=OpenOptions::new().write(true).create(true).truncate(true).open(&staged).map_err(|_|"Cannot stage settlement")?;
        file.write_all(&bytes).and_then(|_|file.sync_all()).map_err(|_|"Cannot save settlement history")?;
        match fs::hard_link(&staged,&history) {
            Ok(())=>{},
            Err(e) if e.kind()==std::io::ErrorKind::AlreadyExists=>{
                if fs::metadata(&history).map_err(|_|"Cannot inspect settlement")?.len()>MAX_BYTES || fs::read(&history).map_err(|_|"Cannot read settlement")?!=bytes {return Err("Conflicting settlement history".into());}
            },
            Err(_)=>return Err("Cannot archive settlement".into())
        }
        fs::remove_file(&staged).map_err(|_|"Cannot clean settlement staging")?;
        File::open(&self.directory).and_then(|f|f.sync_all()).map_err(|_|"Cannot synchronize settlement archive")?;
        self.put(record)
    }
    pub fn authorized(&mut self,intent:&[u8])->Result<(),String> {
        self.authorized_kind(intent,"ordinary")
    }
    pub fn authorized_offline(&mut self,intent:&[u8])->Result<(),String> {
        self.authorized_kind_delivery(intent,"ordinary",true)
    }
    pub fn authorized_kind(&mut self,intent:&[u8],kind:&str)->Result<(),String> {
        self.authorized_kind_delivery(intent,kind,false)
    }
    fn authorized_kind_delivery(&mut self,intent:&[u8],kind:&str,offline:bool)->Result<(),String> {
        if !matches!(kind,"ordinary"|"native"){return Err("Unknown payment kind".into());}
        let i=self.active_index()?;
        let mut record=self.entries[i].clone();
        if record["state"]!="preparing" {return Err("Payment is already authorized".into());}
        record["state"]=json!("authorized");record["intent_hex"]=json!(hex::encode(intent));record["intent_digest"]=json!(hex::encode(Sha3_256::digest(intent)));
        record["operation_kind"]=json!(kind);
        if record["claims"]["exclusive"]==true && kind=="native" {
            if let Ok(exact)=intent_claims(intent) {record["claims"]=exact;}
        }
        if offline {record["offline_delivery"]=json!(true);}
        self.put(record)
    }
}

#[cfg(test)] mod tests {
    use super::*;
    static COUNTER:std::sync::atomic::AtomicUsize=std::sync::atomic::AtomicUsize::new(0);
    struct Temp(PathBuf);
    impl Temp {fn new()->Self{let p=std::env::temp_dir().join(format!("noid-journal-{}-{}",std::process::id(),COUNTER.fetch_add(1,std::sync::atomic::Ordering::SeqCst)));fs::create_dir(&p).unwrap();Self(p)}}
    impl Drop for Temp {fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
    fn begin(j:&mut Journal,id:char)->Result<Option<String>,String>{j.begin(&id.to_string().repeat(64),&"b".repeat(64),&"c".repeat(64),"o1test")}
    #[test] fn restart_blocks_conflicting_payment_and_resumes_identical_review(){let t=Temp::new();{let mut j=Journal::open(&t.0).unwrap();assert_eq!(begin(&mut j,'a').unwrap(),None);}let mut j=Journal::open(&t.0).unwrap();assert!(begin(&mut j,'d').is_err());assert_eq!(begin(&mut j,'a').unwrap(),None);}
    #[test] fn retry_returns_identical_saved_authorization(){let t=Temp::new();{let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();j.authorized(&[1,2,3]).unwrap();}let mut j=Journal::open(&t.0).unwrap();assert_eq!(begin(&mut j,'a').unwrap(),Some("010203".into()));assert!(begin(&mut j,'d').is_err());}
    #[test] fn offline_delivery_survives_restart_without_changing_signed_bytes(){let t=Temp::new();{let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();j.authorized_offline(&[1,2,3]).unwrap();}let j=Journal::open(&t.0).unwrap();let saved=j.current().unwrap();assert_eq!(saved["state"],"authorized");assert_eq!(saved["offline_delivery"],true);assert_eq!(saved["intent_hex"],"010203");}
    #[test] fn corruption_fails_closed(){let t=Temp::new();fs::write(t.0.join("pending.json"),b"broken").unwrap();assert!(Journal::open(&t.0).is_err());assert_eq!(fs::read(t.0.join("pending.json")).unwrap(),b"broken");}
    #[test] fn tampered_saved_intent_fails_closed(){let t=Temp::new();{let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();j.authorized(&[1]).unwrap();}let path=t.0.join("ledger.json");let mut value:Value=serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();value["entries"][0]["intent_hex"]=json!("02");fs::write(path,serde_json::to_vec(&value).unwrap()).unwrap();assert!(Journal::open(&t.0).is_err());}
    #[test] fn concurrent_authorizations_are_serialized(){let t=Temp::new();let paths=[t.0.clone(),t.0.clone()];let handles:Vec<_>=paths.into_iter().enumerate().map(|(i,p)|std::thread::spawn(move||{let mut j=Journal::open(&p).unwrap();begin(&mut j,if i==0{'a'}else{'d'}).is_ok()})).collect();assert_eq!(handles.into_iter().filter_map(|h|h.join().ok()).filter(|v|*v).count(),1);}
    #[test] fn cancel_only_unexported_preparation(){let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();assert!(j.cancel_preparing(&"d".repeat(64)).is_err());j.cancel_preparing(&"b".repeat(64)).unwrap();begin(&mut j,'d').unwrap();j.authorized(&[1]).unwrap();assert!(j.cancel_preparing(&"b".repeat(64)).is_err());}
    #[test] fn settlement_requires_authorized_matching_identity_and_survives_restart(){let t=Temp::new();{let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();assert!(j.mark_finalized(&"b".repeat(64),5).is_err());j.authorized(&[1]).unwrap();assert!(j.mark_finalized(&"d".repeat(64),5).is_err());j.mark_finalized(&"b".repeat(64),5).unwrap();}let mut j=Journal::open(&t.0).unwrap();assert_eq!(j.current().unwrap()["state"],"finalized");assert!(begin(&mut j,'d').is_ok());assert!(t.0.join(format!("settled-{}.json","b".repeat(64))).exists());}
    #[test] fn expiry_preserves_unknown_settlement_and_releases_only_matching_authorized_record(){
        let t=Temp::new();{let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();
        assert!(j.mark_expired(&"b".repeat(64),144,144).is_err());j.authorized(&[1]).unwrap();
        assert!(j.mark_expired(&"d".repeat(64),144,144).is_err());assert!(j.mark_expired(&"b".repeat(64),144,143).is_err());
        j.mark_expired(&"b".repeat(64),144,144).unwrap();assert_eq!(j.current().unwrap()["settlement_status"],"unknown");}
        let mut j=Journal::open(&t.0).unwrap();assert_eq!(j.current().unwrap()["state"],"expired");assert!(begin(&mut j,'d').is_ok());
        assert!(t.0.join(format!("expired-{}.json","b".repeat(64))).exists());
    }
    #[test] fn native_operations_require_the_same_finalized_recovery_boundary(){let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();j.authorized_kind(&[1],"native").unwrap();assert!(j.mark_expired(&"b".repeat(64),144,143).is_err());assert_eq!(j.current().unwrap()["state"],"authorized");}
    #[test] fn native_pending_display_includes_fee_and_asset_identity_after_restart(){
        let t=Temp::new();
        {let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();
         let review=json!({"request":{"action":"transfer_nft","collection_id":"a".repeat(64),"serial":"7"},"fee_micronoid":"9000"});
         j.note_native_review(&"b".repeat(64),&review).unwrap();j.authorized_kind(&[1],"native").unwrap();}
        let record=Journal::open(&t.0).unwrap().current().unwrap();
        assert_eq!(record["local_fee"],"9000");
        assert_eq!(record["local_native_request"]["serial"],"7");
    }
    #[test] fn interrupted_staging_does_not_replace_committed_record(){let t=Temp::new();{let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();}fs::write(t.0.join("ledger.next"),b"partial").unwrap();let mut j=Journal::open(&t.0).unwrap();assert!(begin(&mut j,'d').is_err());assert!(begin(&mut j,'a').is_ok());}
    #[test] fn interrupted_settlement_staging_can_be_retried(){let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();j.authorized(&[1]).unwrap();fs::write(t.0.join("settlement.next"),b"partial").unwrap();j.mark_finalized(&"b".repeat(64),5).unwrap();j.mark_finalized(&"b".repeat(64),5).unwrap();assert!(!t.0.join("settlement.next").exists());assert!(j.mark_finalized(&"b".repeat(64),6).is_err());assert_eq!(j.current().unwrap()["finalized_height"],5);}
    #[test] fn payment_display_survives_authorization_restart_and_settlement() {
        let t=Temp::new();
        // Shared by wallet and node crates; this fixture needs no wallet-only derivation helper.
        let secret=noid_poseidon2b::primitives::SpendSecret::from_bytes([7;32]);
        let recipient=noid_poseidon2b::primitives::derive_address(&secret).to_bech32();
        {let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();
         assert!(j.note_noid_transfer(&"d".repeat(64),&recipient,"1000000","9000").is_err());
         j.note_noid_transfer(&"b".repeat(64),&recipient,"1000000","9000").unwrap();j.authorized(&[1]).unwrap();}
        let mut j=Journal::open(&t.0).unwrap();
        assert_eq!(j.current().unwrap()["local_amount"],"1000000");
        assert_eq!(j.current().unwrap()["local_fee"],"9000");
        assert_eq!(j.current().unwrap()["local_reserved_total"],"1009000");
        assert_eq!(j.current().unwrap()["recipient"],recipient);
        j.mark_finalized(&"b".repeat(64),5).unwrap();
        let saved:Value=serde_json::from_slice(&fs::read(t.0.join(format!("settled-{}.json","b".repeat(64)))).unwrap()).unwrap();
        assert_eq!(saved["local_kind"],"NOID transfer");assert_eq!(saved["local_amount"],"1000000");
    }
    #[test] fn amount_and_fee_overflow_never_become_a_reservation() {
        let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();begin(&mut j,'a').unwrap();
        let secret=noid_poseidon2b::primitives::SpendSecret::from_bytes([7;32]);
        let recipient=noid_poseidon2b::primitives::derive_address(&secret).to_bech32();
        assert!(j.note_noid_transfer(&"b".repeat(64),&recipient,&u64::MAX.to_string(),"1").is_err());
        assert!(j.current().unwrap().get("local_reserved_total").is_none());
    }

    fn claims(inputs:&[(u64,u64)],outputs:&[u64])->Value{json!({"inputs":inputs.iter().map(|(s,c)|json!([s,c])).collect::<Vec<_>>(),"outputs":outputs,"epoch_anchor":"e".repeat(64)})}
    fn start(j:&mut Journal,tx:char,c:Value)->Result<Option<String>,String>{j.begin_claims(&tx.to_string().repeat(64),&tx.to_string().repeat(64),&"c".repeat(64),"o1test",c)}
    #[test] fn independent_payments_can_be_pending_together(){
        let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();
        start(&mut j,'1',claims(&[(10,1)],&[20,21])).unwrap();
        start(&mut j,'2',claims(&[(11,2)],&[22,23])).unwrap();
        start(&mut j,'3',claims(&[(12,3),(13,4)],&[24])).unwrap();
        drop(j);
        assert_eq!(Journal::open(&t.0).unwrap().unresolved_entries().len(),3);
    }
    #[test] fn a_coin_or_output_slot_cannot_be_used_twice(){
        let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();
        start(&mut j,'1',claims(&[(10,1)],&[20,21])).unwrap();
        assert!(start(&mut j,'2',claims(&[(10,1)],&[30])).unwrap_err().contains("reuse coins"));
        assert!(start(&mut j,'3',claims(&[(11,1)],&[21])).unwrap_err().contains("reuse coins"));
        // The same coin with another incarnation still conflicts by slot.
        assert!(start(&mut j,'4',claims(&[(10,9)],&[31])).is_err());
        assert_eq!(j.unresolved_entries().len(),1);
    }
    #[test] fn native_operations_reserve_everything_both_ways(){
        let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();
        start(&mut j,'1',claims(&[(10,1)],&[20])).unwrap();
        assert!(j.begin(&"n".repeat(64).replace('n',"a"),&"a".repeat(64),&"c".repeat(64),"o1test").is_err());
        let t2=Temp::new();let mut k=Journal::open(&t2.0).unwrap();
        k.begin(&"a".repeat(64),&"a".repeat(64),&"c".repeat(64),"o1test").unwrap();
        assert!(start(&mut k,'2',claims(&[(10,1)],&[20])).is_err());
    }
    #[test] fn settling_out_of_order_releases_only_that_payment(){
        let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();
        start(&mut j,'1',claims(&[(10,1)],&[20])).unwrap();j.cancel_preparing(&"1".repeat(64)).unwrap();
        start(&mut j,'2',claims(&[(11,2)],&[21])).unwrap();
        start(&mut j,'3',claims(&[(10,1)],&[22])).unwrap(); // coin 10 is free again after cancel
        j.cancel_preparing(&"3".repeat(64)).unwrap();
        drop(j);
        let open=Journal::open(&t.0).unwrap().unresolved_entries();
        assert_eq!(open.len(),1);assert_eq!(open[0]["txid"],"2".repeat(64));
    }
    #[test] fn too_many_unsettled_payments_are_refused(){
        let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();
        for i in 0..MAX_UNRESOLVED as u64 {j.begin_claims(&format!("{:064x}",i+1),&format!("{:064x}",i+1),&"c".repeat(64),"o1test",claims(&[(100+i,1)],&[1000+i])).unwrap();}
        assert!(j.begin_claims(&"f".repeat(64),&"f".repeat(64),&"c".repeat(64),"o1test",claims(&[(9999,1)],&[99999])).unwrap_err().contains("Too many"));
    }
    #[test] fn old_single_record_migrates_once_and_crash_after_commit_is_finished(){
        let t=Temp::new();
        let old=json!({"version":1,"state":"preparing","review_hash":"a".repeat(64),"txid":"b".repeat(64),"chain_id":"c".repeat(64),"owner":"o1test"});
        fs::write(t.0.join("pending.json"),serde_json::to_vec(&old).unwrap()).unwrap();
        {let j=Journal::open(&t.0).unwrap();assert_eq!(j.current().unwrap()["claims"]["exclusive"],true);}
        assert!(!t.0.join("pending.json").exists());assert!(t.0.join("pending.migrated.json").exists());
        // Simulate a crash after the ledger commit but before the old file was retired.
        fs::write(t.0.join("pending.json"),serde_json::to_vec(&old).unwrap()).unwrap();
        let j=Journal::open(&t.0).unwrap();assert_eq!(j.entries().len(),1);assert!(!t.0.join("pending.json").exists());
    }
    #[test] fn edited_claims_fail_closed(){
        let t=Temp::new();{let mut j=Journal::open(&t.0).unwrap();start(&mut j,'1',claims(&[(10,1)],&[20])).unwrap();}
        let path=t.0.join("ledger.json");let mut value:Value=serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        value["entries"][0]["claims"]["inputs"]=json!([[10,1],[10,2]]);fs::write(&path,serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(Journal::open(&t.0).is_err());
    }
    #[test] fn unreadable_native_intent_keeps_reserving_everything(){
        let t=Temp::new();let mut j=Journal::open(&t.0).unwrap();
        j.begin(&"a".repeat(64),&"a".repeat(64),&"c".repeat(64),"o1test").unwrap();
        j.authorized_kind(&[9,9,9],"native").unwrap();
        assert_eq!(j.current().unwrap()["claims"]["exclusive"],true);
        assert!(start(&mut j,'2',claims(&[(10,1)],&[20])).is_err());
    }
    #[test] fn trade_intents_always_reserve_everything(){
        let mut bytes=noid_tx::native_assets::trade::wire::TRADE_OWNER_INTENT_MAGIC.to_vec();bytes.extend([0u8;8]);
        assert_eq!(intent_claims(&bytes).unwrap()["exclusive"],true);
    }
}