//! Public-address balance discovery with slot proofs anchored to the mobile node.
//! Slot proof validation adapted from the pinned Paramo1d mobile_wallet.rs (Apache-2.0).
//! No seed or secret is accepted. Discovery completeness is not proven.
use anyhow::{ensure,Context,Result};
use serde::{Deserialize,Serialize};
use serde_json::{json,Value};
use noid_chain::{fri_state::SlotValue,BlockHeader};
use noid_core::Block128;
use noid_poseidon2b::primitives::Address;
use std::{collections::{BTreeMap,BTreeSet},fs::{self,File},io::Write,path::Path};
/// The public Parano1d node: always included, tried after the Parano1d World node and any backups.
pub const PUBLIC_RPC:&str="https://chat.parano1d.org/chain";
/// The Parano1d World read-only node, tried first. None until node.parano1dworld.com is live.
pub const PRIMARY_RPC:Option<&str>=None;
/// Backup node endpoints chosen in Settings → Network, tried after the Parano1d World node and before the public one.
static EXTRA_RPC:std::sync::RwLock<Vec<String>>=std::sync::RwLock::new(Vec::new());
/// Accepts at most three extra https endpoints; anything else is ignored.
pub fn set_extra_endpoints(value:&Value){
    let list:Vec<String>=value.as_array().map(|items|items.iter().filter_map(Value::as_str)
        .filter(|url|url.starts_with("https://")&&url.len()<=200&&*url!=PUBLIC_RPC&&Some(*url)!=PRIMARY_RPC).map(str::to_owned).take(3).collect()).unwrap_or_default();
    if let Ok(mut saved)=EXTRA_RPC.write(){*saved=list;}
}
/// Node endpoints in failover order: the Parano1d World node, the person's backups, then the public node.
/// If none answers, wallet reads fall back to mainnet peers (see `snapshot`); Parano1d mode uses peers only.
pub fn endpoints()->Vec<String>{
    let mut list:Vec<String>=PRIMARY_RPC.map(str::to_owned).into_iter().collect();
    if let Ok(saved)=EXTRA_RPC.read(){list.extend(saved.iter().cloned());}
    list.push(PUBLIC_RPC.to_owned());
    list
}
/// Opens the first endpoint that answers the given read. Results are still checked by the caller.
fn first_answer(method:&str,params:Value)->Result<(paramo1d::rpc::Rpc,Value)>{
    let mut last=None;
    for endpoint in endpoints(){
        match paramo1d::rpc::Rpc::new(&endpoint).and_then(|mut rpc|rpc.call(method,params.clone()).map(|v|(rpc,v))){
            Ok(pair)=>return Ok(pair),
            Err(error)=>last=Some(error),
        }
    }
    Err(last.unwrap_or_else(||anyhow::anyhow!("No node endpoint answered")))
}
/// Prefix of a wallet_balance error caused by chain synchronization itself.
pub const SYNC_FAILURE_PREFIX:&str="Chain sync failed: ";
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Slot {
    slot_index: u32,
    value: u64,
    creation_id: u64,
    owner: String,
    empty: bool,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Proof {
    height: u64,
    block_hash: String,
    state_root: String,
    log_slots: u32,
    slots: Vec<Slot>,
    siblings: Vec<String>,
}
fn verify_proof(header: &BlockHeader, proof: &Proof) -> Result<BTreeMap<u32, SlotValue>> {
    ensure!(header.log_slots <= 32, "Unsupported State depth");
    ensure!(
        proof.height == header.height
            && proof.block_hash == hex::encode(noid_chain::block_header::block_id(header))
            && proof.state_root == hex::encode(header.state_root)
            && proof.log_slots == header.log_slots,
        "State advanced; synchronize and retry"
    );
    ensure!(
        !proof.slots.is_empty()
            && proof.slots.len() <= 128
            && proof
                .slots
                .windows(2)
                .all(|p| p[0].slot_index < p[1].slot_index),
        "Invalid slot proof order"
    );
    let mut values = BTreeMap::new();
    for slot in &proof.slots {
        ensure!(
            u64::from(slot.slot_index) < (1u64 << header.log_slots),
            "Slot outside State"
        );
        let value = if slot.empty {
            ensure!(
                slot.value == 0 && slot.creation_id == 0 && slot.owner.is_empty(),
                "Invalid empty slot"
            );
            SlotValue::EMPTY
        } else {
            let owner = Address::parse(&slot.owner)
                .map_err(|e| anyhow::anyhow!("Invalid slot owner: {e}"))?;
            ensure!(slot.creation_id > 0, "Invalid slot incarnation");
            SlotValue {
                value: Block128(u128::from(slot.value) | (u128::from(slot.creation_id) << 64)),
                owner_hi: Block128(u128::from_le_bytes(owner.0[..16].try_into().unwrap())),
                owner_lo: Block128(u128::from_le_bytes(owner.0[16..].try_into().unwrap())),
            }
        };
        values.insert(slot.slot_index, value);
    }
    let indices = values.keys().copied().collect::<Vec<_>>();
    let leaves = values
        .values()
        .copied()
        .map(noid_chain::exact_state_hash::slot_leaf_hash)
        .collect::<Vec<_>>();
    let siblings = proof
        .siblings
        .iter()
        .map(|s| paramo1d_courier::decode_array::<32>(s))
        .collect::<Result<Vec<_>>>()?;
    let root =
        noid_chain::sparse_merkle::reconstruct_root(&indices, &leaves, &siblings, header.log_slots)
            .map_err(|e| anyhow::anyhow!("Slot proof rejected: {e}"))?;
    ensure!(root == header.state_root, "Slot proof root mismatch");
    Ok(values)
}
fn cached_values(header:&BlockHeader,proofs:&[Proof])->Result<BTreeMap<u32,SlotValue>> {
    ensure!(!proofs.is_empty() && proofs.len()<=513,"No bounded saved wallet proofs");
    let mut values=BTreeMap::new();
    for proof in proofs {
        for (index,value) in verify_proof(header,proof)? {
            ensure!(values.insert(index,value).is_none(),"Repeated saved proof slot");
        }
    }
    Ok(values)
}
fn owner(value: SlotValue) -> Address {
    let mut a = [0u8; 32];
    a[..16].copy_from_slice(&value.owner_hi.0.to_le_bytes());
    a[16..].copy_from_slice(&value.owner_lo.0.to_le_bytes());
    Address(a)
}

pub struct Snapshot {pub header:BlockHeader,pub proof_height:Option<u64>,pub slots:BTreeMap<u32,SlotValue>,pub verified:Value,pub native_state:Value,pub native_state_error:Value,pub owner:Address,pub anchor:BlockHeader}
/// Peers mode: the last verified peer wallet view (coins plus spare empty slots), saved
/// next to the verified chain so offline (Bluetooth) payments can still be planned.
fn save_peer_view(directory:&Path,owner:&str,header:&BlockHeader,values:&BTreeMap<u32,SlotValue>)->Result<()> {
    ensure!(values.len()<=4096+32,"Peer wallet view exceeds the mobile limit");
    let slots:Vec<Value>=values.iter().map(|(i,v)|json!([i,format!("{:032x}",v.value.0),format!("{:032x}",v.owner_hi.0),format!("{:032x}",v.owner_lo.0)])).collect();
    let encoded=serde_json::to_vec(&json!({"version":1,"owner":owner,"height":header.height,
        "block_hash":hex::encode(noid_chain::block_header::block_id(header)),"slots":slots}))?;
    let path=directory.join(format!("peer-wallet-{owner}.json"));
    let temp=path.with_extension("next");
    let mut file=File::create(&temp)?;file.write_all(&encoded)?;file.sync_all()?;
    fs::rename(temp,path)?;File::open(directory)?.sync_all()?;
    Ok(())
}
fn load_peer_view(directory:&Path,owner:&str,headers:&mut File)->Result<(u64,BTreeMap<u32,SlotValue>)> {
    let bytes=paramo1d::artifacts::read_bounded(&directory.join(format!("peer-wallet-{owner}.json")),2*1024*1024)
        .context("No saved peer wallet yet. Connect once in Peers mode before paying offline")?;
    let cache:Value=serde_json::from_slice(&bytes)?;
    ensure!(cache["version"]==1 && cache["owner"]==owner,"Saved wallet identity mismatch");
    let height=cache["height"].as_u64().context("Saved wallet height")?;
    let header=paramo1d::headers::read_header(headers,height)?;
    ensure!(cache["block_hash"].as_str()==Some(hex::encode(noid_chain::block_header::block_id(&header)).as_str()),
        "Saved peer wallet is not on this phone's verified chain; reconnect to refresh");
    let rows=cache["slots"].as_array().context("Saved wallet slots")?;
    ensure!(rows.len()<=4096+32,"Saved wallet exceeds the mobile limit");
    let word=|v:&Value|->Result<Block128>{Ok(Block128(u128::from_str_radix(v.as_str().context("Saved slot")?,16)?))};
    let mut values=BTreeMap::new();
    for row in rows {
        let index=u32::try_from(row[0].as_u64().context("Saved slot index")?)?;
        ensure!(u64::from(index)<(1u64<<header.log_slots),"Saved slot index outside State");
        let value=SlotValue{value:word(&row[1])?,owner_hi:word(&row[2])?,owner_lo:word(&row[3])?};
        let address=Address::parse(owner).map_err(|_|anyhow::anyhow!("Invalid wallet address"))?;
        ensure!(value==SlotValue::EMPTY || self::owner(value)==address,"Saved wallet holds another owner's coin");
        ensure!(values.insert(index,value).is_none(),"Repeated saved slot");
    }
    Ok((height,values))
}
pub fn snapshot(args:&Value,with_outputs:bool)->Result<Snapshot> {
    let requested=args["owner"].as_str().context("Missing wallet address")?;
    let address=Address::parse(requested).map_err(|_|anyhow::anyhow!("Invalid wallet address"))?;
    ensure!(address.to_bech32()==requested,"Noncanonical wallet address");
    let directory=Path::new(args["data_dir"].as_str().context("Missing device node directory")?);
    let artifacts=args["artifacts"].as_str().context("Missing verification parameters")?;
    let paranoid=args["paranoid_mode"].as_bool()==Some(true);
    if args["use_cached"].as_bool()==Some(true) {
        // Offline planning from the last verified wallet data (endpoint proofs, or in
        // Peers mode the last peer wallet view this phone verified and saved).
        let bundle=paramo1d::courier_api::accepted_bundle(directory)?;
        let verified=paramo1d::verify_bundle(Path::new(artifacts),&bundle,paramo1d::MatrixMode::Streaming)?;
        let mut headers=File::open(bundle.join("headers.bin"))?;
        let tip=paramo1d::headers::read_header(&mut headers,verified.height())?;
        ensure!(hex::encode(noid_chain::block_header::block_id(&tip))==verified.block_hash().to_string(),"Saved boundary changed");
        let epoch=noid_chain::consensus::tx_epoch_anchor_height_for_child(tip.height.checked_add(1).context("Height overflow")?);
        let anchor=paramo1d::headers::read_header(&mut headers,epoch)?;
        let (at,values)=if paranoid {
            load_peer_view(directory,requested,&mut headers)?
        } else {
            let bytes=paramo1d::artifacts::read_bounded(&directory.join(format!("wallet-{}.json",address.to_bech32())),8*1024*1024)?;
            let cache:Value=serde_json::from_slice(&bytes)?;
            ensure!(cache["version"]==1 && cache["owner"]==requested,"Saved wallet identity mismatch");
            let proofs:Vec<Proof>=serde_json::from_value(cache["proofs"].clone())?;
            ensure!(!proofs.is_empty() && proofs.len()<=513,"No bounded saved wallet proofs");
            let at=proofs[0].height;
            ensure!(at<=tip.height,"Saved wallet proofs are ahead of this phone's chain");
            let header=paramo1d::headers::read_header(&mut headers,at)?;
            (at,cached_values(&header,&proofs)?)
        };
        ensure!(at<=tip.height && at>=epoch,"Saved wallet data is from another epoch; reconnect to refresh");
        return Ok(Snapshot{header:tip,proof_height:Some(at),slots:values,verified:serde_json::to_value(verified)?,native_state:Value::Null,native_state_error:Value::Null,owner:address,anchor});
    }
    // Endpoint mode: the first node that answers (the Parano1d World node, backups, then the public node).
    // If none answers, fall back to mainnet peers below; the phone verifies either way.
    let endpoint_answer=if paranoid {None} else {first_answer("getSlotsByOwner",json!([requested])).ok()};
    // Payment planning (with_outputs) also uses this path: the peer wallet view holds the
    // owner's coins plus spare empty slots for outputs, each checked against the header.
    if endpoint_answer.is_none() {
        let sync_request=serde_json::to_vec(&json!({"op":"sync_once","artifacts":artifacts,"data_dir":directory}))?;
        let mut sync=paramo1d::courier_api::execute(&sync_request);
        ensure!(sync["ok"]==true,"{}{}",SYNC_FAILURE_PREFIX,sync["error"].as_str().unwrap_or("Device node synchronization failed"));
        let (mut proof_header,mut slots)=paramo1d::peer_wallet_slots(args,address)?;
        let mut height=sync["result"]["verified"]["height"].as_u64().context("Missing verified height")?;
        if proof_header.height>height {
            // A peer answered from a block this phone has not verified yet: verify forward once.
            sync=paramo1d::courier_api::execute(&sync_request);
            ensure!(sync["ok"]==true,"{}{}",SYNC_FAILURE_PREFIX,sync["error"].as_str().unwrap_or("Device node synchronization failed"));
            height=sync["result"]["verified"]["height"].as_u64().context("Missing verified height")?;
            if proof_header.height>height { (proof_header,slots)=paramo1d::peer_wallet_slots(args,address)?; }
        }
        let verified=sync["result"]["verified"].clone();
        let bundle=paramo1d::courier_api::accepted_bundle(directory)?;
        let mut headers=File::open(bundle.join("headers.bin"))?;
        let tip=paramo1d::headers::read_header(&mut headers,height)?;
        ensure!(Some(hex::encode(noid_chain::block_header::block_id(&tip)).as_str())==verified["block_hash"].as_str(),"Accepted node boundary changed; retry");
        ensure!(proof_header.height<=height,"P2P wallet data is ahead of local verification; retry");
        let checked=paramo1d::headers::read_header(&mut headers,proof_header.height)?;
        ensure!(checked==proof_header,"P2P wallet data is not on the verified chain");
        let epoch=noid_chain::consensus::tx_epoch_anchor_height_for_child(height+1);
        ensure!(proof_header.height>=epoch,"P2P wallet data belongs to a previous payment epoch; retry");
        let anchor=paramo1d::headers::read_header(&mut headers,epoch)?;
        let values:BTreeMap<u32,SlotValue>=slots.into_iter()
            .filter(|(_,value)|(with_outputs && *value==SlotValue::EMPTY) || (*value!=SlotValue::EMPTY && owner(*value)==address)).collect();
        if with_outputs { save_peer_view(directory,requested,&proof_header,&values)?; }
        return Ok(Snapshot{header:tip,proof_height:Some(proof_header.height),slots:values,verified,native_state:sync["result"]["native_state"].clone(),native_state_error:sync["result"]["native_state_error"].clone(),owner:address,anchor});
    }
    let (mut rpc,discovered)=endpoint_answer.context("No node endpoint answered")?;
    let discovered:Vec<Slot>=serde_json::from_value(discovered)?;
    ensure!(discovered.len()<=4096,"Wallet discovery exceeds the mobile limit");
    let mut indices=BTreeSet::new();
    for slot in &discovered {
        ensure!(!slot.empty && slot.owner==requested && indices.insert(slot.slot_index),"Invalid or repeated owner discovery slot");
    }
    if with_outputs {
        let hints:Vec<u32>=serde_json::from_value(rpc.call("getSlotHints",json!([8]))?)?;
        ensure!(hints.len()<=8,"Too many output hints");indices.extend(hints);
    }
    let indices:Vec<_>=indices.into_iter().collect();
    let mut proofs:Vec<Proof>=Vec::new();
    for chunk in indices.chunks(8) {
        let proof:Proof=serde_json::from_value(rpc.call("getSlotProof",json!([chunk]))?)?;
        ensure!(proof.slots.iter().map(|s|s.slot_index).collect::<Vec<_>>()==chunk,"Proof substituted requested slot indices");
        if let Some(first)=proofs.first() {
            ensure!(proof.height==first.height && proof.block_hash==first.block_hash && proof.state_root==first.state_root,"State changed during balance discovery; retry");
        }
        proofs.push(proof);
    }
    let sync=paramo1d::courier_api::execute(&serde_json::to_vec(&json!({"op":"sync_once","artifacts":artifacts,"data_dir":directory}))?);
    // Stable prefix: the app must not repeat a failed chain sync as a
    // "balance only" fallback (see App/NodeRefresh.swift SYNC_FAILURE_PREFIX).
    ensure!(sync["ok"]==true,"{}{}",SYNC_FAILURE_PREFIX,sync["error"].as_str().unwrap_or("Device node synchronization failed"));
    let verified=&sync["result"]["verified"];
    let height=verified["height"].as_u64().context("Missing verified height")?;
    let bundle=paramo1d::courier_api::accepted_bundle(directory)?;
    let mut headers=File::open(bundle.join("headers.bin"))?;
    let tip=paramo1d::headers::read_header(&mut headers,height)?;
    ensure!(Some(hex::encode(noid_chain::block_header::block_id(&tip)).as_str())==verified["block_hash"].as_str(),"Accepted node boundary changed; retry");
    let proof_height=proofs.first().map(|p|p.height);
    let mut values=BTreeMap::new();
    if let Some(at)=proof_height {
        ensure!(at<=height,"Balance proof is ahead of local verification; retry");
        let header=paramo1d::headers::read_header(&mut headers,at)?;
        for proof in &proofs {
            values.extend(verify_proof(&header,proof)?);
        }
    }
    // Every discovery entry must still resolve to a live coin owned by this address.
    for slot in discovered {
        let checked=values.get(&slot.slot_index).context("Missing discovered coin proof")?;
        ensure!(*checked!=SlotValue::EMPTY && owner(*checked)==address,"Discovered coin changed owner; retry");
    }
    let epoch=noid_chain::consensus::tx_epoch_anchor_height_for_child(height+1);
    if let Some(at)=proof_height {
        ensure!(at>=epoch,"Wallet proof belongs to a previous payment epoch; refresh and retry");
    }
    let anchor=paramo1d::headers::read_header(&mut headers,epoch)?;
    if with_outputs && !proofs.is_empty() {
        let encoded=serde_json::to_vec(&json!({"version":1,"owner":requested,"proofs":proofs}))?;
        ensure!(encoded.len()<=8*1024*1024,"Saved wallet proofs exceed limit");
        let path=directory.join(format!("wallet-{}.json",address.to_bech32()));
        let temp=path.with_extension("next");
        let mut file=File::create(&temp)?;file.write_all(&encoded)?;file.sync_all()?;
        fs::rename(temp,path)?;File::open(directory)?.sync_all()?;
    }
    Ok(Snapshot{header:tip,proof_height,slots:values,verified:verified.clone(),native_state:sync["result"]["native_state"].clone(),native_state_error:sync["result"]["native_state_error"].clone(),owner:address,anchor})
}
pub fn run(args:&Value)->Result<Value> {
    // Paranoid mode reads the balance over P2P; payment planning still saves endpoint proofs.
    let snapshot=snapshot(args,args["paranoid_mode"].as_bool()!=Some(true))?;
    let total=snapshot.slots.values().filter(|v| owner(**v)==snapshot.owner && noid_tx::native_assets::native_sequence(v.creation_id()).is_err()).try_fold(0u64,|n,v|n.checked_add(v.amount())).context("Balance overflow")?;
    Ok(json!({"owner":snapshot.owner.to_bech32(),"amount_micronoid":total.to_string(),"balance_height":snapshot.proof_height,"verified":snapshot.verified,"native_state":snapshot.native_state,"native_state_error":snapshot.native_state_error,"discovered_slots":snapshot.slots.len(),"discovery_complete":false,"proofs_verified":snapshot.proof_height.is_some()}))
}

#[cfg(test)] mod tests {
 use super::*;
 fn fixture()->(BlockHeader,Proof) {
    let mut header=noid_chain::consensus::genesis::genesis_header();header.log_slots=1;
    let leaves=vec![noid_chain::exact_state_hash::slot_leaf_hash(SlotValue::EMPTY);2];
    header.state_root=noid_chain::sparse_merkle::reconstruct_root(&[0,1],&leaves,&[],1).unwrap();
    let proof=Proof{height:header.height,block_hash:hex::encode(noid_chain::block_header::block_id(&header)),state_root:hex::encode(header.state_root),log_slots:1,slots:vec![Slot{slot_index:0,value:0,creation_id:0,owner:String::new(),empty:true},Slot{slot_index:1,value:0,creation_id:0,owner:String::new(),empty:true}],siblings:vec![]};
    (header,proof)
 }
 #[test] fn cached_proofs_reject_duplicate_pages_and_mixed_boundaries(){let(h,p)=fixture();assert!(cached_values(&h,&[p.clone()]).is_ok());assert!(cached_values(&h,&[p.clone(),p.clone()]).is_err());let mut altered=p.clone();altered.height+=1;assert!(cached_values(&h,&[altered]).is_err());assert!(cached_values(&h,&[]).is_err());}
 #[test] fn authenticates_exact_state_leaves(){let(h,p)=fixture();assert_eq!(verify_proof(&h,&p).unwrap().len(),2);}
 #[test] fn rejects_state_hash_height_and_slot_substitution(){let(h,mut p)=fixture();p.height+=1;assert!(verify_proof(&h,&p).is_err());let(_,mut p)=fixture();p.block_hash="00".repeat(32);assert!(verify_proof(&h,&p).is_err());let(_,mut p)=fixture();p.slots[0].value=1;assert!(verify_proof(&h,&p).is_err());}
 #[test] fn sync_failure_prefix_is_stable_for_the_app(){assert_eq!(SYNC_FAILURE_PREFIX,"Chain sync failed: ");}
 #[test] fn rejects_duplicate_indices_and_false_state_roots(){let(h,mut p)=fixture();p.slots[1].slot_index=0;assert!(verify_proof(&h,&p).is_err());let(_,mut p)=fixture();p.state_root="ff".repeat(32);assert!(verify_proof(&h,&p).is_err());}
}
