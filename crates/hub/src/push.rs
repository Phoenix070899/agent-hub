//! Web Push to Echo Remote on the phone: the payload encrypted as RFC 8291 says, signed for the
//! push service with VAPID (RFC 8292), and posted with `curl`.

use std::io::Write;
use std::process::{Command, Stdio};

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use anyhow::{bail, Context, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use hkdf::Hkdf;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::Sha256;

/// What the phone's browser hands over when it subscribes: where to post, and its keys.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Subscription {
    pub endpoint: String,
    pub keys: SubscriptionKeys,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SubscriptionKeys {
    pub p256dh: String,
    pub auth: String,
}

/// A new VAPID key pair: the private scalar and the uncompressed public point, both base64url.
pub fn new_vapid_keys() -> (String, String) {
    let secret = SecretKey::random(&mut OsRng);
    let public = secret.public_key().to_encoded_point(false);
    (B64.encode(secret.to_bytes()), B64.encode(public.as_bytes()))
}

pub fn random_token() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    B64.encode(bytes)
}

/// How a push went: delivered, or the subscription is gone and should be forgotten.
#[derive(Debug, PartialEq)]
pub enum Sent {
    Delivered,
    Gone,
}

/// Encrypts `payload` for the subscription and posts it to its push service.
pub fn send(subscription: &Subscription, vapid_private: &str, payload: &[u8]) -> Result<Sent> {
    let body = encrypt(subscription, payload)?;
    let audience = origin(&subscription.endpoint)?;
    let jwt = vapid_jwt(vapid_private, &audience, crate::db::now() + 12 * 60 * 60)?;
    let public = public_of(vapid_private)?;
    let mut child = Command::new("curl")
        .args([
            "-sS",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "--max-time",
            "20",
            "-X",
            "POST",
        ])
        .args(["-H", "TTL: 86400", "-H", "Urgency: high"])
        .args([
            "-H",
            "Content-Encoding: aes128gcm",
            "-H",
            "Content-Type: application/octet-stream",
        ])
        .arg("-H")
        .arg(format!("Authorization: vapid t={jwt}, k={public}"))
        .args(["--data-binary", "@-"])
        .arg(&subscription.endpoint)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("running curl")?;
    child.stdin.take().unwrap().write_all(&body)?;
    let out = child.wait_with_output()?;
    let code = String::from_utf8_lossy(&out.stdout).trim().to_string();
    match code.as_str() {
        "200" | "201" | "202" => Ok(Sent::Delivered),
        "404" | "410" => Ok(Sent::Gone),
        _ => bail!(
            "the push service answered {code}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ),
    }
}

/// `https://host[:port]` of an endpoint URL: the JWT's audience.
fn origin(endpoint: &str) -> Result<String> {
    let rest = endpoint
        .strip_prefix("https://")
        .context("a push endpoint must be https")?;
    let host = rest.split('/').next().unwrap_or_default();
    if host.is_empty() {
        bail!("a push endpoint needs a host");
    }
    Ok(format!("https://{host}"))
}

fn public_of(vapid_private: &str) -> Result<String> {
    let secret = SecretKey::from_slice(&B64.decode(vapid_private)?)?;
    Ok(B64.encode(secret.public_key().to_encoded_point(false).as_bytes()))
}

/// The VAPID token for one push service, valid until `exp` (Unix seconds).
pub fn vapid_jwt(vapid_private: &str, audience: &str, exp: i64) -> Result<String> {
    let key = SigningKey::from_slice(&B64.decode(vapid_private)?)?;
    let header = B64.encode(json!({ "typ": "JWT", "alg": "ES256" }).to_string());
    let claims =
        B64.encode(json!({ "aud": audience, "exp": exp, "sub": "mailto:echo-remote@example.com" }).to_string());
    let signed = format!("{header}.{claims}");
    let signature: Signature = key.sign(signed.as_bytes());
    Ok(format!("{signed}.{}", B64.encode(signature.to_bytes())))
}

fn encrypt(subscription: &Subscription, payload: &[u8]) -> Result<Vec<u8>> {
    let mut salt = [0u8; 16];
    OsRng.fill_bytes(&mut salt);
    encrypt_with(subscription, payload, &SecretKey::random(&mut OsRng), &salt)
}

/// RFC 8291 with the sender's one-time key and salt given, so the RFC's own example checks it.
fn encrypt_with(subscription: &Subscription, payload: &[u8], sender: &SecretKey, salt: &[u8; 16]) -> Result<Vec<u8>> {
    let ua_public_bytes = B64.decode(&subscription.keys.p256dh).context("bad p256dh key")?;
    let ua_public = PublicKey::from_sec1_bytes(&ua_public_bytes).context("bad p256dh key")?;
    let auth = B64.decode(&subscription.keys.auth).context("bad auth secret")?;
    let as_public = sender.public_key().to_encoded_point(false);
    let shared = p256::ecdh::diffie_hellman(sender.to_nonzero_scalar(), ua_public.as_affine());

    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(&ua_public_bytes);
    key_info.extend_from_slice(as_public.as_bytes());
    let mut ikm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(&auth), shared.raw_secret_bytes())
        .expand(&key_info, &mut ikm)
        .map_err(|_| anyhow::anyhow!("hkdf"))?;
    let prk = Hkdf::<Sha256>::new(Some(salt), &ikm);
    let mut cek = [0u8; 16];
    let mut nonce = [0u8; 12];
    prk.expand(b"Content-Encoding: aes128gcm\0", &mut cek)
        .map_err(|_| anyhow::anyhow!("hkdf"))?;
    prk.expand(b"Content-Encoding: nonce\0", &mut nonce)
        .map_err(|_| anyhow::anyhow!("hkdf"))?;

    // One record: the payload, then the last-record delimiter.
    let mut record = payload.to_vec();
    record.push(2);
    let sealed = Aes128Gcm::new_from_slice(&cek)?
        .encrypt(&Nonce::from(nonce), record.as_slice())
        .map_err(|_| anyhow::anyhow!("encrypting the push payload"))?;

    let mut body = salt.to_vec();
    body.extend_from_slice(&4096u32.to_be_bytes());
    body.push(as_public.as_bytes().len() as u8);
    body.extend_from_slice(as_public.as_bytes());
    body.extend_from_slice(&sealed);
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::signature::Verifier;
    use p256::ecdsa::VerifyingKey;

    #[test]
    fn encrypts_the_rfc_8291_example() {
        let subscription = Subscription {
            endpoint: "https://push.example.net/push/JzLQ3raZJfFBR0aqvOMsLrt54w4rJUsV".into(),
            keys: SubscriptionKeys {
                p256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
                    .into(),
                auth: "BTBZMqHH6r4Tts7J_aSIgg".into(),
            },
        };
        let sender =
            SecretKey::from_slice(&B64.decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw").unwrap()).unwrap();
        let salt: [u8; 16] = B64.decode("DGv6ra1nlYgDCS1FRnbzlw").unwrap().try_into().unwrap();
        let body = encrypt_with(
            &subscription,
            b"When I grow up, I want to be a watermelon",
            &sender,
            &salt,
        )
        .unwrap();
        assert_eq!(
            B64.encode(body),
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        );
    }

    #[test]
    fn vapid_tokens_verify_with_the_public_key() {
        let (private, public) = new_vapid_keys();
        let jwt = vapid_jwt(&private, "https://web.push.apple.com", 2_000_000_000).unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let claims: serde_json::Value = serde_json::from_slice(&B64.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["aud"], "https://web.push.apple.com");
        assert_eq!(claims["exp"], 2_000_000_000);
        let key = VerifyingKey::from_sec1_bytes(&B64.decode(&public).unwrap()).unwrap();
        let signature = Signature::from_slice(&B64.decode(parts[2]).unwrap()).unwrap();
        key.verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
            .unwrap();
        assert_eq!(public_of(&private).unwrap(), public);
    }

    #[test]
    fn audiences_are_the_endpoint_origin() {
        assert_eq!(
            origin("https://web.push.apple.com/QGuQ/abc").unwrap(),
            "https://web.push.apple.com"
        );
        assert_eq!(
            origin("https://fcm.googleapis.com:443/fcm/send/x").unwrap(),
            "https://fcm.googleapis.com:443"
        );
        assert!(origin("http://insecure.example/x").is_err());
    }
}
