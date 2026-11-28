//! Ordinary payment planning from device-verified slot proofs, no spending secret.
//! Selection/layout adapted from pinned Paramo1d mobile_wallet.rs (Apache-2.0).
use anyhow::{ensure,Context,Result};
use serde_json::{json,Value};
use noid_chain::fri_state::SlotValue;
use noid_core::Block128;
use noid_poseidon2b::primitives::Address;
use noid_tx::{output_bitmap_bit,PagedSpendIntent,TxBody,TxInput,TxOutput,TxPage,PAGED_SPEND_END_BIT,PAGED_SPEND_START_BIT};
use sha2::{Digest,Sha256};
use std::collections::{BTreeMap,BTreeSet};
fn owner(value:SlotValue)->Address {let mut a=[0u8;32];a[..16].copy_from_slice(&value.owner_hi.0.to_le_bytes());a[16..].copy_from_slice(&value.owner_lo.0.to_le_bytes());Address(a)}
fn amount(value:u64)->String{format!("{}.{:06}",value/1_000_000,value%1_000_000)}
/// Highest fee the phone pays without a fresh look from the person (matches the review's limit).
pub(crate) const MAX_AUTO_FEE: u64 = 100_000;
/// The fee a payment actually pays: the consensus minimum, raised to the peers' current
/// relay floor when the network is busy (peers reject anything below that floor).
fn paid_fee(required:u64,floor:u64)->u64 {required.max(floor)}
fn max_net(total:u64,input_count:usize,active_slots:u64,log_slots:u32,floor:u64)->Result<(u64,u64)> {
    ensure!(input_count>0 && input_count<=504,"Send Max input limit");
    let fee=paid_fee(noid_chain::consensus::fees::fee_breakdown(
        input_count as u64,1,active_slots,log_slots
    ).required_total,floor);
    let payment=total.checked_sub(fee).filter(|amount|*amount>0)
        .context("Available NOID does not cover the network fee")?;
    Ok((payment,fee))
}
fn wallet_total(slots: &BTreeMap<u32, SlotValue>, address: Address) -> Result<u64> {
    slots
        .values()
        .filter(|v| {
            owner(**v) == address
                && noid_tx::native_assets::native_sequence(v.creation_id()).is_err()
        })
        .try_fold(0u64, |total, v| total.checked_add(v.amount()))
        .context("Balance overflow")
}
fn reservations(
    args: &Value,
    anchor: [u8; 32],
    proof_height: u64,
) -> Result<(BTreeSet<(u32, u64)>, BTreeSet<u32>)> {
    let mut inputs = BTreeSet::new();
    let mut outputs = BTreeSet::new();
    if let Some(packets) = args["reservations"].as_array() {
        ensure!(
            packets.len() <= 4096,
            "Too many pending authorizations. Synchronize to refresh the wallet"
        );
        let mut live_packets = 0;
        for packet in packets {
            if packet["epoch_anchor"].as_str() != Some(hex::encode(anchor).as_str())
                || packet["included_height"]
                    .as_u64()
                    .is_some_and(|height| height <= proof_height)
            {
                continue;
            }
            live_packets += 1;
            ensure!(
                live_packets <= 100,
                "Too many pending payments. Wait for confirmation or update your balance"
            );
            let reserved = packet["inputs"]
                .as_array()
                .context("Pending input reservations")?;
            ensure!(reserved.len() <= 504, "Pending input limit");
            for item in reserved {
                inputs.insert((
                    u32::try_from(item["slot_index"].as_u64().context("Reserved input slot")?)?,
                    item["creation_id"]
                        .as_u64()
                        .context("Reserved input identity")?,
                ));
            }
            let reserved = packet["outputs"]
                .as_array()
                .context("Pending output reservations")?;
            ensure!(reserved.len() <= 126, "Pending output limit");
            for item in reserved {
                outputs.insert(u32::try_from(
                    item.as_u64().context("Reserved output slot")?,
                )?);
            }
        }
    }
    Ok((inputs, outputs))
}

