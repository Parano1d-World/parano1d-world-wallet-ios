//! Service prices are not proven executions. Bind their block context to the
//! independently verified local chain, without claiming price authentication.
#[path="../../Vendor/parano1d-sdk/crates/authorization/src/history.rs"]
mod schema;
use anyhow::{ensure,Context,Result};
use serde_json::{json,Value};
use std::{fs::File,path::Path};

fn decode(text:&str,asset:&str,maximum:u64)->Result<schema::History> {
    ensure!(text.len()<=schema::MAX_RESPONSE_BYTES,"History exceeds size limit");
    let history:schema::History=serde_json::from_str(text)?;
    let chain=hex::encode(noid_chain::state::native_assets::native_chain_id());
    history.validate(&chain,asset,maximum).map_err(anyhow::Error::msg)?;
    Ok(history)
}
pub fn run(request:&Value)->Result<Value> {
    let history=decode(request["history_json"].as_str().context("Missing history")?,request["asset"].as_str().context("Missing asset")?,request["maximum_height"].as_u64().context("Missing requested height")?)?;
    let bundle=paramo1d::courier_api::accepted_bundle(Path::new(request["data_dir"].as_str().context("Missing device state")?))?;
    let state=paramo1d::verify_bundle(Path::new(request["artifacts"].as_str().context("Missing verification parameters")?),&bundle,paramo1d::MatrixMode::Streaming)?;
    ensure!(history.through.height<=state.height(),"History is ahead of verified state");
    let mut headers=File::open(bundle.join("headers.bin"))?;
    let tip=paramo1d::headers::read_header(&mut headers,state.height())?;
    ensure!(hex::encode(noid_chain::block_header::block_id(&tip))==state.block_hash().to_string(),"Verified boundary changed");
    for header in history.blocks.iter().map(|block|&block.header).chain(std::iter::once(&history.through)) {
        let local=paramo1d::headers::read_header(&mut headers,header.height)?;
        ensure!(hex::encode(noid_chain::block_header::block_id(&local))==header.hash && hex::encode(local.prev_block_hash)==header.prev_hash && local.timestamp==header.timestamp,"History block is not in verified chain");
    }
    let candles:Vec<Value>=history.blocks.iter().filter_map(|block|block.candle.as_ref().map(|c|json!({"height":block.header.height.to_string(),"open":c.open.value(),"high":c.high.value(),"low":c.low.value(),"close":c.close.value(),"trades":c.trades}))).collect();
    Ok(json!({"asset":history.asset,"through_height":history.through.height.to_string(),"through_hash":history.through.hash,"first_height":history.blocks.first().map(|b|b.header.height.to_string()),"block_count":history.blocks.len(),"candles":candles,"headers_verified":true,"prices_verified":false}))
}
#[cfg(test)]mod tests {
    use super::*;
    #[test]fn history_identity_size_and_candle_ranges_fail_closed(){
        let asset="a".repeat(64);let chain=hex::encode(noid_chain::state::native_assets::native_chain_id());
        let header=json!({"height":1,"hash":"b".repeat(64),"prev_hash":"c".repeat(64),"timestamp":1});
        let mut value=json!({"schema":1,"chain":chain,"asset":asset,"through":header,"blocks":[]});
        assert!(decode(&value.to_string(),&asset,1).is_ok());
        assert!(decode(&value.to_string(),&"d".repeat(64),1).is_err());
        assert!(decode(&value.to_string(),&asset,0).is_err());
        assert!(decode(&" ".repeat(schema::MAX_RESPONSE_BYTES+1),&asset,1).is_err());
        value["blocks"]=json!([{"header":header,"candle":{"open":{"noid":2,"tokens":1},"high":{"noid":1,"tokens":1},"low":{"noid":1,"tokens":1},"close":{"noid":1,"tokens":1},"trades":1}}]);
        assert!(decode(&value.to_string(),&asset,1).is_err());
    }
}
