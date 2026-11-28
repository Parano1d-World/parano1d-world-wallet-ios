//! Exact, read-only planning inputs from one independently verified State.
//! This is deliberately not an admission snapshot or permission to sign.
use serde_json::Value;
use std::collections::BTreeSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Source {
    pub slot: u32,
    pub creation_id: u64,
    pub amount: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NativeSource {
    pub carrier: Source,
    pub root: [u8; 32],
    pub identity: Value,
}

#[derive(Debug, Clone)]
pub(crate) struct Snapshot {
    pub parent: [u8; 32],
    pub state_root: [u8; 32],
    pub height: u64,
    pub funding: Vec<Source>,
    pub native: Vec<NativeSource>,
}

fn decimal(value: &Value, label: &str) -> Result<u64, String> {
    let text = value.as_str().ok_or_else(|| format!("Missing {label}"))?;
    if text.is_empty() || text.len() > 20 || !text.bytes().all(|b| b.is_ascii_digit())
        || text.len() > 1 && text.starts_with('0') {
        return Err(format!("Noncanonical {label}"));
    }
    text.parse().map_err(|_| format!("Overflowing {label}"))
}

fn digest(value: &Value, label: &str) -> Result<[u8; 32], String> {
    let text = value.as_str().ok_or_else(|| format!("Missing {label}"))?;
    if text.len() != 64 || !text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err(format!("Noncanonical {label}"));
    }
    let mut bytes = [0; 32];
    hex::decode_to_slice(text, &mut bytes).map_err(|_| format!("Invalid {label}"))?;
    Ok(bytes)
}

fn source(value: &Value) -> Result<Source, String> {
    let raw_slot = value["slot_index"].as_u64().ok_or("Missing source slot")?;
    let slot = u32::try_from(raw_slot).map_err(|_| "Source slot exceeds u32")?;
    let creation_id = decimal(&value["creation_id"], "creation ID")?;
    let amount = decimal(&value["amount_micronoid"], "source amount")?;
    Ok(Source { slot, creation_id, amount })
}

impl Snapshot {
    pub(crate) fn parse(value: &Value, expected_parent: &str) -> Result<Self, String> {
        if value["state_boundary_matches"] != true || value["can_authorize_native"] != false {
            return Err("Native planning probe did not return a read-only verified State".into());
        }
        let parent = digest(&value["parent_hash"], "State parent")?;
        if parent != digest(&Value::String(expected_parent.to_owned()), "expected parent")? {
            return Err("Native State is not at the requested verified parent".into());
        }
        let state_root = digest(&value["state_root"], "State root")?;
        let height = value["height"].as_u64().ok_or("Missing State height")?;
        let funding_values = value["funding_sources"].as_array().ok_or("Missing funding sources")?;
        let native_values = value["native_sources"].as_array().ok_or("Missing native sources")?;
        if funding_values.len() > 16_384 || native_values.len() > 16_384 {
            return Err("Native planning source limit exceeded".into());
        }
        let mut occupied = BTreeSet::new();
        let mut funding = Vec::with_capacity(funding_values.len());
        for value in funding_values {
            let item = source(value)?;
            if !occupied.insert(item.slot) { return Err("Repeated funding slot".into()); }
            funding.push(item);
        }
        let mut native = Vec::with_capacity(native_values.len());
        let mut roots = BTreeSet::new();
        for value in native_values {
            let carrier = source(value)?;
            let root = digest(&value["root"], "native opening root")?;
            let identity = value.get("identity").filter(|v| v.is_object())
                .ok_or("Missing native opening identity")?.clone();
            if !matches!(identity["kind"].as_str(), Some("token" | "nft" | "listing")) {
                return Err("Unsupported native opening identity".into());
            }
            if !occupied.insert(carrier.slot) || !roots.insert(root) {
                return Err("Repeated native carrier or opening root".into());
            }
            native.push(NativeSource { carrier, root, identity });
        }
        if value["owner_funding_sources"].as_u64() != Some(funding.len() as u64) {
            return Err("Funding count changed during planning snapshot".into());
        }
        let total = funding.iter().try_fold(0u128, |sum, item|
            sum.checked_add(u128::from(item.amount))).ok_or("Funding sum overflow")?;
        if value["owner_funding_micronoid"].as_str() != Some(total.to_string().as_str()) {
            return Err("Funding amount changed during planning snapshot".into());
        }
        Ok(Self { parent, state_root, height, funding, native })
    }
}

#[cfg(test)] mod tests {
    use super::*;
    use serde_json::json;
    fn fixture() -> Value { json!({
        "state_boundary_matches": true, "can_authorize_native": false,
        "height": 12, "parent_hash": "a".repeat(64), "state_root": "b".repeat(64),
        "owner_funding_sources": 1, "owner_funding_micronoid": "12",
        "funding_sources": [{"slot_index": 1, "creation_id": "4", "amount_micronoid": "12"}],
        "native_sources": [{"slot_index": 2, "creation_id": "5", "amount_micronoid": "0",
            "root": "c".repeat(64), "identity": {"kind": "nft", "serial": "1"}}]
    }) }
    #[test] fn accepts_only_one_exact_verified_parent() {
        let snapshot = Snapshot::parse(&fixture(), &"a".repeat(64)).unwrap();
        assert_eq!(snapshot.funding[0].creation_id, 4);
        assert_eq!(snapshot.native[0].carrier.slot, 2);
        assert!(Snapshot::parse(&fixture(), &"d".repeat(64)).is_err());
    }
    #[test] fn rejects_conflicts_and_display_totals() {
        let mut value = fixture(); value["native_sources"][0]["slot_index"] = json!(1);
        assert!(Snapshot::parse(&value, &"a".repeat(64)).is_err());
        let mut value = fixture(); value["owner_funding_micronoid"] = json!("13");
        assert!(Snapshot::parse(&value, &"a".repeat(64)).is_err());
        let mut value = fixture(); value["funding_sources"][0]["creation_id"] = json!("04");
        assert!(Snapshot::parse(&value, &"a".repeat(64)).is_err());
    }
    #[test] fn never_accepts_an_authorization_claim_from_probe() {
        let mut value = fixture(); value["can_authorize_native"] = json!(true);
        assert!(Snapshot::parse(&value, &"a".repeat(64)).is_err());
    }
}
