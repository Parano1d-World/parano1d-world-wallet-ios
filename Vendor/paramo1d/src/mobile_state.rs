//! A snapshot is local wallet State only after the complete sparse root and
//! independently checked HistoryStep boundary are atomically installed.
use anyhow::{ensure, Context, Result};
use noid_chain::{
    add_work, block_work,
    block_header::{block_id, BlockHeader},
    consensus::params,
    storage::{
        FinalizedSnapshotStaging, MdbxChainContext, MdbxStore, SnapshotHeaderInstallSource,
        VerifiedHeaderBatchRecord, NativeCatalogKind,
        native_payloads::NativeAssetLookup,
    },
};
use noid_p2p::protocol::GetStateManifestResponse;
use noid_poseidon2b::primitives::Address;
use noid_tx::native_assets::{AssetId, NativeOpening, launch::LaunchOpening, market::MarketOpening, nft_market::NftMarketOpening};
use serde_json::{json, Value};
use std::{collections::{BTreeMap, BTreeSet}, fs::File, path::Path};

struct VerifiedFileHeaders {
    file: File,
    base: VerifiedHeaderBatchRecord,
    target: VerifiedHeaderBatchRecord,
    recent: Vec<BlockHeader>,
    next: u64,
    running_work: [u8; 32],
    last_hash: [u8; 32],
}

impl VerifiedFileHeaders {
    fn new(context: &MdbxChainContext, bundle: &Path, manifest: &GetStateManifestResponse) -> Result<Self> {
        let mut file = File::open(bundle.join("headers.bin"))?;
        let base_height = context.tip_height();
        ensure!(base_height < manifest.tip_height, "snapshot does not advance the installed State");
        let base_header = crate::headers::read_header(&mut file, base_height)?;
        ensure!(block_id(&base_header) == context.tip_hash(), "snapshot fork differs from local State");
        let base = VerifiedHeaderBatchRecord {
            header: base_header,
            hash: context.tip_hash(),
            cumulative_chainwork: *context.tip_chain_work(),
        };
        let mut work = base.cumulative_chainwork;
        let mut target = base;
        for height in base_height + 1..=manifest.tip_height {
            let header = crate::headers::read_header(&mut file, height)?;
            ensure!(header.prev_block_hash == target.hash, "snapshot header suffix is discontinuous");
            work = add_work(&work, &block_work(&header.difficulty_target));
            target = VerifiedHeaderBatchRecord { header, hash: block_id(&header), cumulative_chainwork: work };
        }
        ensure!(target.hash == manifest.tip_hash && target.cumulative_chainwork == manifest.cumulative_chainwork,
            "snapshot chainwork or boundary differs from verified headers");
        let first = manifest.tip_height.saturating_sub(params::MEDIAN_TIME_BLOCKS as u64 + params::TX_EPOCH_BLOCKS);
        let mut recent = Vec::with_capacity((manifest.tip_height - first + 1) as usize);
        for height in first..=manifest.tip_height {
            recent.push(crate::headers::read_header(&mut file, height)?);
        }
        Ok(Self { file, base, target, recent, next: base_height + 1,
            running_work: base.cumulative_chainwork, last_hash: base.hash })
    }
}

impl SnapshotHeaderInstallSource for VerifiedFileHeaders {
    fn base_record(&self) -> VerifiedHeaderBatchRecord { self.base }
    fn target_record(&self) -> VerifiedHeaderBatchRecord { self.target }
    fn recent_headers(&self) -> &[BlockHeader] { &self.recent }
    fn next_record(&mut self) -> std::result::Result<Option<VerifiedHeaderBatchRecord>, String> {
        if self.next > self.target.header.height { return Ok(None); }
        let header = crate::headers::read_header(&mut self.file, self.next).map_err(|e|e.to_string())?;
        if header.prev_block_hash != self.last_hash { return Err("snapshot header chain changed during install".into()); }
        self.running_work = add_work(&self.running_work, &block_work(&header.difficulty_target));
        self.last_hash = block_id(&header);
        self.next += 1;
        let record = VerifiedHeaderBatchRecord { header, hash: self.last_hash, cumulative_chainwork: self.running_work };
        if self.next > self.target.header.height && record != self.target {
            return Err("snapshot target changed during installation".into());
        }
        Ok(Some(record))
    }
}