pub fn run(args:&Value)->Result<Value> {
    let recipient=Address::parse(args["address"].as_str().context("Missing recipient")?).map_err(|_|anyhow::anyhow!("Invalid recipient"))?;
    let send_max=args["send_max"].as_bool()==Some(true);
    ensure!(!send_max || args["amount"].is_null(),"Send Max must not include a custom amount");
    let requested=if send_max {None} else {Some(paramo1d_courier::amount_micronoid(args["amount"].as_str().context("Missing amount")?)?)};
    ensure!(requested != Some(0),"Payment must be positive");
    let boundary=crate::balance::snapshot(args,true)?;
    let owner=boundary.owner;
    let proof_height=boundary.proof_height.context("No authenticated wallet snapshot")?;
    let slots=&boundary.slots;
    let cached=args["use_cached"].as_bool()==Some(true);
    let total_balance = wallet_total(&slots, owner)?;
    let epoch = noid_chain::consensus::tx_epoch_anchor_height_for_child(boundary.header.height + 1);
    let anchor = boundary.anchor;
    ensure!(anchor.height == epoch, "Payment epoch boundary");
    let (mut reserved_inputs, mut reserved_outputs) = reservations(
        args,
        noid_chain::block_header::block_id(&anchor),
        proof_height,
    )?;
    // Coins and output slots that peers' pending transactions already claim (this wallet
    // on another device, or anyone's new outputs) are never planned again.
    for item in args["mempool"]["inputs"].as_array().into_iter().flatten().take(200_000) {
        if let (Some(slot), Some(creation)) = (item[0].as_u64(), item[1].as_u64()) {
            if let Ok(slot) = u32::try_from(slot) { reserved_inputs.insert((slot, creation)); }
        }
    }
    for item in args["mempool"]["outputs"].as_array().into_iter().flatten().take(200_000) {
        if let Some(slot) = item.as_u64().and_then(|v| u32::try_from(v).ok()) { reserved_outputs.insert(slot); }
    }
    let mut available = slots
        .iter()
        .filter(|(index, v)| {
            !reserved_inputs.contains(&(**index, v.creation_id()))
                && **v != SlotValue::EMPTY
                && owner == self::owner(**v)
                && noid_tx::native_assets::native_sequence(v.creation_id()).is_err()
        })
        .map(|(i, v)| (*i, *v))
        .collect::<Vec<_>>();
    available.sort_by_key(|(index, v)| (std::cmp::Reverse(v.amount()), *index));
    let empty = slots
        .iter()
        .filter(|(index, v)| **v == SlotValue::EMPTY && !reserved_outputs.contains(index))
        .map(|(i, _)| *i)
        .take(2)
        .collect::<Vec<_>>();
    ensure!(
        empty.len() == 2,
        "Refresh State to obtain available output slots"
    );
    let mut selected = Vec::new();
    let mut total = 0u64;
    let mut fee = 0u64;
    let floor = args["mempool"]["floor"].as_u64().unwrap_or(0);
    let payment = if send_max {
        ensure!(!available.is_empty() && available.len()<=504,"Send Max needs a fresh wallet with at most 504 available inputs");
        for (index,value) in available {
            total=total.checked_add(value.amount()).context("Input amount overflow")?;
            selected.push((index,value));
        }
        let (payment,computed_fee)=max_net(total,selected.len(),boundary.header.active_slot_count,boundary.header.log_slots,floor)?;
        fee=computed_fee;
        payment
    } else {
        let requested=requested.context("Missing amount")?;
        for (index, value) in available.into_iter().take(504) {
            total = total.checked_add(value.amount()).context("Input amount overflow")?;
            selected.push((index, value));
            fee = paid_fee(noid_chain::consensus::fees::fee_breakdown(
                selected.len() as u64,2,boundary.header.active_slot_count,boundary.header.log_slots
            ).required_total,floor);
            if total >= requested.checked_add(fee).context("Amount overflow")? {break;}
        }
        requested
    };
    ensure!(
        total >= payment.checked_add(fee).context("Amount overflow")?,
        "Insufficient available NOID. Pending authorizations reserve their inputs until confirmed or expired"
    );
    ensure!(fee <= MAX_AUTO_FEE, "The network is very busy: peers currently need a fee above 0.1 NOID. Nothing was signed. Try again in a few minutes");
    let change = total - payment - fee;
    let mut pages = Vec::new();
    for (index, chunk) in selected.chunks(8).enumerate() {
        let mut body = TxBody {
            epoch_anchor: noid_chain::block_header::block_id(&anchor),
            fee: if index == 0 { fee } else { 0 },
            input_owner: owner,
            inputs: [TxInput::dummy(); 8],
            outputs: [TxOutput::dummy(); 2],
            validity_bitmap: 0,
            is_coinbase: false,
        };
        for (offset, (slot, v)) in chunk.iter().enumerate() {
            body.inputs[offset] = TxInput {
                slot_index: *slot,
                amount: v.amount(),
                creation_id: v.creation_id(),
            };
            body.validity_bitmap |= 1 << offset;
        }
        if index == 0 {
            body.validity_bitmap |= PAGED_SPEND_START_BIT | output_bitmap_bit(0);
            body.outputs[0] = TxOutput {
                slot_index: empty[0],
                amount: payment,
                owner: recipient,
            };
            if change > 0 {
                body.validity_bitmap |= output_bitmap_bit(1);
                body.outputs[1] = TxOutput {
                    slot_index: empty[1],
                    amount: change,
                    owner,
                };
            }
        }
        if index + 1 == selected.len().div_ceil(8) {
            body.validity_bitmap |= PAGED_SPEND_END_BIT;
        }
        pages.push(TxPage::new(body).map_err(|e| anyhow::anyhow!("Payment layout: {e}"))?);
    }
    let unsigned = PagedSpendIntent::new(pages, vec![])
        .map_err(|e| anyhow::anyhow!("Payment layout: {e}"))?
        .to_bytes()
        .map_err(|e| anyhow::anyhow!("Payment encoding: {e}"))?;
    let review_id = hex::encode(Sha256::digest(&unsigned));
    let chain_id=hex::encode(noid_chain::block_header::block_id(&noid_chain::consensus::genesis::genesis_header()));
    Ok(
        json!({"review_id":review_id,"chain_id":chain_id,"owner":owner.to_bech32(),"unsigned_intent":hex::encode(unsigned),"to":recipient.to_bech32(),"amount":amount(payment),"fee":amount(fee),"busy_fee":fee>noid_chain::consensus::fees::fee_breakdown(selected.len() as u64,if send_max {1} else {2},boundary.header.active_slot_count,boundary.header.log_slots).required_total,"total":amount(payment.checked_add(fee).context("Payment total overflow")?),"send_max":send_max,"height":boundary.header.height,"balance_height":proof_height,"valid_through_height":epoch.checked_add(noid_chain::consensus::params::TX_EPOCH_BLOCKS).context("Payment epoch overflow")?,"using_saved_state":cached,"wallet":{"height":boundary.header.height,"balance_height":proof_height,"balance":amount(total_balance),"balance_micronoid":total_balance.to_string(),"block_hash":hex::encode(noid_chain::block_header::block_id(&boundary.header))}}),
    )
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn send_max_deducts_exact_single_output_fee() {
        let (payment,fee)=max_net(1_000_000_000,2,1000,16,0).unwrap();
        assert_eq!(payment.checked_add(fee),Some(1_000_000_000));
        assert!(max_net(fee,2,1000,16,0).is_err());
        let (busy_payment,busy_fee)=max_net(1_000_000_000,2,1000,16,fee+7).unwrap();
        assert_eq!(busy_fee,fee+7); assert_eq!(busy_payment+busy_fee,1_000_000_000);
        assert_eq!(paid_fee(10,0),10); assert_eq!(paid_fee(10,25),25);
        assert!(max_net(1_000_000_000,505,1000,16,0).is_err());
    }
}
