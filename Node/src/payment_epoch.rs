//! Fail closed if the reviewed payment belongs to a different verified epoch.
use anyhow::{ensure, Context, Result};
use noid_tx::PagedSpendIntent;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub fn run(args: &Value) -> Result<Value> {
    let encoded = args["unsigned_intent"].as_str().context("Missing reviewed payment")?;
    ensure!(encoded.len() <= 2 * noid_tx::MAX_PAGED_SPEND_INTENT_BYTES, "Payment too large");
    let bytes = hex::decode(encoded)?;
    ensure!(
        args["review_id"].as_str() == Some(hex::encode(Sha256::digest(&bytes)).as_str()),
        "Payment differs from approved review"
    );
    let intent = PagedSpendIntent::from_bytes(&bytes)
        .map_err(|e| anyhow::anyhow!("Invalid reviewed payment: {e}"))?;
    ensure!(intent.authorization_bytes.is_empty(), "Review is already authorized");
    let requested_owner = args["owner"].as_str().context("Missing reviewed wallet")?;
    ensure!(intent.pages.iter().all(|p| p.body.input_owner.to_bech32() == requested_owner), "Reviewed wallet changed");
    let mut online = args.clone();
    online["use_cached"] = json!(false);
    // A new, locally verified boundary and fresh owner/output proofs are required.
    // Failure to reach the chain prevents online signing.
    let snapshot = crate::balance::snapshot(&online, true)?;
    let current_anchor = noid_chain::block_header::block_id(&snapshot.anchor);
    ensure!(intent.pages.iter().all(|p| p.body.epoch_anchor == current_anchor),
        "Payment epoch changed. Update your wallet and review the payment again.");
    ensure!(snapshot.proof_height.is_some(), "No current wallet state; review the payment again");
    Ok(json!({"height":snapshot.header.height,"epoch_anchor":hex::encode(current_anchor),"review_id":args["review_id"]}))
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn rejects_invalid_review_before_network_access() {
        assert!(run(&json!({})).is_err());
        assert!(run(&json!({"unsigned_intent":"00","review_id":"wrong"})).unwrap_err().to_string().contains("review"));
    }
}