pub(crate) fn installed_at(database: &Path, manifest: &GetStateManifestResponse) -> Result<bool> {
    if !database.exists() { return Ok(false); }
    let context = MdbxChainContext::open_or_create(database)?;
    if context.tip_height() != manifest.tip_height || context.tip_hash() != manifest.tip_hash {
        return Ok(false);
    }
    let header = context.get_header_from_store(manifest.tip_height)?
        .context("installed native State has no tip header")?;
    ensure!(header.state_root == manifest.state_root && context.tip_chain_work() == &manifest.cumulative_chainwork,
        "installed native State conflicts with verified snapshot");
    Ok(true)
}

/// Read one locally installed owner index. The returned snapshot height is
/// explicit because a finalized State boundary may lag the verifier's tip.
pub(crate) fn holdings(artifacts: &Path, data_dir: &Path, owner: &str) -> Result<Value> {
    let address = Address::parse(owner).map_err(|e| anyhow::anyhow!("Invalid owner: {e}"))?;
    ensure!(address.to_bech32() == owner, "noncanonical owner address");
    let database = data_dir.join("NativeState");
    ensure!(database.exists(), "Native State has not been installed on this phone");
    let store = MdbxStore::open(&database)?;
    let bundle = crate::courier_api::accepted_bundle(data_dir)?;
    let mut cursor = None;
    let mut items = Vec::new();
    let mut binding = None;
    for _ in 0..64 {
        let page = store.native_wallet_page(address, cursor, 256)?;
        let identity = (page.height, page.tip_hash, page.state_root);
        if let Some(previous) = binding {
            ensure!(previous == identity, "Native State changed during holdings pagination");
        } else {
            let accepted = crate::verifier_session::header(artifacts, &bundle, page.height)?;
            ensure!(block_id(&accepted) == page.tip_hash && accepted.state_root == page.state_root,
                "Native State is not on the verified mobile chain");
            binding = Some(identity);
        }
        for item in page.items {
            let base = json!({"root":hex::encode(item.root),"slot_index":item.carrier.slot_index.to_string(),
                "sequence":(item.carrier.creation_id & !(1u64<<63)).to_string(),
                "unlock_height":item.opening.unlock_height().to_string(),"reserved":false});
            let mut value = match item.opening {
                NativeOpening::TokenBalance(token) => json!({
                    "type":"token","asset_id":hex::encode(token.asset.0),
                    "owner":token.owner.to_string(),"units":token.units.to_string()
                }),
                NativeOpening::NftItem(nft) => json!({
                    "type":"nft","collection_id":hex::encode(nft.collection.0),
                    "serial":nft.serial.to_string(),"owner":nft.owner.to_string(),
                    "metadata_hash":hex::encode(nft.metadata)
                }),
                _ => continue,
            };
            for key in ["root","slot_index","sequence","unlock_height","reserved"] {
                value[key] = base[key].clone();
            }
            items.push(value);
            ensure!(items.len() <= 16_384, "Native wallet exceeds mobile display limit");
        }
        cursor = page.next;
        if cursor.is_none() {
            let (height,hash,root) = binding.context("Native State has no owner snapshot")?;
            // Market discovery is optional. Resolve owned token definitions by
            // their exact native asset ID, including tokens with no NOID pair.
            let mut token_metadata = BTreeMap::<String,String>::new();
            for item in &items {
                let Some(id) = item["asset_id"].as_str() else { continue };
                if token_metadata.contains_key(id) { continue; }
                let mut asset = [0u8; 32];
                hex::decode_to_slice(id, &mut asset).context("Invalid owned token ID")?;
                let definition_root = store.native_asset_root(NativeAssetLookup::TokenDefinition(AssetId(asset)))?
                    .context("Owned token definition is missing")?;
                let payload = store.native_payload(definition_root)?
                    .context("Owned token definition payload is missing")?;
                let NativeOpening::FungibleDefinition(definition) = payload.opening else {
                    anyhow::bail!("Owned token definition has an invalid opening");
                };
                ensure!(definition.asset.0 == asset, "Owned token definition identity changed");
                token_metadata.insert(id.to_owned(), hex::encode(definition.metadata));
            }
            for item in &mut items {
                if let Some(metadata) = item["asset_id"].as_str().and_then(|id| token_metadata.get(id)) {
                    item["metadata_hash"] = json!(metadata);
                }
            }
            let wanted: BTreeSet<String> = items.iter().filter_map(|entry|
                entry["collection_id"].as_str().map(str::to_owned)).collect();
            let mut collections = Vec::new();
            if !wanted.is_empty() {
                let mut next = None;
                let mut complete = false;
                for _ in 0..64 {
                    let page = store.native_catalog_page(NativeCatalogKind::Collections, next, 256)?;
                    ensure!((page.height, page.tip_hash, page.state_root) == (height,hash,root),
                        "collection catalog changed during owner discovery");
                    for item in page.items {
                        if let NativeOpening::NftCollection(definition) = item.primary.opening {
                            let id = hex::encode(definition.collection.0);
                            if wanted.contains(&id) {
                                collections.push(json!({"type":"collection","root":hex::encode(item.primary.root),
                                    "collection_id":id,"metadata_hash":hex::encode(definition.metadata),
                                    "issued_items":definition.issued_items.to_string()}));
                            }
                        }
                    }
                    next = page.next;
                    if next.is_none() {complete = true; break;}
                }
                ensure!(complete, "collection catalog exceeds mobile limit");
                ensure!(collections.len() == wanted.len(), "owned NFT collection definition is missing");
            }
            return Ok(json!({"owner":owner,"height":height,"block_hash":hex::encode(hash),
                "state_root":hex::encode(root),"items":items,"collections":collections,"complete":true}));
        }
    }
    anyhow::bail!("Native holdings pagination exceeds mobile limit")
}

