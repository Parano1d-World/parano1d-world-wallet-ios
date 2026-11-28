//! Release reservations only when the transaction epoch is behind verified finality.
//! No RPC status, phone clock, peer message or caller-supplied height is evidence.
use anyhow::{ensure,Context,Result};
use serde_json::{json,Value};
use noid_chain::consensus::params::{TX_EPOCH_BLOCKS,CONSENSUS_FINALITY_DEPTH};
use std::{fs::File,path::Path};

fn finalized_expiry(anchor_height:u64,tip:u64,valid_until:Option<u64>)->Result<(u64,u64)> {
    ensure!(anchor_height%TX_EPOCH_BLOCKS==0,"Invalid epoch anchor height");
    let epoch_end=anchor_height.checked_add(TX_EPOCH_BLOCKS).context("Epoch overflow")?;
    let last=valid_until.map_or(epoch_end,|until|until.min(epoch_end));
    ensure!(last>0,"Invalid last eligible height");
    let finalized=tip.checked_sub(CONSENSUS_FINALITY_DEPTH).context("No finalized boundary")?;
    ensure!(finalized>=last,"Payment epoch is not behind verified finality; reservation retained");
    Ok((last,finalized))
}
pub(crate) struct Identity { pub(crate) txid:String, pub(crate) owner:String, anchor:String, valid_until:Option<u64> }
pub(crate) fn native_identity(encoded:&str,chain:[u8;32])->Result<Identity> {
    use noid_tx::native_assets::{wire::{NativeIntent,NATIVE_INTENT_MAGIC},trade::wire::{TradeOwnerIntent,TRADE_OWNER_INTENT_MAGIC}};
    use noid_gkr::{WalletAuthorizationBundle,zk_authorization::{ZkAuthCapsuleOwnerStatement,verify_zk_authorization_for_version},authorization_profile::OwnerAuthorizationVersion};
    ensure!(encoded.len()<=2*1024*1024,"Saved native intent exceeds limit");
    let bytes=hex::decode(encoded)?;
    let (auth,anchor,until,proof)=if bytes.starts_with(NATIVE_INTENT_MAGIC) {
        let intent=NativeIntent::from_bytes(&bytes)?;
        let facts=intent.validate_structure()?;
        ensure!(facts.chain==chain,"Native intent belongs to another chain");
        (facts.canonical_auth(),facts.epoch_anchor,None,intent.authorization_bytes)
    } else if bytes.starts_with(TRADE_OWNER_INTENT_MAGIC) {
        let wire=TradeOwnerIntent::from_bytes(&bytes)?;
        ensure!(wire.intent.policy.chain==chain,"Trade belongs to another chain");
        (wire.intent.canonical_auth()?,wire.intent.policy.epoch_anchor,Some(wire.intent.policy.valid_until),wire.authorization_bytes)
    } else {anyhow::bail!("Unsupported native intent encoding; reservation retained")};
    let bundle=WalletAuthorizationBundle::from_bytes(&proof)?;
    verify_zk_authorization_for_version(ZkAuthCapsuleOwnerStatement{tx_body_hash:auth.tx_body_hash.as_fields(),address:auth.input_owner.as_fields()},&bundle.proof,OwnerAuthorizationVersion::V4).map_err(|e|anyhow::anyhow!("Native authorization rejected: {e:?}"))?;
    Ok(Identity{txid:hex::encode(auth.tx_body_hash.0),owner:auth.input_owner.to_bech32(),anchor:hex::encode(anchor),valid_until:until})
}
pub fn run(request:&Value)->Result<Value> {
    let directory=Path::new(request["journal_directory"].as_str().context("Missing payment storage")?);
    let mut journal=crate::payment_journal::Journal::open(directory).map_err(anyhow::Error::msg)?;
    let pending=journal.entry(request["expected_txid"].as_str().context("Missing payment identity")?).context("No pending payment")?;
    ensure!(pending["state"]=="authorized","Only unresolved authorizations support expiry recovery");
    let txid=pending["txid"].as_str().context("Missing payment identity")?;
    ensure!(request["expected_txid"].as_str()==Some(txid),"Pending payment changed");
    let chain=noid_chain::state::native_assets::native_chain_id();
    ensure!(pending["chain_id"]==hex::encode(chain),"Pending payment belongs to another chain");
    let signed=pending["intent_hex"].as_str().context("Missing signed authorization")?;
    let (anchor,until)=if pending["operation_kind"]=="native" {
        let identity=native_identity(signed,chain)?;
        ensure!(identity.txid==txid && pending["owner"]==identity.owner,"Saved native authorization identity mismatch");
        (identity.anchor,identity.valid_until)
    }else{
        let inspected=paramo1d::courier_api::inspect_intent(signed)?;
        ensure!(inspected["txid"]==txid,"Saved authorization identity mismatch");
        (inspected["epoch_anchor"].as_str().context("Missing authorization epoch")?.to_owned(),None)
    };
    let node=Path::new(request["data_dir"].as_str().context("Missing verified node")?);
    let bundle=paramo1d::courier_api::accepted_bundle(node)?;
    let state=paramo1d::verify_bundle(Path::new(request["artifacts"].as_str().context("Missing verification parameters")?),&bundle,paramo1d::MatrixMode::Streaming)?;
    let mut headers=File::open(bundle.join("headers.bin"))?;
    let tip=paramo1d::headers::read_header(&mut headers,state.height())?;
    ensure!(hex::encode(noid_chain::block_header::block_id(&tip))==state.block_hash().to_string(),"Accepted boundary changed");
    let mut height=(state.height()/TX_EPOCH_BLOCKS)*TX_EPOCH_BLOCKS;
    loop {
        let header=paramo1d::headers::read_header(&mut headers,height)?;
        if hex::encode(noid_chain::block_header::block_id(&header))==anchor {
            let (last,finalized)=finalized_expiry(height,state.height(),until)?;
            journal.mark_expired(txid,last,finalized).map_err(anyhow::Error::msg)?;
            return Ok(json!({"txid":txid,"reservation_released":true,"last_valid_height":last,"verified_finalized_height":finalized,"settlement_status":"unknown"}));
        }
        if height==0 {break}
        height-=TX_EPOCH_BLOCKS;
    }
    anyhow::bail!("Authorization anchor is not in the accepted chain; reservation retained")
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn finality_must_cover_last_eligible_block_not_just_epoch_change(){
        let end=2*TX_EPOCH_BLOCKS;
        assert!(finalized_expiry(TX_EPOCH_BLOCKS,end,None).is_err());
        assert!(finalized_expiry(TX_EPOCH_BLOCKS,end+CONSENSUS_FINALITY_DEPTH-1,None).is_err());
        assert_eq!(finalized_expiry(TX_EPOCH_BLOCKS,end+CONSENSUS_FINALITY_DEPTH,None).unwrap(),(end,end));
    }
    #[test] fn rejects_unaligned_or_overflowing_boundaries(){assert!(finalized_expiry(1,u64::MAX,None).is_err());assert!(finalized_expiry(u64::MAX,0,None).is_err());assert!(finalized_expiry(0,0,None).is_err());}
    #[test] fn trade_window_can_expire_before_its_epoch_but_still_needs_finality(){
        let until=TX_EPOCH_BLOCKS+3;
        assert!(finalized_expiry(TX_EPOCH_BLOCKS,until+CONSENSUS_FINALITY_DEPTH-1,Some(until)).is_err());
        assert_eq!(finalized_expiry(TX_EPOCH_BLOCKS,until+CONSENSUS_FINALITY_DEPTH,Some(until)).unwrap(),(until,until));
        assert_eq!(finalized_expiry(0,TX_EPOCH_BLOCKS+CONSENSUS_FINALITY_DEPTH,Some(u64::MAX)).unwrap().0,TX_EPOCH_BLOCKS);
    }
    #[test] fn native_trade_recovery_reads_only_proof_bound_terms(){
        use noid_tx::{TxInput,native_assets::{AssetId,launch::LaunchSide,transition::NativeInputClaim,trade::{TradeIntent,TradePolicy,wire::TradeOwnerIntent}}};
        use noid_poseidon2b::primitives::{SpendSecret,derive_address};
        use noid_gkr::{wallet_authorization::{prove_native_trade_authorization,OwnerAuthWitness},authorization_profile::OwnerAuthorizationVersion};
        let key=SpendSecret::from_bytes([7;32]);let owner=derive_address(&key);let chain=[1;32];let anchor=[2;32];
        let intent=TradeIntent{policy:TradePolicy{chain,epoch_anchor:anchor,owner,asset:AssetId([3;32]),recipient:owner,side:LaunchSide::Buy,gross_input:100,minimum_output:1,fee_limit:10,valid_from:144,valid_until:147},funding:vec![NativeInputClaim{input:TxInput{slot_index:1,amount:110,creation_id:1},root:owner,opening:None}]};
        let mut wire=TradeOwnerIntent{intent,authorization_bytes:vec![]};
        assert!(native_identity(&hex::encode(wire.to_bytes().unwrap()),chain).is_err());
        wire.authorization_bytes=prove_native_trade_authorization(&wire.intent,chain,anchor,144,OwnerAuthWitness::new(key),OwnerAuthorizationVersion::V4).unwrap().to_bytes().unwrap();
        let encoded=hex::encode(wire.to_bytes().unwrap());
        let checked=native_identity(&encoded,chain).unwrap();
        assert_eq!(checked.valid_until,Some(147));assert_eq!(checked.owner,owner.to_bech32());
        assert!(native_identity(&encoded,[9;32]).is_err());
        wire.intent.policy.valid_until=146;
        assert!(native_identity(&hex::encode(wire.to_bytes().unwrap()),chain).is_err());
    }
}
