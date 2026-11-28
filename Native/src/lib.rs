//! Native authorization adapter; device and live integration acceptance remains pending.
//! Caller supplies trusted chain and parent, original request, reviewed fee cap.
//! Never pass page-provided expectations directly into this API.
use std::ffi::{c_char, CString};
use parano1d_authorization::{native::NativeOperationPlan, prepare, prove_job};
use noid_poseidon2b::primitives::{SpendSecret, derive_address};
use serde_json::{json, Value};
use sha3::{Digest, Sha3_256};
use zeroize::{Zeroizing, Zeroize};
use noid_core::Block128;
use noid_poseidon2b::native::compression::Poseidon2bSponge;
mod messaging;
mod payment_journal;
mod payment;

const LIMIT: usize = 9 * 1024 * 1024;
// Matches desktop MasterSecret and Paramo1d derivation at address index 0.
fn derive_secret(master: &[u8;32], index: u32) -> SpendSecret {
    let mut fields=Zeroizing::new([
        Block128(u128::from_le_bytes(master[..16].try_into().unwrap())),
        Block128(u128::from_le_bytes(master[16..].try_into().unwrap()))]);
    let mut sponge=Poseidon2bSponge::with_iv([Block128(0);2]);
    sponge.absorb(fields[0]); sponge.absorb(fields[1]); fields.zeroize();
    sponge.absorb(Block128(index as u128));
    sponge.absorb(Block128(0x6E6F69642D64657269));
    let mut digest=Zeroizing::new(sponge.finalize());
    let key=SpendSecret::from_bytes(*digest); digest.zeroize(); key
}
fn review(plan: &NativeOperationPlan) -> Result<(Value,String),String> {
    let value=plan.review()?;
    let encoded=serde_json::to_vec(&value).map_err(|e|e.to_string())?;
    Ok((value,hex::encode(Sha3_256::digest(encoded))))
}
fn run(input: &[u8], secret: Option<&[u8]>) -> Result<Value,String> {
    let request: Value=serde_json::from_slice(input).map_err(|_|"Invalid JSON")?;
    let limit=if matches!(request["op"].as_str(),Some("chat_open"|"chat_open_archived"|"chat_open_saved"|"chat_inspect")){paramo1d_courier::MAX_ENVELOPE+8192}else{768*1024};
    if request["op"] != "inspect_image" && input.len() > limit { return Err("Native request too large".into()); }
    match request["op"].as_str() {
        Some("payment_inspect")=>payment::inspect_signed(request["intent_hex"].as_str().ok_or("Missing payment intent")?),
        Some("payment_review"|"payment_authorize")=>payment::run(&request,secret),
        Some("payment_cancel_preparing")=>{
            let directory=request["journal_directory"].as_str().ok_or("Missing payment storage")?;
            let mut journal=payment_journal::Journal::open(std::path::Path::new(directory))?;
            journal.cancel_preparing(request["txid"].as_str().ok_or("Missing preparation identity")?)?;
            Ok(json!({"cancelled":true}))
        },
        Some("payment_pending")=>{
            let directory=request["journal_directory"].as_str().ok_or("Missing payment storage")?;
            let journal=payment_journal::Journal::open(std::path::Path::new(directory))?;
            // "pending" keeps the oldest unsettled entry (or the latest settled one) for
            // older screens; "entries" lists every entry, unsettled first.
            let mut entries=journal.unresolved_entries();
            entries.extend(journal.entries().into_iter().filter(|e|!matches!(e["state"].as_str(),Some("preparing"|"authorized"))).rev());
            Ok(json!({"pending":journal.current(),"entries":entries}))
        },
        Some("app_lock_hash"|"app_lock_check") => {
            use subtle::ConstantTimeEq;
            let code=request["code"].as_str().ok_or("Missing app code")?;
            if code.len()<4 || code.len()>512 {return Err("Invalid app code length".into());}
            let salt=hex::decode(request["salt"].as_str().ok_or("Missing salt")?).map_err(|_|"Invalid salt")?;
            if salt.len()!=32 {return Err("Invalid salt length".into());}
            let params=argon2::Params::new(19456,2,1,Some(32)).map_err(|_|"Invalid lock parameters")?;
            let kdf=argon2::Argon2::new(argon2::Algorithm::Argon2id,argon2::Version::V0x13,params);
            let mut derived=Zeroizing::new([0u8;32]);
            kdf.hash_password_into(code.as_bytes(),&salt,&mut *derived).map_err(|_|"App lock derivation failed")?;
            if request["op"]=="app_lock_hash" {return Ok(json!({"digest":hex::encode(&*derived)}));}
            let expected=hex::decode(request["digest"].as_str().ok_or("Missing verifier")?).map_err(|_|"Invalid verifier")?;
            if expected.len()!=32 {return Err("Invalid verifier length".into());}
            Ok(json!({"matches":bool::from(derived.as_slice().ct_eq(&expected))}))
        },
        Some("chat_profile"|"chat_contact"|"chat_inspect"|"chat_group_open"|"chat_group_seal"|"chat_seal"|"chat_seal_invoice"|"chat_seal_payment"|"chat_seal_receipt"|"chat_open"|"chat_open_archived"|"chat_open_saved"|"chat_inbox_auth"|"chat_push_auth") => messaging::run(&request,secret),
        Some("inspect_metadata") => {
            let manifest: parano1d_authorization::media::Manifest=serde_json::from_value(request["manifest"].clone()).map_err(|_|"Invalid metadata")?;
            if manifest.hash()? != request["expected_hash"].as_str().ok_or("Missing metadata hash")? { return Err("Metadata hash mismatch".into()); }
            serde_json::to_value(manifest).map_err(|e|e.to_string())
        }
        Some("inspect_image") => {
            let bytes=hex::decode(request["bytes_hex"].as_str().ok_or("Missing image")?).map_err(|_|"Invalid image bytes")?;
            if bytes.len()>4*1024*1024 { return Err("Image too large".into()); }
            if parano1d_authorization::media::image_hash(&bytes) != request["expected_hash"].as_str().ok_or("Missing image hash")? { return Err("Image hash mismatch".into()); }
            Ok(json!({"verified":true}))
        }
        Some("inspect_items") => Ok(json!({"items":parano1d_authorization::native::view::inspect_items(&request["page"])?})),
        Some("inspect_holdings") => {
            let values=request["holdings"].as_array().ok_or("Missing holdings")?;
            if values.len()>256 { return Err("Too many holdings".into()); }
            let inspected=values.iter().map(parano1d_authorization::native::view::inspect_holding).collect::<Result<Vec<_>,_>>()?;
            Ok(json!({"items":inspected}))
        },
        Some("recover_key"|"check_key") => {
            let key=request["key_hex"].as_str().ok_or("Missing master key")?;
            if key.len()!=64 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err("Enter exactly 64 hexadecimal characters from the Parano1d master key".into());
            }
            let decoded=Zeroizing::new(hex::decode(key).map_err(|_|"Invalid master key")?);
            let master=Zeroizing::new(<[u8;32]>::try_from(decoded.as_slice()).map_err(|_|"Invalid master key length")?);
            if request["op"]=="check_key" {
                use subtle::ConstantTimeEq;
                let existing=secret.ok_or("Missing stored master key")?;
                return if bool::from(existing.ct_eq(&master[..])) { Ok(json!({"verified":true})) }
                       else { Err("Key does not recover this wallet".into()) };
            }
            Ok(json!({"master_hex":hex::encode(&*master),"address":derive_address(&derive_secret(&master,0)).to_bech32(),"scheme":"parano1d-master-entropy-v1"}))
        }
        Some("address") => {
            let bytes=Zeroizing::new(<[u8;32]>::try_from(secret.ok_or("Missing secret")?).map_err(|_|"Secret length")?);
            let index=request.get("account_index").map(|v|v.as_u64().filter(|n|*n<=100000).ok_or("Invalid account index")).transpose()?.unwrap_or(0) as u32;
            let key=derive_secret(&bytes, index);
            Ok(json!({"address":derive_address(&key).to_bech32()}))
        }
        Some("review") | Some("authorize") => {
            let plan: NativeOperationPlan=serde_json::from_value(request["operation"].clone()).map_err(|_|"Invalid operation plan")?;
            let (value, digest)=review(&plan)?;
            if request["op"] == "review" { return Ok(json!({"review":value,"review_hash":digest})); }
            if request["approved_review_hash"].as_str()!=Some(digest.as_str()) { return Err("Approval does not match canonical review".into()); }
            let bytes=Zeroizing::new(<[u8;32]>::try_from(secret.ok_or("Missing secret")?).map_err(|_|"Secret length")?);
            let index=request.get("account_index").map(|v|v.as_u64().filter(|n|*n<=100000).ok_or("Invalid account index")).transpose()?.unwrap_or(0) as u32;
            let key=derive_secret(&bytes, index);
            if derive_address(&key).to_bech32()!=plan.native_plan.owner { return Err("Wallet owner mismatch".into()); }
            // Callers must create this protected app directory before approval.
            // Hold the process/file lock through proving and durable persistence.
            let directory=request["journal_directory"].as_str().ok_or("Protected pending-payment storage is required")?;
            let mut journal=payment_journal::Journal::open(std::path::Path::new(directory))?;
            // Reserve exactly the slots this token/NFT transaction uses, so other payments can
            // proceed in parallel; unreadable intents reserve everything until signed.
            let claims=hex::decode(&plan.native_plan.unsigned_intent_hex).ok()
                .and_then(|bytes|payment_journal::intent_claims(&bytes).ok()).unwrap_or(json!({"exclusive":true}));
            if let Some(intent)=journal.begin_claims(&digest,&plan.native_plan.intent_id,&plan.expected_chain,&plan.native_plan.owner,claims)? {
                return Ok(json!({"intent_hex":intent,"txid":plan.native_plan.intent_id,"resumed":true}));
            }
            let txid=plan.native_plan.intent_id.clone();
            journal.note_native_review(&txid,&value)?;
            let (job,pending)=prepare(&key)?.begin(parano1d_authorization::WalletOperation::Native(plan))?;
            let job=Zeroizing::new(job);
            let response=Zeroizing::new(prove_job(&job)?);
            // SDK verifies the completed capsule before encoding the intent.
            let intent=pending.finish(&response)?;
            journal.authorized_kind(&intent,"native")?;
            Ok(json!({"intent_hex":hex::encode(intent),"txid":txid,"resumed":false}))
        }
        _ => Err("Unsupported native operation".into())
    }
}
/// Input points to length readable bytes; optional secret points to exactly 32 bytes.
/// All outputs must be freed through paranoid_ios_free. Serialize calls off main thread.
#[no_mangle]
pub unsafe extern "C" fn paranoid_ios_call(input:*const u8,length:usize,secret:*const u8,secret_length:usize)->*mut c_char {
    let result:Result<Value,String>=if input.is_null() || length>LIMIT || !(secret_length==0 || secret_length==32) || (secret_length>0 && secret.is_null()) {
        Err("Invalid native input".into())
    } else {
        let bytes=unsafe { std::slice::from_raw_parts(input,length) }.to_vec();
        let key=if secret_length==32 { Some(Zeroizing::new(unsafe { std::slice::from_raw_parts(secret,32) }.to_vec())) } else { None };
        // Runs on its own 32 MB-stack thread: a stack overflow on Swift's ~512 KB
        // background threads would end the app instead of returning an error.
        std::thread::Builder::new().name("paranoid-core".into()).stack_size(32*1024*1024)
            .spawn(move||std::panic::catch_unwind(||run(&bytes,key.as_ref().map(|v|v.as_slice())))
                .unwrap_or_else(|_|Err("Native operation failed".into())))
            .ok().and_then(|worker|worker.join().ok())
            .unwrap_or_else(||Err("Native operation failed".into()))
    };
    let value=match result { Ok(v)=>json!({"result":v}), Err(e)=>json!({"error":e}) };
    CString::new(value.to_string()).unwrap().into_raw()
}
/// Must be a live pointer returned by paranoid_ios_call; free exactly once.
#[no_mangle]
pub unsafe extern "C" fn paranoid_ios_free(value:*mut c_char) { if !value.is_null() { let bytes=unsafe { CString::from_raw(value) }.into_bytes_with_nul(); drop(Zeroizing::new(bytes)); } }

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn local_app_code_is_salted_and_rejects_wrong_code() {
        let salt="07".repeat(32);
        let hashed=run(serde_json::to_vec(&json!({"op":"app_lock_hash","code":"873920","salt":salt})).unwrap().as_slice(),None).unwrap();
        for (code,matches) in [("873920",true),("873921",false)] {
            let request=json!({"op":"app_lock_check","code":code,"salt":salt,"digest":hashed["digest"]});
            assert_eq!(run(&serde_json::to_vec(&request).unwrap(),None).unwrap()["matches"],matches);
        }
        let other=run(&serde_json::to_vec(&json!({"op":"app_lock_hash","code":"873920","salt":"08".repeat(32)})).unwrap(),None).unwrap();
        assert_ne!(hashed,other);
        assert!(run(br#"{"op":"app_lock_hash","code":"873920","salt":"00"}"#,None).is_err());
    }
    #[test] fn accounts_are_distinct_and_reproducible() {
        let master=[7;32];
        let a=run(br#"{"op":"address","account_index":0}"#,Some(&master)).unwrap();
        let b=run(br#"{"op":"address","account_index":1}"#,Some(&master)).unwrap();
        assert_ne!(a,b);
        assert_eq!(b,run(br#"{"op":"address","account_index":1}"#,Some(&master)).unwrap());
        assert!(run(br#"{"op":"address","account_index":-1}"#,Some(&master)).is_err());
        assert!(run(br#"{"op":"address","account_index":100001}"#,Some(&master)).is_err());
    }
    #[test] fn desktop_master_key_recovers_same_wallet() {
        let master=[7;32];
        let key=hex::encode(master);
        let recovered=run(json!({"op":"recover_key","key_hex":key.to_uppercase()}).to_string().as_bytes(),None).unwrap();
        assert_eq!(recovered["master_hex"],key);
        assert_eq!(recovered["address"],"o1lhhsuqy5d35c3zarhnuj7kpywrke5wwsr8ukc6x8y4dvhe38vs2qzg2759");
        assert_eq!(run(json!({"op":"check_key","key_hex":key}).to_string().as_bytes(),Some(&master)).unwrap()["verified"],true);
        assert!(run(json!({"op":"check_key","key_hex":key}).to_string().as_bytes(),Some(&[9;32])).is_err());
        assert_eq!(recovered["address"],run(br#"{"op":"address"}"#,Some(&master)).unwrap()["address"]);
        for bad in ["07".repeat(31),"0g".repeat(32),"00".repeat(33)] {
            assert!(run(json!({"op":"recover_key","key_hex":bad}).to_string().as_bytes(),None).is_err());
        }
    }
    #[test] fn recovery_derives_same_address() {
        let key=[7;32];
        let a=derive_address(&derive_secret(&key,0)).to_bech32();
        assert_eq!(a,"o1lhhsuqy5d35c3zarhnuj7kpywrke5wwsr8ukc6x8y4dvhe38vs2qzg2759");
        assert_ne!(a,derive_address(&derive_secret(&key,1)).to_bech32());
        // Fixed fixture checked against upstream's documented derivation sequence.

    }
    #[test] fn refuses_unknown_operation() { assert!(run(br#"{"op":"exportSecret"}"#,None).is_err()); }
    #[test] fn refuses_missing_key() { assert!(run(br#"{"op":"address"}"#,None).is_err()); }
    #[test] fn refuses_unbound_plan() { assert!(run(br#"{"op":"authorize","operation":{}}"#,Some(&[1;32])).is_err()); }
    #[test] fn ffi_rejects_invalid_secret_length_without_reading_it() {
        let input=br#"{"op":"address"}"#;
        let output=unsafe{paranoid_ios_call(input.as_ptr(),input.len(),std::ptr::null(),31)};
        let value:Value=serde_json::from_slice(unsafe{std::ffi::CStr::from_ptr(output)}.to_bytes()).unwrap();
        assert_eq!(value["error"],"Invalid native input");
        unsafe{paranoid_ios_free(output)};
    }
    #[test] fn image_hash_tampering_is_rejected() {
        let bytes=b"public test fixture";
        let hash=parano1d_authorization::media::image_hash(bytes);
        let request=json!({"op":"inspect_image","bytes_hex":hex::encode(bytes),"expected_hash":hash});
        assert!(run(request.to_string().as_bytes(),None).is_ok());
        let mut altered=request;altered["bytes_hex"]=json!(hex::encode(b"modified test fixture"));
        assert!(run(altered.to_string().as_bytes(),None).is_err());
    }
    #[test] fn metadata_name_cannot_change_under_same_commitment() {
        let manifest:parano1d_authorization::media::Manifest=serde_json::from_value(json!({"schema":1,"kind":"collection","name":"Public fixture"})).unwrap();
        let hash=manifest.hash().unwrap();
        let mut request=json!({"op":"inspect_metadata","manifest":manifest,"expected_hash":hash});
        assert!(run(request.to_string().as_bytes(),None).is_ok());
        request["manifest"]["name"]=json!("Impersonated collection");
        assert!(run(request.to_string().as_bytes(),None).is_err());
    }
}
