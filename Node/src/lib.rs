//! Minimal on-device node bridge. No secrets and no web-accessible dispatcher.
mod balance;
mod payment_plan;
mod payment_epoch;
mod payment_expiry;
mod market_history;
mod native_planning_snapshot;
mod native_port;
#[path="../../Native/src/payment_journal.rs"]
mod payment_journal;
use std::ffi::{c_char,CString};
use serde_json::{json,Value};
fn checked_parent(result:&Value,expected:Option<&str>)->Result<String,String> {
    if result["ok"]!=true {return Err("Device node synchronization did not verify a parent".into());}
    let parent=result["result"]["verified"]["block_hash"].as_str().ok_or("Verified parent is missing")?;
    if parent.len()!=64 || !parent.bytes().all(|b|b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {return Err("Invalid verified parent".into());}
    if expected.is_some_and(|hash|hash!=parent){return Err("Reviewed parent is not the device's verified tip. Refresh markets and review again".into());}
    Ok(parent.to_owned())
}
fn receipt_request(mut request:Value)->Result<Value,String> {
    let id=request["expected_txid"].as_str().ok_or("Expected transaction ID is required")?;
    if id.len()!=64 || !id.bytes().all(|b|b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {return Err("Invalid transaction ID".into());}
    let receipt=request["receipt_hex"].as_str().ok_or("Receipt is required")?;
    if receipt.is_empty() || receipt.len()>262144 || receipt.len()%2!=0 || !receipt.bytes().all(|b|b.is_ascii_hexdigit()) {return Err("Invalid receipt encoding".into());}
    let directory=request["data_dir"].as_str().ok_or("Verified node directory is required")?;
    let bundle=paramo1d::courier_api::accepted_bundle(std::path::Path::new(directory)).map_err(|_|"Synchronize the device node before verifying receipts")?;
    request["bundle"]=json!(bundle);
    // Check only the already accepted local boundary. Never start network sync
    // implicitly from a receipt supplied by an explorer or another person.
    request.as_object_mut().unwrap().remove("data_dir");
    Ok(request)
}
fn execute(bytes:&[u8])->Value {
    let result=(||->Result<Value,String>{
        let mut request:Value=serde_json::from_slice(bytes).map_err(|_|"Invalid node request")?;
        match request["op"].as_str() {
            Some("node_status"|"node_active"|"node_trim_memory"|"sync_once"|"native_holdings"|"native_planning_probe"|"native_prepare"|"native_listings"|"native_collections"|"native_markets"|"receipt_check"|"wallet_balance"|"transaction_status"|"transaction_evidence"|"payment_plan"|"payment_epoch_check"|"broadcast_send"|"native_submit"|"settle_payment"|"verify_parent"|"expire_payment"|"market_history"|"chain_identity")=>{},
            _=>return Err("Unsupported node operation".into())
        }
        // Optional extra node endpoints from Settings → Network (failover only).
        balance::set_extra_endpoints(&request["rpc_endpoints_extra"]);
        if let Some(object)=request.as_object_mut(){object.remove("rpc_endpoints_extra");}
        if request["op"]=="chain_identity" {
            return Ok(json!({"ok":true,"result":{
                "chain_id":hex::encode(noid_chain::state::native_assets::native_chain_id()),
                "genesis_header_hex":hex::encode(noid_chain::consensus::genesis::genesis_header().to_bytes())
            }}));
        }
        if request["op"]=="market_history" {
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            return market_history::run(&request).map(|result|json!({"ok":true,"result":result})).map_err(|e|e.to_string());
        }
        if request["op"]=="expire_payment" {
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            return payment_expiry::run(&request).map(|result|json!({"ok":true,"result":result})).map_err(|e|e.to_string());
        }
        if request["op"]=="verify_parent" {
            let chain=hex::encode(noid_chain::state::native_assets::native_chain_id());
            if request["expected_chain"].as_str()!=Some(chain.as_str()){return Err("Requested chain does not match the device's pinned chain".into());}
            let expected=match request.get("expected_parent_hash") {
                None=>None,
                Some(value)=>Some(value.as_str().ok_or("Invalid expected parent")?.to_owned())
            };
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            request["op"]=json!("sync_once");
            let result=paramo1d::courier_api::execute(&serde_json::to_vec(&request).map_err(|_|"Invalid state request")?);
            let parent=checked_parent(&result,expected.as_deref())?;
            return Ok(json!({"ok":true,"result":{"verified_parent_hash":parent,"chain_id":chain}}));
        }
        if request["op"]=="settle_payment" {
            let directory=request["journal_directory"].as_str().ok_or("Missing payment storage")?;
            let mut journal=payment_journal::Journal::open(std::path::Path::new(directory))?;
            let pending=journal.entry(request["expected_txid"].as_str().ok_or("Missing payment identity")?).ok_or("No pending payment")?;
            let expected=pending["txid"].as_str().ok_or("Invalid pending identity")?.to_owned();
            if request["expected_txid"].as_str()!=Some(expected.as_str()){return Err("Receipt differs from pending payment".into());}
            request["op"]=json!("receipt_check");
            request=receipt_request(request)?;
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            let result=paramo1d::courier_api::execute(&serde_json::to_vec(&request).map_err(|_|"Invalid settlement request")?);
            if result["ok"]!=true || result["result"]["verified"]!=true || result["result"]["finalized"]!=true || result["result"]["txid"]!=expected {return Err("Payment is not independently verified as finalized; reservation retained".into());}
            journal.mark_finalized(&expected,result["result"]["height"].as_u64().ok_or("Missing settlement height")?)?;
            return Ok(result);
        }
        if request["op"]=="payment_plan" {
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            // Coins and output slots held by unsettled payments are never planned again.
            // Read from the ledger (claims are checked against each entry's own bytes),
            // never from caller-supplied lists; the lock is released before network work.
            if let Some(directory)=request["journal_directory"].as_str() {
                let journal=payment_journal::Journal::open(std::path::Path::new(directory))?;
                let open=journal.unresolved_entries();drop(journal);
                if open.iter().any(|e|e["claims"]["exclusive"]==true) {
                    return Err("A transaction that reserves your whole wallet is still settling. Try again once it confirms".into());
                }
                let packets:Vec<Value>=open.iter().map(|e|json!({"epoch_anchor":e["claims"]["epoch_anchor"],
                    "inputs":e["claims"]["inputs"].as_array().map(|a|a.iter().map(|i|json!({"slot_index":i[0],"creation_id":i[1]})).collect::<Vec<_>>()).unwrap_or_default(),
                    "outputs":e["claims"]["outputs"]})).collect();
                request["reservations"]=json!(packets);
            } else {
                request.as_object_mut().map(|o|o.remove("reservations"));
            }
            if request["use_cached"]!=true {
                if let Some(snapshot)=mempool_snapshot(&request) {request["mempool"]=snapshot;}
            } else {request.as_object_mut().map(|o|o.remove("mempool"));}
            return payment_plan::run(&request).map(|result|json!({"ok":true,"result":result})).map_err(|e|e.to_string());
        }
        if request["op"]=="native_planning_probe" {
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            let parent=request["expected_parent_hash"].as_str().ok_or("Expected verified parent is required")?;
            let response=paramo1d::courier_api::execute(&serde_json::to_vec(&request).map_err(|_|"Invalid native probe")?);
            if response["ok"]!=true {return Ok(response);}
            native_planning_snapshot::Snapshot::parse(&response["result"],parent)?;
            return Ok(response);
        }
        if request["op"]=="native_prepare" {
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            let directory=request["journal_directory"].as_str().ok_or("Missing protected wallet storage")?;
            let journal=payment_journal::Journal::open(std::path::Path::new(directory))?;
            // Several transactions may be pending; the planner never touches a slot an
            // unsettled one uses (claims are checked against each entry's own bytes).
            let open=journal.unresolved_entries();drop(journal);
            if open.iter().any(|e|e["claims"]["exclusive"]==true) {
                return Err("A transaction that reserves your whole wallet is still settling. Try again once it confirms".into());
            }
            if open.len()>=payment_journal::MAX_UNRESOLVED {return Err("Twenty transactions are pending. Wait for some to confirm".into());}
            let mut reserved=std::collections::HashSet::new();
            for entry in &open {
                for item in entry["claims"]["inputs"].as_array().into_iter().flatten() {if let Some(slot)=item[0].as_u64(){reserved.insert(slot as u32);}}
                for item in entry["claims"]["outputs"].as_array().into_iter().flatten() {if let Some(slot)=item.as_u64(){reserved.insert(slot as u32);}}
            }
            // Peers' pending transactions: their slots are avoided and their fees set the floor.
            let mut floor=0;
            if let Some(snapshot)=mempool_snapshot(&request) {
                for item in snapshot["inputs"].as_array().into_iter().flatten() {if let Some(slot)=item[0].as_u64(){reserved.insert(slot as u32);}}
                for item in snapshot["outputs"].as_array().into_iter().flatten() {if let Some(slot)=item.as_u64(){reserved.insert(slot as u32);}}
                floor=snapshot["floor"].as_u64().unwrap_or(0);
            }
            let plan=native_port::prepare_reserving(&request,reserved,floor)?;
            return Ok(json!({"ok":true,"result":plan}));
        }
        if request["op"]=="native_submit" {
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            let directory=request["journal_directory"].as_str().ok_or("Missing protected payment storage")?;
            let journal=payment_journal::Journal::open(std::path::Path::new(directory))?;
            let saved=journal.entry(request["expected_txid"].as_str().ok_or("Missing native transaction identity")?).ok_or("No saved native authorization")?;
            let id=saved["txid"].as_str().ok_or("Missing saved transaction identity")?;
            if saved["state"]!="authorized" || saved["operation_kind"]!="native" || request["expected_txid"].as_str()!=Some(id) {
                return Err("Saved native authorization does not match this submission".into());
            }
            let chain=noid_chain::state::native_assets::native_chain_id();
            if saved["chain_id"]!=hex::encode(chain) {return Err("Saved authorization belongs to another chain".into());}
            let signed=saved["intent_hex"].as_str().ok_or("Missing saved signed intent")?;
            let identity=payment_expiry::native_identity(signed,chain).map_err(|e|e.to_string())?;
            if identity.txid!=id || saved["owner"]!=identity.owner {return Err("Signed native intent differs from the payment journal".into());}
            // Release the journal lock before network I/O. It is immutable while
            // authorized except for independently verified settlement or expiry.
            let intent=signed.to_owned();let id=id.to_owned();drop(journal);
            // Peers mode: straight to mainnet peers, never an endpoint.
            if request["paranoid_mode"].as_bool()==Some(true) {
                let path=request["artifacts"].as_str().ok_or("Missing verification parameters")?;
                let bytes=hex::decode(&intent).map_err(|e|e.to_string())?;
                let peers=paramo1d::peer_broadcast(std::path::Path::new(path),bytes,&id).map_err(|e|e.to_string())?;
                return Ok(json!({"ok":true,"result":{"submitted":true,"txid":id,"confirmed":false,"via":"peers","p2p":peers}}));
            }
            // Identical signed bytes to each endpoint in turn, then directly to peers.
            let mut last=String::from("No node endpoint answered");
            for endpoint in balance::endpoints() {
                let mut rpc=match paramo1d::rpc::Rpc::new(&endpoint){Ok(rpc)=>rpc,Err(error)=>{last=error.to_string();continue;}};
                match rpc.call("submitTxIntent",json!([intent])) {
                    Ok(response)=>{
                        if response.as_str()!=Some(id.as_str()) {return Err("Node returned a different native transaction ID; saved authorization retained".into());}
                        return Ok(json!({"ok":true,"result":{"submitted":true,"txid":id,"confirmed":false,"via":endpoint}}));
                    }
                    Err(error) if error.to_string().contains("BadEpochAnchor")=>{
                        // An included operation can outlive its admission epoch.
                        // The lookup is only a relay hint, never verified settlement.
                        let known=rpc.call("getTx",json!([id])).map_err(|e|e.to_string())?;
                        if known.is_null(){return Err(error.to_string());}
                        return Ok(json!({"ok":true,"result":{"submitted":true,"txid":id,"confirmed":false,"already_known":true}}));
                    }
                    Err(error)=>last=error.to_string(),
                }
            }
            if let Some(path)=request["artifacts"].as_str() {
                let bytes=hex::decode(&intent).map_err(|e|e.to_string())?;
                if let Ok(peers)=paramo1d::peer_broadcast(std::path::Path::new(path),bytes,&id) {
                    return Ok(json!({"ok":true,"result":{"submitted":true,"txid":id,"confirmed":false,"via":"peers","p2p":peers}}));
                }
            }
            return Err(last);
        }
        if request["op"]=="payment_epoch_check" {
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            return payment_epoch::run(&request).map(|result|json!({"ok":true,"result":result})).map_err(|e|e.to_string());
        }
        if request["op"]=="wallet_balance" {
            paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
            return balance::run(&request).map(|result|json!({"ok":true,"result":result})).map_err(|e|e.to_string());
        }
        if request["op"]=="transaction_evidence" {
            let location=request["location"].as_object().ok_or("Missing transaction location")?;
            let txid=request["txid"].as_str().ok_or("Missing transaction ID")?;
            if txid.len()!=64 || !txid.bytes().all(|v|v.is_ascii_hexdigit()) || location.get("tx_hash").and_then(Value::as_str)!=Some(txid) {return Err("Transaction lookup identity mismatch".into());}
            let block=request["block_hex"].as_str().ok_or("Missing block body")?;
            if block.len()>4*1024*1024 || block.len()%2!=0 || !block.bytes().all(|v|v.is_ascii_hexdigit()){return Err("Invalid supplied block".into());}
            request["op"]=json!("transaction_status");
        } else if request["op"]=="transaction_status" || request["op"]=="broadcast_send" {request["rpc"]=json!(balance::PUBLIC_RPC);request["rpc_endpoints"]=json!(balance::endpoints());}
        if request["op"]=="receipt_check" {request=receipt_request(request)?;}
        paramo1d::ensure_verification_hardware().map_err(|e|e.to_string())?;
        Ok(paramo1d::courier_api::execute(&serde_json::to_vec(&request).map_err(|_|"Invalid request")?))
    })();
    result.unwrap_or_else(|error|json!({"ok":false,"error":error}))
}
/// Node calls run off Swift's background threads, whose ~512 KB stacks deep proof
/// verification can overflow (a stack overflow ends the app; it cannot be caught).
/// Network work runs on one long-lived 64 MB-stack thread, so the P2P connection
/// (kept per thread) stays open between syncs instead of reconnecting each time.
/// Local State reads and status checks get their own short-lived 64 MB thread so they
/// never wait behind a long sync.
const NODE_STACK:usize=64*1024*1024;
type NodeJob=(Vec<u8>,std::sync::mpsc::Sender<Value>);
fn failed()->Value {json!({"ok":false,"error":"Node operation failed"})}
fn guarded(request:&[u8])->Value {std::panic::catch_unwind(||execute(request)).unwrap_or_else(|_|failed())}
fn network_worker()->Option<&'static std::sync::Mutex<std::sync::mpsc::Sender<NodeJob>>> {
    static WORKER:std::sync::OnceLock<Option<std::sync::Mutex<std::sync::mpsc::Sender<NodeJob>>>>=std::sync::OnceLock::new();
    WORKER.get_or_init(||{
        let (sender,jobs)=std::sync::mpsc::channel::<NodeJob>();
        std::thread::Builder::new().name("paranoid-node-network".into()).stack_size(NODE_STACK)
            .spawn(move||{for (request,reply) in jobs {let _=reply.send(guarded(&request));}})
            .ok().map(|_|std::sync::Mutex::new(sender))
    }).as_ref()
}
/// Best effort: peers' pending transactions. Planning still works without it (as before).
fn mempool_snapshot(request:&Value)->Option<Value> {
    let path=request["artifacts"].as_str()?;
    let snapshot=paramo1d::peer_mempool_snapshot(std::path::Path::new(path)).ok()?;
    (snapshot["peers"].as_u64()?>0).then_some(snapshot)
}
fn local_operation(request:&[u8])->bool {
    let op=serde_json::from_slice::<Value>(request).ok().and_then(|v|v["op"].as_str().map(str::to_owned));
    matches!(op.as_deref(),Some("node_status"|"node_active"|"node_trim_memory"|"native_holdings"|"native_listings"
        |"native_collections"|"native_markets"|"chain_identity"))
}
fn run_on_node_thread(request:Vec<u8>)->Value {
    if !local_operation(&request) {
        if let Some(worker)=network_worker() {
            let (reply,answer)=std::sync::mpsc::channel();
            let sent=worker.lock().map(|sender|sender.send((request.clone(),reply)).is_ok()).unwrap_or(false);
            if sent {return answer.recv().unwrap_or_else(|_|failed());}
        }
    }
    std::thread::Builder::new().name("paranoid-node".into()).stack_size(NODE_STACK)
        .spawn(move||guarded(&request)).ok().and_then(|worker|worker.join().ok()).unwrap_or_else(failed)
}
/// Input must reference length readable bytes. Call sync off the UI thread.
#[no_mangle]
pub unsafe extern "C" fn paranoid_node_call(input:*const u8,length:usize)->*mut c_char {
    let value=if input.is_null()||length>4*1024*1024 { json!({"ok":false,"error":"Invalid node request size"}) }
    else { run_on_node_thread(unsafe{std::slice::from_raw_parts(input,length)}.to_vec()) };
    CString::new(value.to_string()).unwrap().into_raw()
}
/// Free exactly once, only pointers returned by paranoid_node_call.
#[no_mangle]
pub unsafe extern "C" fn paranoid_node_free(value:*mut c_char){if !value.is_null(){drop(unsafe{CString::from_raw(value)});}}
#[cfg(test)]
mod tests { use super::*;
    #[test] fn freshly_verified_parent_is_explicit_and_fail_closed() {
        let hash="a".repeat(64);
        let result=json!({"ok":true,"result":{"verified":{"block_hash":hash}}});
        assert_eq!(checked_parent(&result,None).unwrap(),hash);
        assert!(checked_parent(&result,Some(&hash)).is_ok());
        assert!(checked_parent(&result,Some(&"b".repeat(64))).is_err());
        assert!(checked_parent(&json!({"ok":false,"result":{"verified":{"block_hash":hash}}}),None).is_err());
        assert!(checked_parent(&json!({"ok":true,"result":{"verified":{"block_hash":"bad"}}}),None).is_err());
        assert!(checked_parent(&json!({"ok":true,"result":{}}),None).is_err());
    }
    #[test] fn receipt_requires_expected_identity() {
        assert!(receipt_request(json!({"receipt_hex":"00"})).unwrap_err().contains("transaction ID"));
        assert!(receipt_request(json!({"expected_txid":"a".repeat(64),"receipt_hex":"0"})).is_err());
        assert!(receipt_request(json!({"expected_txid":"a".repeat(64),"receipt_hex":"zz"})).is_err());
        assert!(receipt_request(json!({"expected_txid":"a".repeat(64),"receipt_hex":"00".repeat(131073)})).is_err());
    }
    #[test] fn receipt_uses_only_accepted_local_bundle() {
        let dir=std::env::temp_dir().join(format!("paranoid-receipt-{}",std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("accepted.json"),br#"{"bundle":"candidate-test"}"#).unwrap();
        let request=receipt_request(json!({"expected_txid":"a".repeat(64),"receipt_hex":"00","data_dir":dir,"bundle":"untrusted"})).unwrap();
        assert_eq!(request["bundle"],json!(dir.join("candidate-test")));
        assert!(request.get("data_dir").is_none());
        std::fs::write(dir.join("accepted.json"),br#"{"bundle":"candidate-../../outside"}"#).unwrap();
        assert!(receipt_request(json!({"expected_txid":"a".repeat(64),"receipt_hex":"00","data_dir":dir})).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test] fn rejects_wallet_secret_operations(){assert_eq!(execute(br#"{"op":"profile","seed_hex":"00"}"#)["ok"],false);}
    #[test] fn rejects_arbitrary_operations(){assert_eq!(execute(br#"{"op":"walletSend"}"#)["ok"],false);}
    #[test] fn returns_only_the_pinned_chain_identity(){
        let result=execute(br#"{"op":"chain_identity"}"#);
        assert_eq!(result["ok"],true);
        assert_eq!(result["result"]["chain_id"],hex::encode(noid_chain::state::native_assets::native_chain_id()));
        assert_eq!(result["result"]["genesis_header_hex"],hex::encode(noid_chain::consensus::genesis::genesis_header().to_bytes()));
    }
    #[test] fn rejects_other_chain_before_market_state_network_access(){let result=execute(&serde_json::to_vec(&json!({"op":"verify_parent","expected_chain":"0".repeat(64),"expected_parent_hash":"1".repeat(64)})).unwrap());assert_eq!(result["ok"],false);assert!(result["error"].as_str().unwrap().contains("pinned chain"));}
    #[test] fn mobile_derivation_matches_wallet_core() {
        let secret=paramo1d::courier_api::spend_secret(&[7;32],0);
        assert_eq!(noid_poseidon2b::primitives::derive_address(&secret).to_bech32(),"o1lhhsuqy5d35c3zarhnuj7kpywrke5wwsr8ukc6x8y4dvhe38vs2qzg2759");
    }
}
#[cfg(test)]
mod node_thread_tests {
    use super::*;
    #[test] fn network_calls_reuse_one_thread_and_local_calls_do_not_wait() {
        // Unsupported operations still return an error (no crash) through both routes.
        let network=run_on_node_thread(br#"{"op":"nope"}"#.to_vec());
        assert_eq!(network["ok"],false);
        assert!(local_operation(br#"{"op":"native_holdings"}"#));
        assert!(!local_operation(br#"{"op":"sync_once"}"#));
        let first=network_worker().map(|w| w as *const _);
        let _=run_on_node_thread(br#"{"op":"also_nope"}"#.to_vec());
        assert_eq!(first,network_worker().map(|w| w as *const _));
        assert_eq!(run_on_node_thread(b"not json".to_vec())["ok"],false);
    }
}
