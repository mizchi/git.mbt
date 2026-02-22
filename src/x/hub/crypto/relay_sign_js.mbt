///| JS relay signing: Web Crypto API via extern "js".

///|
fn relay_sign_public_key() -> String? {
  match @sys.get_env_var("BIT_RELAY_SIGN_PUBLIC_KEY") {
    Some(value) => {
      let normalized = value.trim(chars=" \n\r\t").to_string()
      if normalized.length() > 0 {
        Some(normalized)
      } else {
        None
      }
    }
    None => None
  }
}

///|
extern "js" fn js_unix_timestamp_sec() -> Int64 =
  #| () => BigInt(Math.floor(Date.now() / 1000))

///|
pub fn relay_unix_timestamp_sec() -> Int64 {
  js_unix_timestamp_sec()
}

///|
extern "js" fn js_load_signing_key() -> String =
  #| () => {
  #|   const filePath = process.env.BIT_RELAY_SIGN_PRIVATE_KEY_FILE;
  #|   if (filePath && filePath.trim().length > 0) {
  #|     try {
  #|       const fs = require('fs');
  #|       return fs.readFileSync(filePath.trim(), 'utf8');
  #|     } catch (e) {
  #|       return '';
  #|     }
  #|   }
  #|   const pemContent = process.env.BIT_RELAY_SIGN_PRIVATE_KEY;
  #|   if (pemContent && pemContent.trim().length > 0) {
  #|     return pemContent.trim();
  #|   }
  #|   return '';
  #| }

///|
pub fn relay_load_signing_key() -> String? {
  let pem = js_load_signing_key()
  if pem.length() > 0 {
    Some(pem)
  } else {
    None
  }
}

///|
extern "js" fn js_sha256_hex(text : String) -> @js_async.Promise[String] =
  #| async (text) => {
  #|   const encoder = new TextEncoder();
  #|   const data = encoder.encode(text);
  #|   const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  #|   const hashArray = new Uint8Array(hashBuffer);
  #|   return Array.from(hashArray).map(b => b.toString(16).padStart(2, '0')).join('');
  #| }

///|
pub async fn relay_sha256_hex(text : String) -> String raise @bit.GitError {
  js_sha256_hex(text).wait() catch {
    err =>
      raise @bit.GitError::IoError(
        "relay sign: Web Crypto SHA-256 failed: \{err}",
      )
  }
}

///|
extern "js" fn js_sign_ed25519(
  pem_key : String,
  message : String,
) -> @js_async.Promise[String] =
  #| async (pemKey, message) => {
  #|   const pemBody = pemKey
  #|     .replace(/-----BEGIN[^-]*-----/, '')
  #|     .replace(/-----END[^-]*-----/, '')
  #|     .replace(/\s+/g, '');
  #|   const binaryDer = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0));
  #|   const key = await crypto.subtle.importKey(
  #|     'pkcs8', binaryDer, { name: 'Ed25519' }, false, ['sign']
  #|   );
  #|   const encoder = new TextEncoder();
  #|   const data = encoder.encode(message);
  #|   const sigBuffer = await crypto.subtle.sign('Ed25519', key, data);
  #|   const sigBytes = new Uint8Array(sigBuffer);
  #|   let b64 = '';
  #|   for (let i = 0; i < sigBytes.length; i++) {
  #|     b64 += String.fromCharCode(sigBytes[i]);
  #|   }
  #|   return btoa(b64);
  #| }

///|
pub async fn relay_sign_ed25519(
  key_source : String,
  message : String,
) -> String raise @bit.GitError {
  let base64_sig = js_sign_ed25519(key_source, message).wait() catch {
    err =>
      raise @bit.GitError::IoError(
        "relay sign: Web Crypto Ed25519 sign failed: \{err}",
      )
  }
  relay_base64_to_base64url(base64_sig)
}

///|
extern "js" fn js_resolve_public_key(
  pem_key : String,
) -> @js_async.Promise[String] =
  #| async (pemKey) => {
  #|   const pemBody = pemKey
  #|     .replace(/-----BEGIN[^-]*-----/, '')
  #|     .replace(/-----END[^-]*-----/, '')
  #|     .replace(/\s+/g, '');
  #|   const binaryDer = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0));
  #|   const key = await crypto.subtle.importKey(
  #|     'pkcs8', binaryDer, { name: 'Ed25519' }, true, ['sign']
  #|   );
  #|   const rawPub = await crypto.subtle.exportKey('raw', key);
  #|   const pubBytes = new Uint8Array(rawPub);
  #|   let b64 = '';
  #|   for (let i = 0; i < pubBytes.length; i++) {
  #|     b64 += String.fromCharCode(pubBytes[i]);
  #|   }
  #|   return btoa(b64);
  #| }

///|
pub async fn relay_resolve_public_key(
  key_source : String,
) -> String raise @bit.GitError {
  match relay_sign_public_key() {
    Some(explicit) => explicit
    None => {
      let base64_pub = js_resolve_public_key(key_source).wait() catch {
        err =>
          raise @bit.GitError::IoError(
            "relay sign: Web Crypto public key export failed: \{err}",
          )
      }
      relay_base64_to_base64url(base64_pub)
    }
  }
}
