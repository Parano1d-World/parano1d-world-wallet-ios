//! Pinned desktop native planner, adapted to one accepted mobile State boundary.
//! No secret enters this module. A returned plan still requires SDK review and
//! an exact owner signature. Trade is disabled until pending-policy projection
//! is available on the phone.
#![allow(dead_code)]
mod native_types;
mod client_types;
mod wallet_ops;
mod wallet_submit;
mod planner;

mod types {
    #[derive(Clone)]
    pub struct WalletUtxoInfo {
        pub slot_index: u32,
        pub value_micronoid: u64,
        pub creation_id: u64,
        pub value_noid: f64,
        pub address: String,
        pub key_index: u32,
        pub confirmed_height: u64,
        pub reserved: bool,
    }
}

use client_types::{NativeClientIntentKind,NativeClientPlan};
use native_types::NativeWalletRequest;
use noid_chain::{block_id,storage::MdbxChainContext};
use noid_poseidon2b::primitives::Address;
use noid_tx::native_assets::{native_sequence,trade::wire::TradeOwnerIntent};
use serde_json::Value;
use std::{collections::HashSet,path::Path};
use wallet_ops::WalletNativeIntent;

fn checked_envelope(request:&Value)->Result<(),String> {
    let object=request.as_object().ok_or("Invalid native planning envelope")?;
    const FIELDS:[&str;8]=["op","owner","account_index","expected_parent_hash","request","journal_directory","artifacts","data_dir"];
    if object.keys().any(|key|!FIELDS.contains(&key.as_str())) {
        return Err("Unexpected native planning field".into());
    }
    if request["op"]!="native_prepare" {return Err("Invalid native planning operation".into())}
    Ok(())
}

fn budget(artifacts:&Path)->Result<noid_chain::mempool::BlockSelectionBudget,String> {
    use noid_recursive::acceptance::history_step::v2::capacity_banked::Class;
    let runtime=paramo1d::artifacts::Runtime::load(artifacts,paramo1d::MatrixMode::Streaming)
        .map_err(|e|format!("Native verification parameters: {e}"))?;
    let config=runtime.current.bank().config().class(Class::Native);
    let financial=config.native_financial_config().map(|financial| {
        let trade=config.native_sequential_config();
        noid_chain::mempool::NativeFinancialBudget {
            actions:financial.action_capacity,
            definitions:financial.kernel.definition_capacity,
            markets:trade.map_or(0,|trade|trade.markets),
            policies:trade.map_or(0,|trade|trade.policies),
            funding:trade.map_or(0,|trade|trade.funding),
            owner_operations:financial.phase != noid_recursive::acceptance::trace::native_assets::financial_kernel::FinancialKernelPhase::Settlement,
        }
    });
    Ok(noid_chain::mempool::BlockSelectionBudget {
        pages:config.pages(), live_inputs:config.max_live_inputs(),
        contract_calls:config.contract_slots(),
        native_headers:config.native_header_capacity().unwrap_or(0),
        native_records:config.native_action_capacity().unwrap_or(0),
        owner_authorizations:config.pages(), financial,
    })
}

fn reserve_system_page(limit:&mut noid_chain::mempool::BlockSelectionBudget,next_height:u64) {
    if noid_chain::consensus::development_allocation::development_payout_due_at_height(next_height) {
        limit.pages=limit.pages.saturating_sub(1);
    }
}

fn export(prepared:planner::Prepared)->Result<NativeClientPlan,String> {
    let claims=prepared.proof.checked_claims()?;
    let context=&prepared.proof.context;
    let height=context.candidate_height()?;
    let (kind,bytes)=match &prepared.proof.intent {
        WalletNativeIntent::Operation(intent)=>(NativeClientIntentKind::Operation,intent.to_bytes().map_err(|e|e.to_string())?),
        WalletNativeIntent::Trade(intent)=>(NativeClientIntentKind::Trade,TradeOwnerIntent{intent:intent.clone(),authorization_bytes:Vec::new()}.to_bytes().map_err(|e|e.to_string())?),
    };
    let request=serde_json::to_vec(&prepared.review.request).map_err(|e|e.to_string())?;
    let mut hasher=blake3::Hasher::new();
    hasher.update(b"NOIDNativeClientPlan1");
    hasher.update(&context.parent.to_bytes());
    hasher.update(&context.owner.0);
    hasher.update(&context.epoch_anchor);
    hasher.update(&(request.len() as u32).to_le_bytes());
    hasher.update(&request);
    hasher.update(&bytes);
    Ok(NativeClientPlan {
        schema_version:1, plan_id:hasher.finalize().to_hex().to_string(),
        intent_id:hex::encode(claims.txid),owner:context.owner.to_bech32(),
        candidate_height:height,parent_header_hex:hex::encode(context.parent.to_bytes()),
        chain_id:hex::encode(noid_chain::state::native_assets::native_chain_id()),
        epoch_anchor:hex::encode(context.epoch_anchor),
        owner_authorization_version:noid_chain::consensus::params::owner_authorization_version(height) as u8,
        intent_kind:kind,unsigned_intent_hex:hex::encode(bytes),review:prepared.review.into(),
    })
}

