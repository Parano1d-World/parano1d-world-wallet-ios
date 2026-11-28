use std::collections::{BTreeMap,HashSet};
use noid_chain::consensus::allocator::{generate_zone_segment_hints,splitmix64};
use noid_chain::consensus::pow::block_id;
use noid_chain::storage::MdbxChainContext;
const WALLET_SEGMENT_HEADROOM_DIVISOR:u32=16;
pub(crate) fn collect_empty_slot_hints(
    chain: &MdbxChainContext,
    reserved: &HashSet<u32>,
    seed: u64,
    count: usize,
) -> Result<Vec<u32>, String> {
    if count == 0 {
        return Ok(Vec::new());
    }
    let state = &chain.state.state;
    let segment_log = state.effective_log_segment_size();
    let segment_size = 1usize << segment_log;
    let segment_full = segment_size as u32;
    let local_mask = (segment_size - 1) as u32;
    let mut rng = seed;
    let mut hints = Vec::with_capacity(count);

    // Refill durable live segments with enough free slots for independent
    // wallets to choose different outputs. Near-full segments are deferred:
    // their few holes otherwise turn concurrent sends into frequent conflicts.
    // Salt still rotates equal-density choices and the local scan.
    let mut partial_segments = (0..state.num_segments())
        .map(|segment| segment as u16)
        .filter(|segment| {
            let live = state.segment_live_count(*segment);
            live > 0 && live < segment_full
        })
        .collect::<Vec<_>>();
    if !partial_segments.is_empty() {
        let rotation = (splitmix64(&mut rng) as usize) % partial_segments.len();
        partial_segments.rotate_left(rotation);
        // Stable ordering fills the densest segment first; the prior rotation
        // supplies deterministic salt diversity between equal live counts.
        partial_segments.sort_by(|left, right| {
            state
                .segment_live_count(*right)
                .cmp(&state.segment_live_count(*left))
        });
    }

    let minimum_headroom =
        (segment_full / WALLET_SEGMENT_HEADROOM_DIVISOR).max(count.min(segment_size) as u32);
    let mut scarce_segments = Vec::new();
    partial_segments.retain(|segment_id| {
        if segment_full - state.segment_live_count(*segment_id) < minimum_headroom {
            scarce_segments.push(*segment_id);
            false
        } else {
            true
        }
    });

    let scan_live_segment = |hints: Vec<u32>, segment_id: u16, rng: &mut u64| {
        let local_start = (splitmix64(rng) as u32) & local_mask;
        let base = u32::from(segment_id) << segment_log;
        let candidates = (0..segment_size)
            .map(move |step| base | (local_start.wrapping_add(step as u32) & local_mask));
        collect_empty_slot_hints_streaming(
            hints,
            reserved,
            count,
            state.num_slots(),
            segment_log,
            candidates,
            |candidate_segment| state.is_evicted(candidate_segment),
            |index| state.slot(index) == noid_chain::fri_state::SlotValue::EMPTY,
            |candidate_segment| load_durable_segment(chain, candidate_segment, segment_log),
        )
    };

    for &segment_id in &partial_segments {
        hints = scan_live_segment(hints, segment_id, &mut rng)?;
        if hints.len() == count {
            return Ok(hints);
        }
    }

    // Open a virtual-zero segment before reusing a scarce hole. This may add
    // one segment, but avoids making every wallet race for the same last slot.
    // The allocator's zone order comes from the monotone alloc_counter.
    for segment_id in generate_zone_segment_hints(
        chain.state.alloc_counter,
        state.log_slots() as u32,
        state.num_segments(),
    ) {
        if state.segment_live_count(segment_id) != 0 || state.is_evicted(segment_id) {
            continue;
        }
        let local_start = (splitmix64(&mut rng) as u32) & local_mask;
        let base = u32::from(segment_id) << segment_log;
        // Every candidate is empty, so `reserved + missing` probes guarantee
        // enough unreserved hints without constructing a 65,536-entry list.
        let missing = count.saturating_sub(hints.len());
        let probes = segment_size.min(reserved.len().saturating_add(missing));
        let candidates = (0..probes)
            .map(move |step| base | (local_start.wrapping_add(step as u32) & local_mask));
        hints = collect_empty_slot_hints_streaming(
            hints,
            reserved,
            count,
            state.num_slots(),
            segment_log,
            candidates,
            |_| false,
            |index| state.slot(index) == noid_chain::fri_state::SlotValue::EMPTY,
            |_| -> Result<noid_chain::segmented_state::SegmentColumns, String> {
                unreachable!("virtual-zero segment cannot require a durable load")
            },
        )?;
        if hints.len() == count {
            return Ok(hints);
        }
    }

    // A full domain still permits the last holes to be used safely. Exact
    // slot reads and mempool admission continue to reject stale choices.
    for segment_id in scarce_segments {
        hints = scan_live_segment(hints, segment_id, &mut rng)?;
        if hints.len() == count {
            break;
        }
    }
    Ok(hints)
}