/// Read-only planning preflight. This never builds an intent or treats an
/// explorer's holdings as spendable. It establishes whether the phone's
/// installed owner funding index is at the exact accepted verifier boundary.
pub(crate) fn planning_probe(
    artifacts: &Path,
    data_dir: &Path,
    owner: &str,
    expected_parent_hash: &str,
) -> Result<Value> {
    let address = Address::parse(owner).map_err(|e| anyhow::anyhow!("Invalid owner: {e}"))?;
    ensure!(address.to_bech32() == owner, "noncanonical owner address");
    ensure!(expected_parent_hash.len() == 64 && expected_parent_hash.bytes().all(|b|
        b.is_ascii_digit() || (b'a'..=b'f').contains(&b)), "invalid expected parent");
    let database = data_dir.join("NativeState");
    ensure!(database.exists(), "Native State has not been installed on this phone");
    let store = MdbxStore::open(&database)?;
    let bundle = crate::courier_api::accepted_bundle(data_dir)?;
    let mut cursor = 0;
    let mut binding = None;
    let mut funding_count = 0usize;
    let mut funding_micronoid = 0u128;
    let mut funding_slots = BTreeSet::new();
    let mut funding_sources = Vec::new();
    for _ in 0..64 {
        let page = store.get_verified_owner_page(&address.0, cursor, 256)?;
        let identity = (page.height, page.tip_hash);
        if let Some(previous) = binding {
            ensure!(previous == identity, "owner funding State changed during preflight");
        } else {
            ensure!(hex::encode(page.tip_hash) == expected_parent_hash,
                "installed owner funding is behind the phone's verified parent");
            let accepted = crate::verifier_session::header(artifacts, &bundle, page.height)?;
            ensure!(block_id(&accepted) == page.tip_hash,
                "owner funding is not on the accepted mobile chain");
            let native = store.native_wallet_page(address, None, 1)?;
            ensure!(native.height == page.height && native.tip_hash == page.tip_hash
                && native.state_root == accepted.state_root,
                "native opening State differs from owner funding State");
            binding = Some(identity);
        }
        for utxo in page.utxos {
            ensure!(funding_slots.insert(utxo.slot_index), "duplicate owner funding slot");
            funding_count += 1;
            funding_micronoid = funding_micronoid.checked_add(u128::from(utxo.amount))
                .context("owner funding overflow")?;
            funding_sources.push(json!({
                "slot_index": utxo.slot_index,
                "creation_id": utxo.creation_id.to_string(),
                "amount_micronoid": utxo.amount.to_string()
            }));
        }
        ensure!(funding_count <= 16_384, "owner funding source limit reached");
        match page.next_slot {
            Some(next) if next > cursor => cursor = next,
            Some(_) => anyhow::bail!("invalid owner funding cursor"),
            None => {
                let (height, hash) = binding.context("owner funding State unavailable")?;
                let accepted = crate::verifier_session::header(artifacts, &bundle, height)?;
                let mut native_cursor = None;
                let mut native_slots = BTreeSet::new();
                let mut native_sources = Vec::new();
                let mut native_complete = false;
                for _ in 0..64 {
                    let native = store.native_wallet_page(address, native_cursor, 256)?;
                    ensure!((native.height, native.tip_hash, native.state_root)
                        == (height, hash, accepted.state_root),
                        "native opening State changed during planning snapshot");
                    for item in native.items {
                        ensure!(native_slots.insert(item.carrier.slot_index),
                            "duplicate native carrier slot");
                        let identity = match item.opening {
                            NativeOpening::TokenBalance(token) => json!({
                                "kind": "token", "asset_id": hex::encode(token.asset.0),
                                "units": token.units.to_string()
                            }),
                            NativeOpening::NftItem(nft) => json!({
                                "kind": "nft", "collection_id": hex::encode(nft.collection.0),
                                "serial": nft.serial.to_string()
                            }),
                            NativeOpening::NftMarket(NftMarketOpening::Listing(listing)) => json!({
                                "kind": "listing", "listing_id": hex::encode(listing.listing.0),
                                "collection_id": hex::encode(listing.collection.0),
                                "serial": listing.serial.to_string(),
                                "generation": listing.generation.to_string()
                            }),
                            _ => continue,
                        };
                        native_sources.push(json!({
                            "identity": identity, "root": hex::encode(item.root),
                            "slot_index": item.carrier.slot_index,
                            "creation_id": item.carrier.creation_id.to_string(),
                            "amount_micronoid": item.carrier.amount.to_string()
                        }));
                        ensure!(native_sources.len() <= 16_384,
                            "native planning source limit reached");
                    }
                    native_cursor = native.next;
                    if native_cursor.is_none() { native_complete = true; break; }
                }
                ensure!(native_complete, "native planning pagination exceeds mobile limit");
                return Ok(json!({
                    "height": height,
                    "parent_hash": hex::encode(hash),
                    "state_root": hex::encode(accepted.state_root),
                    "owner_funding_sources": funding_count,
                    "owner_funding_micronoid": funding_micronoid.to_string(),
                    // Exact, incarnation-bound sources are a prerequisite for
                    // local conflict checks. This is a read-only snapshot,
                    // never an authorization or a spendable balance.
                    "funding_sources": funding_sources,
                    "native_sources": native_sources,
                    "state_boundary_matches": true,
                    "can_authorize_native": false,
                    "missing": ["atomic mempool reservations", "fee floor and admission budget", "native intent planner"]
                }));
            }
        }
    }
    anyhow::bail!("owner funding pagination exceeds mobile limit")
}

