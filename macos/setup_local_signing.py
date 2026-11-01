#!/usr/bin/env python3
"""Create one local, code-signing-only identity; keep its key in the user keychain."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def command(args, **kwargs):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", "replace").strip())
    return result


def main():
    support = Path.home() / "Library/Application Support/digiter-xpander-kiosk/signing"
    support.mkdir(parents=True, exist_ok=True)
    support.chmod(0o700)
    config_path = support / "identity.json"
    if config_path.exists():
        print(json.loads(config_path.read_text())["identity_sha1"])
        return
    keychain = command(["security", "default-keychain", "-d", "user"]).stdout.decode().strip().strip('"')
    with tempfile.TemporaryDirectory(prefix="xpander-signing-", dir=support) as temporary:
        work = Path(temporary)
        config = work / "openssl.cnf"
        config.write_text("""[req]
distinguished_name = dn
x509_extensions = code_signing
prompt = no
[dn]
CN = MSI Xpander Local Signing
[code_signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        key = work / "key.pem"
        cert = work / "cert.pem"
        # No credential is placed in command text or logs. Temporary key material
        # stays in this private directory and is removed after the keychain import.
        old_umask = os.umask(0o077)
        try:
            command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                     "-config", str(config), "-keyout", str(key), "-out", str(cert)])
            identity = work / "identity.p12"
            # Security.framework rejects an empty PKCS#12 MAC password on some
            # macOS releases. This wrapping string is not a user credential; the
            # directory's 0700 permissions protect this short-lived import file.
            wrapping = "local-import-only"
            command(["openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(cert),
                     "-name", "MSI Xpander Local Signing", "-out", str(identity), "-passout", "pass:" + wrapping])
            command(["security", "import", str(identity), "-k", keychain,
                     "-P", wrapping, "-x", "-T", "/usr/bin/codesign"])
            der = command(["openssl", "x509", "-in", str(cert), "-outform", "DER"]).stdout
            fingerprint = hashlib.sha1(der).hexdigest().upper()
            (support / "certificate.pem").write_bytes(cert.read_bytes())
            config_path.write_text(json.dumps({"identity_sha1": fingerprint,
                "name": "MSI Xpander Local Signing", "keychain": keychain}, indent=2) + "\n")
        finally:
            os.umask(old_umask)
    print(fingerprint)


if __name__ == "__main__": main()
