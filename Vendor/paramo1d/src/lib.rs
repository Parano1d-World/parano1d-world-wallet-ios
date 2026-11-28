pub mod api;
pub mod artifacts;
pub mod collector;
pub mod courier_api;
pub mod headers;
pub mod matrix_store;
pub mod mobile;
mod mobile_state;
mod mobile_control;
mod mobile_wallet;
mod network_route;
mod peer_wallet;
mod peer_wallet_view;
mod qr;
pub mod rpc;
mod verifier_session;
pub mod verify;
mod wallet_checkpoint;

pub use artifacts::MatrixMode;
pub use verify::{verify_bundle, VerifiedState, Verifier};

pub fn ensure_verification_hardware() -> anyhow::Result<()> {
    #[cfg(all(target_os = "android", target_arch = "aarch64"))]
    {
        // Read the OS capabilities even when target-feature makes Rust's
        // feature-detection macros assume the static compilation contract.
        unsafe extern "C" {
            fn getauxval(kind: usize) -> usize;
        }
        const REQUIRED: usize = (1 << 1) | (1 << 3) | (1 << 4);
        let capabilities = unsafe { getauxval(16) };
        anyhow::ensure!(
            capabilities & REQUIRED == REQUIRED,
            "This device needs ARM NEON, AES and PMULL for Paramo1d verification"
        );
    }
    noid_core::cpu::ensure_production_hardware()?;
    Ok(())
}

pub fn available_workers() -> usize {
    std::thread::available_parallelism().map_or(1, usize::from)
}

pub fn resolve_workers(requested: Option<usize>) -> anyhow::Result<usize> {
    let available = available_workers();
    let workers = requested.unwrap_or(available);
    anyhow::ensure!(
        workers > 0 && workers <= available,
        "verification worker count must be 1 through {available}"
    );
    Ok(workers)
}

/// iOS: direct submission of identical signed bytes to mainnet peers
/// (upstream's Paranoid-mode broadcast). A peer delivery is a relay hint only.
pub fn peer_broadcast(artifact_directory: &std::path::Path, intent: Vec<u8>, txid: &str) -> anyhow::Result<serde_json::Value> {
    let args = serde_json::json!({"artifacts": artifact_directory.to_string_lossy()});
    peer_wallet::broadcast(&args, intent, txid)
}

/// iOS: pending-transaction claims and an estimated relay fee floor from peers.
pub fn peer_mempool_snapshot(artifact_directory: &std::path::Path) -> anyhow::Result<serde_json::Value> {
    let args = serde_json::json!({"artifacts": artifact_directory.to_string_lossy()});
    peer_wallet::mempool_snapshot(&args)
}

/// iOS Paranoid mode: the wallet's slots and the header they were proven at,
/// fetched and verified over mainnet P2P with zero RPC (upstream `fetch_wallet`).
/// `args` needs `artifacts` and `data_dir`; runs a device node sync first.
pub fn peer_wallet_slots(
    args: &serde_json::Value,
    address: noid_poseidon2b::primitives::Address,
) -> anyhow::Result<(noid_chain::BlockHeader, std::collections::BTreeMap<u32, noid_chain::fri_state::SlotValue>)> {
    peer_wallet::with_policy(true, || {
        let view = peer_wallet::fetch_wallet(args, address)?;
        Ok((view.header, view.slots))
    })
}