/// Read live NOID pairs from the installed, independently verified State.
/// Quotes are observations at this boundary, never executable trade promises.
pub(crate) fn markets(artifacts: &Path, data_dir: &Path) -> Result<Value> {
    let database = data_dir.join("NativeState");
    ensure!(database.exists(), "Native State has not been installed on this phone");
    let store = MdbxStore::open(&database)?;
    let bundle = crate::courier_api::accepted_bundle(data_dir)?;
    let mut next = None;
    let mut binding = None;
    let mut entries = Vec::new();
    for _ in 0..64 {
        let page = store.native_catalog_page(NativeCatalogKind::Markets, next, 256)?;
        let identity = (page.height, page.tip_hash, page.state_root);
        if let Some(previous) = binding {
            ensure!(previous == identity, "Native markets changed during pagination");
        } else {
            let header = crate::verifier_session::header(artifacts, &bundle, page.height)?;
            ensure!(block_id(&header) == page.tip_hash && header.state_root == page.state_root,
                "Native markets are not on the verified mobile chain");
            binding = Some(identity);
        }
        for item in page.items {
            let token_metadata = item.related.iter().find_map(|related| match related.opening {
                NativeOpening::FungibleDefinition(definition) => Some(hex::encode(definition.metadata)),
                _ => None,
            });
            let entry = match (item.primary.opening, item.primary.dependency) {
                (NativeOpening::Market(MarketOpening::Pool(pool)),
                 Some(NativeOpening::Market(MarketOpening::Definition(definition))))
                    if definition.base_is_noid() && pool.quote_reserve > 0 =>
                    Some(json!({"type":"dex","asset_id":hex::encode(definition.quote.0),
                        "root":hex::encode(item.primary.root),
                        "base_reserve":pool.base_reserve.to_string(),
                        "quote_reserve":pool.quote_reserve.to_string(),
                        "price_numerator":pool.base_reserve.to_string(),
                        "price_denominator":pool.quote_reserve.to_string()})),
                (NativeOpening::Launch(LaunchOpening::State(state)),
                 Some(NativeOpening::Launch(LaunchOpening::Definition(definition)))) => {
                    let sold = definition.initial_supply.saturating_sub(state.inventory_units);
                    let price = definition.marginal_price(sold)?;
                    Some(json!({"type":"curve","asset_id":hex::encode(definition.asset.0),
                        "root":hex::encode(item.primary.root),
                        "sold_units":sold.to_string(),"supply":definition.initial_supply.to_string(),
                        "price_numerator":price.numerator.to_string(),
                        "price_denominator":price.denominator.to_string()}))
                }
                _ => None,
            };
            if let Some(mut entry) = entry {
                if let Some(metadata_hash) = token_metadata { entry["metadata_hash"] = json!(metadata_hash); }
                entries.push(entry);
            }
            ensure!(entries.len() <= 16_384, "Native market catalog exceeds mobile limit");
        }
        next = page.next;
        if next.is_none() {
            let (height, hash, root) = binding.context("Native market snapshot unavailable")?;
            return Ok(json!({"height":height,"block_hash":hex::encode(hash),
                "state_root":hex::encode(root),"items":entries,"complete":true}));
        }
    }
    anyhow::bail!("Native market pagination exceeds mobile limit")
}

