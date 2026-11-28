//! Direct text, public community text and saved payment packets use the pinned
//! upstream Courier format unchanged. No payment execution or secret JSON export.
use paramo1d_courier::{Contact,Destination,Envelope,Identity,Message};
use serde_json::{json,Value};
use zeroize::Zeroizing;

pub fn run(request:&Value,secret:Option<&[u8]>)->Result<Value,String> {
    execute(request,secret).map_err(|e|e.to_string())
}
fn execute(request:&Value,secret:Option<&[u8]>)->Result<Value,Box<dyn std::error::Error>> {
    let op=request["op"].as_str().ok_or("Missing operation")?;
    if op=="chat_contact" {
        let uri=request["uri"].as_str().ok_or("Missing contact invitation")?;
        if uri.len()>4096 {return Err("Contact invitation too large".into());}
        return Ok(json!({"contact":paramo1d_courier::import_contact(uri)?}));
    }
    if op=="chat_inspect" {
        // Public validation for untrusted transports. Never decrypt or execute here.
        if serde_json::to_vec(&request["envelope"])?.len()>paramo1d_courier::MAX_ENVELOPE {return Err("Packet too large".into());}
        let envelope:Envelope=serde_json::from_value(request["envelope"].clone())?;
        envelope.verify(request["now_ms"].as_u64().ok_or("Missing clock")?)?;
        let Destination::Direct{contact}= &envelope.data.destination else {return Err("Only direct packets may be carried".into());};
        if envelope.is_plain_direct() {return Err("Unencrypted direct messages are not supported".into());}
        return Ok(json!({"id":envelope.id,"sender":envelope.data.sender,"recipient":contact,"expires_ms":envelope.data.expires_ms}));
    }
    if op=="chat_group_open" {
        let envelope:Envelope=serde_json::from_value(request["envelope"].clone())?;
        envelope.verify(request["now_ms"].as_u64().ok_or("Missing clock")?)?;
        let Destination::Group{room}= &envelope.data.destination else {return Err("Not a community message".into());};
        if room!=paramo1d_courier::LOBBY {return Err("Unknown community channel".into());}
        let public=envelope.public_message()?.ok_or("Not a community packet")?;
        let (text,update)=match public {
            Message::Text{text}=>(Some(text),Value::Null),
            Message::RelayUpdate{txid,stage,receipt_hex}=>(None,json!({"txid":txid,"claimed_stage":stage,"receipt_hex":receipt_hex,"verified":false})),
            _=>(None,Value::Null),
        };
        return Ok(json!({"id":envelope.id,"sender":envelope.data.sender,"text":text,"relay_update":update,"created_ms":envelope.data.created_ms}));
    }
    let seed=Zeroizing::new(<[u8;32]>::try_from(secret.ok_or("Missing local wallet secret")?)?);
    let identity=Identity::from_seed(&seed);
    if op=="chat_profile" {
        let name=request["name"].as_str().ok_or("Missing name")?;
        let address=crate::derive_address(&crate::derive_secret(&seed,0)).to_bech32();
        let contact=identity.contact(name.to_owned(),address)?;
        return Ok(json!({"invite":identity.invite(&contact)?,"contact":contact}));
    }
    let now=request["now_ms"].as_u64().ok_or("Missing clock")?;
    match op {
        "chat_inbox_auth"=>{
            let after=request["after"].as_u64().ok_or("Invalid inbox cursor")?;
            let limit=match request.get("limit") {None=>30,Some(value)=>value.as_u64().filter(|n|(1..=30).contains(n)).ok_or("Invalid inbox page limit")?};
            let own=identity.contact("Local".into(),String::new())?;
            // The host cannot ask this operation to sign an arbitrary relay path.
            let path=format!("/v1/inbox/{}?after={after}&limit={limit}",own.id);
            Ok(json!({"path":path,"signature":identity.read_authorization(&path,now),"time_ms":now.to_string(),"limit":limit}))
        },
        "chat_push_auth"=>{
            // Instant-alert service: signs only /v1/push/register/<sha256 of this device's push token>
            // or /v1/push/ping/<recipient chat identity>. Never an inbox or relay path.
            let target=request["target"].as_str().ok_or("Missing push target")?;
            if target.len()!=64 || !target.bytes().all(|v|matches!(v,b'0'..=b'9'|b'a'..=b'f')) {return Err("Invalid push target".into());}
            let path=match request["purpose"].as_str() {
                Some("register")=>format!("/v1/push/register/{target}"),
                Some("unregister")=>format!("/v1/push/unregister/{target}"),
                Some("ping")=>format!("/v1/push/ping/{target}"),
                _=>return Err("Invalid push purpose".into()),
            };
            let own=identity.contact("Local".into(),String::new())?;
            Ok(json!({"id":own.id,"path":path,"signature":identity.read_authorization(&path,now),"time_ms":now.to_string()}))
        },
        "chat_seal_receipt"=>{
            let sender:Contact=serde_json::from_value(request["sender"].clone())?;
            let contact:Contact=serde_json::from_value(request["contact"].clone())?;
            let txid=request["txid"].as_str().ok_or("Missing transaction ID")?.to_owned();
            let receipt_hex=request["receipt_hex"].as_str().ok_or("Missing receipt")?.to_owned();
            let envelope=identity.seal(sender,Destination::Direct{contact},Message::RelayUpdate{txid,stage:"included".into(),receipt_hex:Some(receipt_hex)},now)?;
            if serde_json::to_vec(&envelope)?.len()>paramo1d_courier::MAX_ENVELOPE{return Err("Receipt exceeds packet limit".into());}
            Ok(json!({"envelope":envelope}))
        },
        "chat_seal_payment"=>{
            let journal=crate::payment_journal::Journal::open(std::path::Path::new(request["journal_directory"].as_str().ok_or("Missing payment storage")?))?;
            let saved=journal.current().ok_or("No saved authorized payment")?;
            if saved["state"]!="authorized"{return Err("No pending authorized payment to carry".into());}
            let intent=saved["intent_hex"].as_str().ok_or("Missing authorized bytes")?;
            let payment=crate::payment::inspect_signed(intent)?;
            if payment["txid"]!=saved["txid"]{return Err("Saved payment identity mismatch".into());}
            let sender:Contact=serde_json::from_value(request["sender"].clone())?;
            let contact:Contact=serde_json::from_value(request["contact"].clone())?;
            let envelope=identity.seal(sender,Destination::Direct{contact},Message::Transaction{intent_hex:intent.to_owned()},now)?;
            if serde_json::to_vec(&envelope)?.len()>paramo1d_courier::MAX_ENVELOPE{return Err("Payment exceeds current nearby packet limit".into());}
            Ok(json!({"envelope":envelope,"payment":payment}))
        },
        "chat_seal"=>{
            let sender:Contact=serde_json::from_value(request["sender"].clone())?;
            let contact:Contact=serde_json::from_value(request["contact"].clone())?;
            let text=request["text"].as_str().ok_or("Missing message")?.to_owned();
            Ok(json!({"envelope":identity.seal(sender,Destination::Direct{contact},Message::Text{text},now)?}))
        },
        "chat_group_seal"=>{
            let sender:Contact=serde_json::from_value(request["sender"].clone())?;
            let own=identity.contact("Local".into(),String::new())?;
            if sender.id!=own.id || sender.box_key!=own.box_key ||
                sender.address!=crate::derive_address(&crate::derive_secret(&seed,0)).to_bech32() {
                return Err("Community sender does not match this wallet".into());
            }
            let text=request["text"].as_str().ok_or("Missing message")?.to_owned();
            let envelope=identity.seal(sender,Destination::Group{room:paramo1d_courier::LOBBY.into()},Message::Text{text},now)?;
            Ok(json!({"envelope":envelope}))
        },
        "chat_seal_invoice"=>{
            let sender:Contact=serde_json::from_value(request["sender"].clone())?;
            let contact:Contact=serde_json::from_value(request["contact"].clone())?;
            let own_address=crate::derive_address(&crate::derive_secret(&seed,0)).to_bech32();
            if sender.address!=own_address {return Err("Payment request must use this wallet's primary address".into());}
            let invoice_id=request["invoice_id"].as_str().ok_or("Missing request ID")?.to_owned();
            let amount=request["amount"].as_str().ok_or("Missing request amount")?.to_owned();
            let memo=request["memo"].as_str().ok_or("Missing request memo")?.to_owned();
            let envelope=identity.seal(sender.clone(),Destination::Direct{contact},Message::Invoice{invoice_id,address:sender.address,amount,memo},now)?;
            Ok(json!({"envelope":envelope}))
        },
        "chat_open"|"chat_open_archived"|"chat_open_saved"=>{
            let envelope:Envelope=serde_json::from_value(request["envelope"].clone())?;
            if envelope.is_plain_direct() {return Err("Unencrypted direct messages are not supported".into());}
            let expected:Contact=serde_json::from_value(request["contact"].clone())?;
            expected.validate()?;
            let Destination::Direct{contact}= &envelope.data.destination else {return Err("Only encrypted direct messages are accepted".into());};
            let own=identity.contact("Local".into(),String::new())?;
            let saved=request["op"]=="chat_open_saved";
            if saved {
                // The sender can reopen its locally saved ciphertext, but only
                // when its signed sender and pinned recipient match this wallet
                // and the selected contact's exact signing/encryption keys.
                if envelope.data.sender.id!=own.id || envelope.data.sender.box_key!=own.box_key ||
                    contact.id!=expected.id || contact.box_key!=expected.box_key {
                    return Err("Saved message does not match this wallet and contact".into());
                }
            } else {
                if envelope.data.sender.id!=expected.id || envelope.data.sender.box_key!=expected.box_key {return Err("Sender differs from the selected contact".into());}
                if contact.id!=own.id || contact.box_key!=own.box_key {return Err("Message is not addressed to this wallet identity".into());}
            }
            // Archived packets were accepted while live. For display only,
            // verify their original signed validity window and decrypt even
            // after transport expiry. The live receive operation still rejects
            // an expired or future packet before it can enter the archive.
            let display_time=if op=="chat_open_archived" || saved {
                now.min(envelope.data.expires_ms.saturating_sub(1))
            } else {now};
            match identity.open(&envelope,display_time)? {
                Message::Text{text}=>Ok(json!({"id":envelope.id,"text":text,"sender":envelope.data.sender})),
                Message::Transaction{intent_hex}=>{
                    let payment=crate::payment::inspect_signed(&intent_hex)?;
                    Ok(json!({"id":envelope.id,"text":"Payment authorization verified. Not settled; network acceptance is still required.","sender":envelope.data.sender,"payment":payment,"intent_hex":intent_hex}))
                },
                Message::RelayUpdate{txid,stage,receipt_hex}=>Ok(json!({"id":envelope.id,"text":"Peer-reported payment status. Verify the receipt on this device before relying on it.","sender":envelope.data.sender,"relay_update":{"txid":txid,"claimed_stage":stage,"receipt_hex":receipt_hex,"verified":false}})),
                Message::Invoice{invoice_id,address,amount,memo}=>{
                    let sender_address=if saved {crate::derive_address(&crate::derive_secret(&seed,0)).to_bech32()} else {expected.address.clone()};
                    if address!=envelope.data.sender.address || address!=sender_address {return Err("Payment request address differs from the saved contact invitation".into());}
                    Ok(json!({"id":envelope.id,"text":"Payment request received. Review the address and amount before authorizing any transfer.","sender":envelope.data.sender,"invoice":{"invoice_id":invoice_id,"address":address,"amount":amount,"memo":memo}}))
                },
                _=>Err("This message type is not enabled; no payment was executed".into())
            }
        },
        _=>Err("Unsupported messaging operation".into())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    const NOW:u64=1_800_000_000_000;
    fn contact(seed:&[u8;32],name:&str)->Contact {Identity::from_seed(seed).contact(name.into(),String::new()).unwrap()}
    #[test] fn sender_can_reopen_saved_ciphertext_only_for_pinned_contact() {
        let a=[1;32];let b=[2;32];let c=[3;32];
        let sender=contact(&a,"Alice");let recipient=contact(&b,"Bob");
        let sealed=run(&json!({"op":"chat_seal","sender":sender,"contact":recipient,"text":"hello again","now_ms":NOW}),Some(&a)).unwrap();
        let saved=run(&json!({"op":"chat_open_saved","envelope":sealed["envelope"],"contact":recipient,"now_ms":NOW}),Some(&a)).unwrap();
        assert_eq!(saved["text"],"hello again");
        assert!(run(&json!({"op":"chat_open_saved","envelope":sealed["envelope"],"contact":contact(&c,"Eve"),"now_ms":NOW}),Some(&a)).is_err());
        assert!(run(&json!({"op":"chat_open_saved","envelope":sealed["envelope"],"contact":recipient,"now_ms":NOW}),Some(&b)).is_err());
        let later=NOW+paramo1d_courier::MAX_LIFETIME_MS+1;
        assert!(run(&json!({"op":"chat_open","envelope":sealed["envelope"],"contact":sender,"now_ms":later}),Some(&b)).is_err());
        let archived=run(&json!({"op":"chat_open_archived","envelope":sealed["envelope"],"contact":sender,"now_ms":later}),Some(&b)).unwrap();
        assert_eq!(archived["text"],"hello again");
    }
    #[test] fn rejects_legacy_unencrypted_direct_packets() {
        let a=[1;32];let b=[2;32];
        let sender=contact(&a,"Alice");let recipient=contact(&b,"Bob");
        let envelope=Identity::from_seed(&a).seal_plain_text(sender.clone(),recipient, "legacy".into(),NOW).unwrap();
        assert!(run(&json!({"op":"chat_inspect","envelope":envelope,"now_ms":NOW}),None).is_err());
        assert!(run(&json!({"op":"chat_open","envelope":envelope,"contact":sender,"now_ms":NOW}),Some(&b)).is_err());
    }
    #[test] fn invoice_requires_signed_contact_address_and_positive_amount() {
        let a=[1;32];let b=[2;32];
        let mut sender=contact(&a,"Alice");sender.address=crate::derive_address(&crate::derive_secret(&a,0)).to_bech32();
        let recipient=contact(&b,"Bob");
        let input=json!({"op":"chat_seal_invoice","sender":sender.clone(),"contact":recipient,"invoice_id":"a".repeat(32),"amount":"1.25","memo":"Lunch","now_ms":NOW});
        let sealed=run(&input,Some(&a)).unwrap();
        let received=run(&json!({"op":"chat_open","envelope":sealed["envelope"],"contact":sender,"now_ms":NOW}),Some(&b)).unwrap();
        assert_eq!(received["invoice"]["amount"],"1.25");
        assert_eq!(received["invoice"]["address"],sender.address);
        let mut wrong=input;wrong["amount"]=json!("0");
        assert!(run(&wrong,Some(&a)).is_err());
    }
    #[test] fn transport_inspection_needs_no_secret_but_rejects_tampering_and_expiry() {
        let a=[1;32];let b=[2;32];
        let envelope=Identity::from_seed(&a).seal(contact(&a,"A"),Destination::Direct{contact:contact(&b,"B")},Message::Text{text:"offline".into()},NOW).unwrap();
        let request=json!({"op":"chat_inspect","envelope":envelope,"now_ms":NOW});
        let result=run(&request,None).unwrap();
        assert_eq!(result["recipient"]["id"],contact(&b,"B").id);
        assert!(result.get("text").is_none());
        let mut bad=request.clone();bad["envelope"]["data"]["sender"]["name"]=json!("Fake");assert!(run(&bad,None).is_err());
        let mut bad=request;bad["now_ms"]=json!(NOW+paramo1d_courier::MAX_LIFETIME_MS+1);assert!(run(&bad,None).is_err());
    }
    #[test] fn inbox_authorization_is_bound_to_own_identity_path_and_time() {
        let seed=[1;32];let own=contact(&seed,"Alice");
        let result=run(&json!({"op":"chat_inbox_auth","after":7,"now_ms":NOW,"path":"/v1/other"}),Some(&seed)).unwrap();
        let path=result["path"].as_str().unwrap();let signature=result["signature"].as_str().unwrap();
        assert_eq!(path,format!("/v1/inbox/{}?after=7&limit=30",own.id));
        paramo1d_courier::verify_read(&own.id,path,NOW,signature,NOW).unwrap();
        assert!(paramo1d_courier::verify_read(&own.id,"/v1/other",NOW,signature,NOW).is_err());
    }
    #[test] fn push_authorization_signs_only_push_paths() {
        let seed=[1;32];let own=contact(&seed,"Alice");let target="cd".repeat(32);
        for (purpose,prefix) in [("register","/v1/push/register/"),("unregister","/v1/push/unregister/"),("ping","/v1/push/ping/")] {
            let result=run(&json!({"op":"chat_push_auth","purpose":purpose,"target":target,"now_ms":NOW}),Some(&seed)).unwrap();
            let path=format!("{prefix}{target}");assert_eq!(result["path"],path);assert_eq!(result["id"],own.id);
            paramo1d_courier::verify_read(&own.id,&path,NOW,result["signature"].as_str().unwrap(),NOW).unwrap();
        }
        for (purpose,target) in [("inbox",json!(target.clone())),("ping",json!("CD".repeat(32))),("ping",json!("../inbox")),("register",Value::Null)] {
            assert!(run(&json!({"op":"chat_push_auth","purpose":purpose,"target":target,"now_ms":NOW}),Some(&seed)).is_err());
        }
    }
    #[test] fn inbox_page_limit_is_bounded_and_signed() {
        let seed=[1;32];let own=contact(&seed,"Alice");
        for limit in [1,2,8,30] {
            let result=run(&json!({"op":"chat_inbox_auth","after":7,"limit":limit,"now_ms":NOW}),Some(&seed)).unwrap();
            let path=format!("/v1/inbox/{}?after=7&limit={limit}",own.id);
            assert_eq!(result["path"],path);
            paramo1d_courier::verify_read(&own.id,&path,NOW,result["signature"].as_str().unwrap(),NOW).unwrap();
            assert!(paramo1d_courier::verify_read(&own.id,&format!("{path}0"),NOW,result["signature"].as_str().unwrap(),NOW).is_err());
        }
        for limit in [json!(0),json!(31),json!(-1),json!(1.5),json!(true),json!("1"),Value::Null] {
            assert!(run(&json!({"op":"chat_inbox_auth","after":7,"limit":limit,"now_ms":NOW}),Some(&seed)).is_err());
        }
    }
    #[test] fn upstream_message_opens_in_ios_adapter_and_reverse() {
        let a=[1;32];let b=[2;32];let sender=contact(&a,"Alice");let recipient=contact(&b,"Bob");
        let envelope=Identity::from_seed(&a).seal(sender.clone(),Destination::Direct{contact:recipient.clone()},Message::Text{text:"Hello".into()},NOW).unwrap();
        let request=json!({"op":"chat_open","envelope":envelope,"contact":sender,"now_ms":NOW});
        assert_eq!(run(&request,Some(&b)).unwrap()["text"],"Hello");
        let sealed=run(&json!({"op":"chat_seal","sender":recipient,"contact":sender,"text":"Reply","now_ms":NOW}),Some(&b)).unwrap();
        let envelope:Envelope=serde_json::from_value(sealed["envelope"].clone()).unwrap();
        assert_eq!(Identity::from_seed(&a).open(&envelope,NOW).unwrap(),Message::Text{text:"Reply".into()});
    }
    #[test] fn rejects_wrong_recipient_sender_tampering_and_expiry() {
        let a=[1;32];let b=[2;32];let sender=contact(&a,"Alice");
        let envelope=Identity::from_seed(&a).seal(sender.clone(),Destination::Direct{contact:contact(&b,"Bob")},Message::Text{text:"Secret".into()},NOW).unwrap();
        let original=json!({"op":"chat_open","envelope":envelope,"contact":sender,"now_ms":NOW});
        assert!(run(&original,Some(&[3;32])).is_err());
        let mut bad=original.clone();bad["contact"]=json!(contact(&[3;32],"Alice"));assert!(run(&bad,Some(&b)).is_err());
        let mut bad=original.clone();bad["envelope"]["data"]["body"]=json!("AAAA");assert!(run(&bad,Some(&b)).is_err());
        let mut bad=original;bad["now_ms"]=json!(NOW+paramo1d_courier::MAX_LIFETIME_MS+1);assert!(run(&bad,Some(&b)).is_err());
    }
    #[test] fn rejects_group_plaintext_and_payment_messages() {
        let a=[1;32];let b=[2;32];let sender=contact(&a,"Alice");
        let envelope=Identity::from_seed(&a).seal(sender.clone(),Destination::Group{room:paramo1d_courier::LOBBY.into()},Message::Text{text:"Public".into()},NOW).unwrap();
        assert!(run(&json!({"op":"chat_open","envelope":envelope,"contact":sender,"now_ms":NOW}),Some(&b)).is_err());
        let envelope=Identity::from_seed(&a).seal(sender.clone(),Destination::Direct{contact:contact(&b,"Bob")},Message::Receipt{invoice_id:"a".repeat(32),receipt_hex:"00".into()},NOW).unwrap();
        assert!(run(&json!({"op":"chat_open","envelope":envelope,"contact":sender,"now_ms":NOW}),Some(&b)).is_err());
    }
    #[test] fn receipt_messages_never_promote_peer_claims_to_verified_settlement() {
        let a=[1;32];let b=[2;32];let sender=contact(&a,"Alice");let recipient=contact(&b,"Bob");
        let sealed=run(&json!({"op":"chat_seal_receipt","sender":sender,"contact":recipient,"txid":"a".repeat(64),"receipt_hex":"00","now_ms":NOW}),Some(&a)).unwrap();
        let opened=run(&json!({"op":"chat_open","envelope":sealed["envelope"],"contact":sender,"now_ms":NOW}),Some(&b)).unwrap();
        assert_eq!(opened["relay_update"]["claimed_stage"],"included");
        assert_eq!(opened["relay_update"]["verified"],false);
        assert!(opened.get("payment").is_none());
    }
    #[test] fn public_community_text_is_signed_and_payment_packets_are_not_displayed() {
        let master=[7;32];let identity=Identity::from_seed(&master);
        let address=crate::derive_address(&crate::derive_secret(&master,0)).to_bech32();
        let sender=identity.contact("Alice".into(),address).unwrap();
        let sealed=run(&json!({"op":"chat_group_seal","sender":sender,"text":"Hello community","now_ms":NOW}),Some(&master)).unwrap();
        let opened=run(&json!({"op":"chat_group_open","envelope":sealed["envelope"],"now_ms":NOW}),None).unwrap();
        assert_eq!(opened["text"],"Hello community");
        assert_eq!(opened["sender"]["id"],sender.id);
        let mut altered=sealed["envelope"].clone();altered["data"]["sender"]["name"]=json!("Mallory");
        assert!(run(&json!({"op":"chat_group_open","envelope":altered,"now_ms":NOW}),None).is_err());
        let group=Destination::Group{room:paramo1d_courier::LOBBY.into()};
        let payment=identity.seal(sender.clone(),group,Message::Transaction{intent_hex:"00".into()},NOW).unwrap();
        let checked=run(&json!({"op":"chat_group_open","envelope":payment,"now_ms":NOW}),None).unwrap();
        assert!(checked["text"].is_null());
        let observation=identity.seal(sender.clone(),Destination::Group{room:paramo1d_courier::LOBBY.into()},Message::RelayUpdate{txid:"a".repeat(64),stage:"included".into(),receipt_hex:Some("00".into())},NOW).unwrap();
        let opened=run(&json!({"op":"chat_group_open","envelope":observation,"now_ms":NOW}),None).unwrap();
        assert_eq!(opened["relay_update"]["verified"],false);
        assert_eq!(opened["relay_update"]["receipt_hex"],"00");
        assert!(opened.get("payment").is_none());
        let mut wrong=sender.clone();wrong.address="o1not-the-wallet".into();
        assert!(run(&json!({"op":"chat_group_seal","sender":wrong,"text":"wrong","now_ms":NOW}),Some(&master)).is_err());
    }
}
