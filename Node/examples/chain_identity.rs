fn main() {
    let header = noid_chain::consensus::genesis::genesis_header();
    println!("{}", hex::encode(header.to_bytes()));
    println!("{}", hex::encode(noid_chain::state::native_assets::native_chain_id()));
}