/// Catalog collection definitions at a boundary accepted by the mobile verifier.
/// Reading does not contact a gateway or authorize any operation.
pub(crate) fn collections(artifacts: &Path, data_dir: &Path) -> Result<Value> {
    let database = data_dir.join("NativeState");
    ensure!(database.exists(), "Native State has not been installed on this phone");
    let store = MdbxStore::open(&database)?;
    let bundle = crate::courier_api::accepted_bundle(data_dir)?;
    let mut next = None;
    let mut binding = None;
    let mut entries = Vec::new();
    for _ in 0..64 {
        let page = store.native_catalog_page(NativeCatalogKind::Collections, next, 256)?;
        let identity = (page.height, page.tip_hash, page.state_root);
        if let Some(previous) = binding {
            ensure!(previous == identity, "NFT collections changed during pagination");
        } else {
            ensure!(page.height > 0, "NFT State is still at genesis");
            let header = crate::verifier_session::header(artifacts, &bundle, page.height)?;
            ensure!(block_id(&header) == page.tip_hash && header.state_root == page.state_root,
                "NFT collections are not on the verified mobile chain");
            binding = Some(identity);
        }
        for item in page.items {
            if let NativeOpening::NftCollection(definition) = item.primary.opening {
                entries.push(json!({"type":"collection","root":hex::encode(item.primary.root),
                    "collection_id":hex::encode(definition.collection.0),
                    "metadata_hash":hex::encode(definition.metadata),
                    "issued_items":definition.issued_items.to_string()}));
            }
            ensure!(entries.len() <= 16_384, "NFT collection catalog exceeds mobile limit");
        }
        next = page.next;
        if next.is_none() {
            let (height, hash, root) = binding.context("NFT collection snapshot unavailable")?;
            return Ok(json!({"height":height,"block_hash":hex::encode(hash),
                "state_root":hex::encode(root),"items":entries,"complete":true}));
        }
    }
    anyhow::bail!("NFT collection pagination exceeds mobile limit")
}