fn load_durable_segment(
    chain: &MdbxChainContext,
    segment_id: u16,
    expected_log: usize,
) -> Result<noid_chain::segmented_state::SegmentColumns, String> {
    let Some((stored_log, columns)) = chain
        .store
        .get_segment(segment_id)
        .map_err(|error| error.to_string())?
    else {
        return Err(format!(
            "evicted segment {segment_id} is missing from durable state"
        ));
    };
    if usize::from(stored_log) != expected_log {
        return Err(format!(
            "segment {segment_id} depth mismatch: stored {stored_log}, expected {expected_log}"
        ));
    }
    Ok(columns)
}

trait ExactSegmentSlots {
    fn slot_is_empty(&self, segment_id: u16, local_index: usize) -> Result<bool, String>;
}

impl ExactSegmentSlots for noid_chain::segmented_state::SegmentColumns {
    fn slot_is_empty(&self, segment_id: u16, local_index: usize) -> Result<bool, String> {
        if local_index >= self.values.len()
            || local_index >= self.owners_hi.len()
            || local_index >= self.owners_lo.len()
        {
            return Err(format!(
                "segment {segment_id} is too short for local slot {local_index}"
            ));
        }
        Ok(noid_chain::fri_state::SlotValue {
            value: self.values[local_index],
            owner_hi: self.owners_hi[local_index],
            owner_lo: self.owners_lo[local_index],
        } == noid_chain::fri_state::SlotValue::EMPTY)
    }
}

struct SlotHintCandidate {
    index: u32,
    evicted_segment: Option<u16>,
    is_empty: Option<Result<bool, String>>,
}

/// Resolve fallback candidates in their original rank order while loading at
/// most one durable segment payload at a time.
///
/// Candidate positions are grouped by segment, but the segment containing the
/// earliest unresolved rank is always loaded next.  All later positions in
/// that segment are resolved before its payload is dropped.  This retains the
/// old sequential short-circuit and error semantics without retaining a
/// `SegmentColumns` cache proportional to the candidate spread.
#[allow(clippy::too_many_arguments)]
fn collect_empty_slot_hints_streaming<S, I, IsEvicted, ReadResident, LoadSegment>(
    mut hints: Vec<u32>,
    reserved: &HashSet<u32>,
    count: usize,
    num_slots: u64,
    segment_log: usize,
    candidate_indices: I,
    mut is_evicted: IsEvicted,
    mut read_resident: ReadResident,
    mut load_segment: LoadSegment,
) -> Result<Vec<u32>, String>
where
    S: ExactSegmentSlots,
    I: IntoIterator<Item = u32>,
    IsEvicted: FnMut(u16) -> bool,
    ReadResident: FnMut(u32) -> bool,
    LoadSegment: FnMut(u16) -> Result<S, String>,
{
    if hints.len() >= count {
        return Ok(hints);
    }

    let local_mask = (1u32 << segment_log) - 1;
    let mut seen = reserved.clone();
    seen.extend(hints.iter().copied());
    let mut candidates = Vec::new();
    let mut positions_by_segment = BTreeMap::<u16, Vec<usize>>::new();

    for index in candidate_indices {
        if u64::from(index) >= num_slots || !seen.insert(index) {
            continue;
        }
        let segment_id = (index >> segment_log) as u16;
        let position = candidates.len();
        if is_evicted(segment_id) {
            positions_by_segment
                .entry(segment_id)
                .or_default()
                .push(position);
            candidates.push(SlotHintCandidate {
                index,
                evicted_segment: Some(segment_id),
                is_empty: None,
            });
        } else {
            candidates.push(SlotHintCandidate {
                index,
                evicted_segment: None,
                is_empty: Some(Ok(read_resident(index))),
            });
        }
    }

    let mut cursor = 0usize;
    while cursor < candidates.len() {
        while cursor < candidates.len() {
            let Some(is_empty) = candidates[cursor].is_empty.take() else {
                break;
            };
            if is_empty? {
                hints.push(candidates[cursor].index);
                if hints.len() == count {
                    return Ok(hints);
                }
            }
            cursor += 1;
        }
        if cursor == candidates.len() {
            break;
        }

        let segment_id = candidates[cursor]
            .evicted_segment
            .expect("only an evicted candidate can be unresolved");
        let positions = positions_by_segment
            .remove(&segment_id)
            .expect("every evicted segment has candidate positions");

        // The payload is intentionally scoped to this block. It is dropped
        // before another segment can be loaded.
        {
            let segment = load_segment(segment_id)?;
            for position in positions {
                let local_index = (candidates[position].index & local_mask) as usize;
                candidates[position].is_empty =
                    Some(segment.slot_is_empty(segment_id, local_index));
            }
        }
    }
    Ok(hints)
}

/// Resolve the sole user-transaction anchor accepted in the next child block.
/// Durable lookup is required because it can be 144 blocks behind the tip.
pub fn next_user_epoch_anchor(chain: &MdbxChainContext) -> Result<[u8; 32], String> {
    let child_height = chain
        .tip_height
        .checked_add(1)
        .ok_or_else(|| "child height overflow".to_string())?;
    let anchor_height = noid_chain::consensus::tx_epoch_anchor_height_for_child(child_height);
    let header = chain
        .get_header_from_store(anchor_height)
        .map_err(|error| format!("load transaction epoch anchor: {error}"))?
        .ok_or_else(|| "canonical transaction epoch anchor header is missing".to_string())?;
    Ok(block_id(&header))
}

