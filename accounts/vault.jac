"""Sealing users' API keys at rest (TDD §9, accounts).

Each value is encrypted with AES-256-GCM under a key derived from the server's secret, with its
owner and name as authenticated data, so a sealed value copied to another account or another
field fails to open rather than opening as something else.

The secret is the server's PARALLAX_KEYS_SECRET, kept out of the database. With none, or one too
short to be a secret, keys cannot be saved or opened: there is no default to fall back on. Losing
it means every user connects their keys again; nothing else depends on it.
"""
import base64;
import os;
import from cryptography.exceptions { InvalidTag }
import from cryptography.hazmat.primitives { hashes }
import from cryptography.hazmat.primitives.ciphers.aead { AESGCM }
import from cryptography.hazmat.primitives.kdf.hkdf { HKDF }

glob SECRET_ENV: str = "PARALLAX_KEYS_SECRET";
glob MIN_SECRET_CHARS: int = 32;
glob FORMAT: str = "v1";
glob NONCE_BYTES: int = 12;

"""A sealed value could not be opened, or the server has no secret to open it with."""
obj VaultError(Exception) {
    has detail: str = "";

    override def __str__ -> str {
        return self.detail;
    }
}

def vault_ready -> bool {
    return len(os.environ.get(SECRET_ENV, "").strip()) >= MIN_SECRET_CHARS;
}

def cipher -> AESGCM {
    if not vault_ready() {
        raise VaultError(detail=f"{SECRET_ENV} is not set to at least {MIN_SECRET_CHARS} characters");
    }
    derived = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"parallax-user-keys-v1").derive(os.environ[SECRET_ENV].strip().encode());
    return AESGCM(derived);
}

def label_of(owner: str, name: str) -> bytes {
    return f"{owner}:{name}".encode();
}

def seal(owner: str, name: str, value: str) -> str {
    nonce = os.urandom(NONCE_BYTES);
    box = cipher().encrypt(nonce, value.encode(), label_of(owner, name));
    return FORMAT + "." + base64.urlsafe_b64encode(nonce + box).decode();
}

def unseal(owner: str, name: str, sealed: str) -> str {
    (version, _, body) = sealed.partition(".");
    if version != FORMAT {
        raise VaultError(detail=f"a sealed {name} has an unknown format");
    }
    try {
        raw = base64.urlsafe_b64decode(body);
        return cipher().decrypt(raw[:NONCE_BYTES], raw[NONCE_BYTES:], label_of(owner, name)).decode();
    } except (InvalidTag, ValueError) {
        raise VaultError(detail=f"a sealed {name} does not open under this server's secret");
    }
}