/// Listings are read from the same verified native snapshot as holdings.
/// Reading is not preparation or authorization, and never contacts a server.
pub(crate) fn listings(artifacts: &Path, data_dir: &Path) -> Result<Value> {
    let database = data_dir.join("NativeState");
    ensure!(database.exists(), "Native State has not been installed on this phone");
    let store = MdbxStore::open(&database)?;
    let bundle = crate::courier_api::accepted_bundle(data_dir)?;
    let mut next = None;
    let mut binding = None;
    let mut entries = Vec::new();
    // One listing this reader can't decode must not hide every other listing (including the
    // owner's own). Display only: buying and managing a listing are checked again when prepared.
    let mut skipped: u64 = 0;
    for _ in 0..64 {
        let page = store.native_catalog_page(NativeCatalogKind::NftListings, next, 256)?;
        let identity = (page.height, page.tip_hash, page.state_root);
        if let Some(previous) = binding {
            ensure!(previous == identity, "NFT listings changed during pagination");
        } else {
            ensure!(page.height > 0, "NFT State is still at genesis");
            let header = crate::verifier_session::header(artifacts, &bundle, page.height)?;
            ensure!(block_id(&header) == page.tip_hash && header.state_root == page.state_root,
                "NFT listings are not on the verified mobile chain");
            binding = Some(identity);
        }
        for item in page.items {
            match (item.primary.opening, item.primary.dependency) {
                (NativeOpening::NftMarket(NftMarketOpening::Listing(_)),
                 Some(NativeOpening::NftMarket(NftMarketOpening::Definition(d)))) => {
                    entries.push(json!({"type":"listing","root":hex::encode(item.primary.root),
                        "collection_id":hex::encode(d.collection.0),"serial":d.serial.to_string(),
                        "seller":d.seller.to_string(),"ask_micronoid":d.ask.to_string(),
                        "expiry_height":d.expiry_height.to_string(),"metadata_hash":hex::encode(d.metadata)}));
                },
                _ => { skipped += 1; continue; },
            }
            ensure!(entries.len() <= 16_384, "NFT listings exceed mobile display limit");
        }
        next = page.next;
        if next.is_none() {
            let (height, hash, root) = binding.context("NFT listing snapshot unavailable")?;
            return Ok(json!({"height":height,"block_hash":hex::encode(hash),
                "state_root":hex::encode(root),"items":entries,"skipped":skipped,"complete":true}));
        }
    }
    anyhow::bail!("NFT listing pagination exceeds mobile limit")
}

pub(crate) fn install(
    verified: &crate::VerifiedState,
    header: BlockHeader,
    anchor: BlockHeader,
    bundle: &Path,
    manifest: &GetStateManifestResponse,
    staged: &FinalizedSnapshotStaging,
    database: &Path,
) -> Result<()> {
    ensure!(verified.height() == manifest.tip_height
        && verified.block_hash() == hex::encode(manifest.tip_hash)
        && verified.state_root() == hex::encode(manifest.state_root),
        "snapshot State is not bound to accepted mobile verification");
    ensure!(block_id(&header) == manifest.tip_hash, "snapshot boundary header changed");
    let terminal = crate::artifacts::read_bounded(&bundle.join("terminal.bin"), 1_100_000)?;
    let mut context = MdbxChainContext::open_or_create(database)?;
    let boundary = context.verify_snapshot_boundary(header, anchor, terminal.clone(), |claim| {
        if claim.terminal_bytes != terminal.as_slice() || claim.header != header || claim.epoch_anchor_header != anchor {
            return Err("HistoryStep input differs from independently verified bundle".into());
        }
        Ok(())
    })?;
    let mut headers = VerifiedFileHeaders::new(&context, bundle, manifest)?;
    context.apply_staged_state_snapshot(staged, &boundary, &mut headers, false)
        .context("atomic native State installation failed")?;
    Ok(())
}