pub(crate) fn prepare(request:&Value)->Result<Value,String> {prepare_reserving(request,HashSet::new(),0)}
/// Plans around slots held by unsettled transactions in this wallet's ledger.
/// `floor` is the peers' estimated relay fee floor (0 = unknown, consensus fee only).
pub(crate) fn prepare_reserving(request:&Value,reserved:HashSet<u32>,floor:u64)->Result<Value,String> {
    checked_envelope(request)?;
    let encoded=serde_json::to_vec(&request["request"]).map_err(|_|"Invalid native request")?;
    if encoded.len()>32*1024 {return Err("Native request exceeds 32 KiB".into())}
    let key_index=request["account_index"].as_u64().ok_or("Missing account index")?;
    if key_index>100_000 {return Err("Invalid account index".into())}
    let key_index=key_index as u32;
    let owner_text=request["owner"].as_str().ok_or("Missing native owner")?;
    let owner=Address::parse(owner_text).map_err(|e|format!("Invalid owner: {e}"))?;
    if owner.to_bech32()!=owner_text {return Err("Noncanonical native owner".into())}
    let expected=request["expected_parent_hash"].as_str().ok_or("Missing expected parent")?;
    if expected.len()!=64 || !expected.bytes().all(|b|b.is_ascii_digit()||(b'a'..=b'f').contains(&b)) {
        return Err("Invalid expected parent".into());
    }
    let action:NativeWalletRequest=serde_json::from_value(request["request"].clone()).map_err(|e|format!("Invalid native action: {e}"))?;
    if matches!(action,NativeWalletRequest::Trade{..}) {return Err("Trade requires a phone pending-policy projection".into())}
    let data=Path::new(request["data_dir"].as_str().ok_or("Missing verified node directory")?);
    let artifacts=Path::new(request["artifacts"].as_str().ok_or("Missing pinned verifier parameters")?);
    let directory=data.join("NativeState");
    if !directory.exists(){return Err("Native State is not installed".into())}
    let chain=MdbxChainContext::open_or_create(&directory).map_err(|e|format!("Open native State: {e}"))?;
    if hex::encode(chain.tip_hash())!=expected {return Err("Native State is behind the verified parent".into())}
    let bundle=paramo1d::courier_api::accepted_bundle(data).map_err(|e|e.to_string())?;
    let verified=paramo1d::verify_bundle(artifacts,&bundle,paramo1d::MatrixMode::Streaming).map_err(|e|e.to_string())?;
    if verified.height()!=chain.tip_height() || verified.block_hash()!=expected ||
        verified.state_root()!=hex::encode(chain.tip_header().state_root) {
        return Err("Installed State is not at the accepted verifier boundary".into());
    }
    let parent=chain.tip_header();
    if block_id(parent)!=chain.tip_hash() {return Err("Native State header identity changed".into())}
    let mut cursor=0;
    let mut funding=Vec::new();
    loop {
        let page=chain.store.get_verified_owner_page(&owner.0,cursor,256).map_err(|e|e.to_string())?;
        if page.height!=parent.height || page.tip_hash!=chain.tip_hash() {return Err("Funding State changed during native planning".into())}
        if funding.len()+page.utxos.len()>16_384 {return Err("Native funding source limit reached".into())}
        funding.extend(page.utxos.into_iter().filter(|u|native_sequence(u.creation_id).is_err()).map(|u|types::WalletUtxoInfo {
            slot_index:u.slot_index,value_micronoid:u.amount,creation_id:u.creation_id,
            value_noid:u.amount as f64 / 1_000_000.0,address:owner_text.into(),
            key_index,confirmed_height:parent.height,reserved:false,
        }));
        match page.next_slot {Some(next) if next>cursor=>cursor=next,Some(_)=>return Err("Invalid funding cursor".into()),None=>break}
    }
    let mut limit=budget(artifacts)?;
    let next_height=parent.height.checked_add(1).ok_or("Native candidate height overflow")?;
    reserve_system_page(&mut limit,next_height);
    let prepared=planner::prepare(&chain,key_index,owner,action,funding,reserved,floor,limit)?;
    if chain.tip_hash()!=block_id(parent) {return Err("Native State changed during planning".into())}
    let plan=export(prepared)?;
    serde_json::to_value(plan).map_err(|e|e.to_string())
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn planning_envelope_rejects_extra_fields_including_secrets() {
        let base=serde_json::json!({"op":"native_prepare","owner":"o1placeholder","account_index":0,
            "expected_parent_hash":"a".repeat(64),"request":{"action":"transfer_nft"},
            "journal_directory":"/tmp/payments","artifacts":"/tmp/keys","data_dir":"/tmp/node"});
        assert!(checked_envelope(&base).is_ok());
        for key in ["seed_hex","master_hex","private_key","rpc","bundle"] {
            let mut changed=base.clone();changed[key]=serde_json::json!("not accepted");
            assert!(checked_envelope(&changed).is_err(),"{key}");
        }
    }
}
