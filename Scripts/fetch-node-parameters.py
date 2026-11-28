#!/usr/bin/env python3
"""Run the pinned fetcher with macOS's CA bundle when no override is supplied.
Certificate and hostname checks stay enabled. The upstream size/hash checks remain intact.
"""
import os
import hashlib
from pathlib import Path
import runpy
import ssl
import sys
import socket
import time
import urllib.error
import http.client


def configure_trust(platform=sys.platform):
    if platform == 'darwin' and not os.environ.get('SSL_CERT_FILE') and not os.environ.get('SSL_CERT_DIR'):
        bundle = Path('/etc/ssl/cert.pem')
        if bundle.is_file():
            ssl.create_default_context(cafile=str(bundle))  # Fail if malformed; never use CERT_NONE.
            os.environ['SSL_CERT_FILE'] = str(bundle)


def support_python39_digest():
    # The pinned upstream fetcher calls hashlib.file_digest (Python 3.11+).
    # Xcode may select Python 3.9. Stream the exact same SHA-256 bytes while
    # retaining the upstream size, digest and inventory checks.
    if hasattr(hashlib, 'file_digest'):
        return

    def file_digest(source, algorithm):
        digest = hashlib.new(algorithm)
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                return digest
            digest.update(chunk)

    hashlib.file_digest = file_digest


def is_transient(error):
    if isinstance(error, urllib.error.HTTPError):
        return error.code in {408, 429, 500, 502, 503, 504}
    if isinstance(error, urllib.error.URLError):
        return is_transient(error.reason)
    return isinstance(error, (TimeoutError, socket.timeout, ConnectionError,
                              http.client.IncompleteRead, http.client.RemoteDisconnected,
                              ssl.SSLEOFError))


if __name__ == '__main__':
    configure_trust()
    support_python39_digest()
    local_archive = os.environ.get('PARANO1D_PARAMETERS_ARCHIVE')
    if local_archive and '--archive' not in sys.argv:
        archive = Path(local_archive).expanduser().resolve()
        if not archive.is_file():
            sys.exit(f'Pinned parameter archive not found: {archive}')
        sys.argv.extend(['--archive', str(archive)])
    fetcher = Path(__file__).resolve().parents[1] / 'Vendor/paramo1d/scripts/fetch-android-artifacts.py'
    for attempt in range(5):
        try:
            runpy.run_path(str(fetcher), run_name='__main__')
            break
        except Exception as error:
            if 'CERTIFICATE_VERIFY_FAILED' in str(error):
                sys.exit('HTTPS certificate verification failed. Repair the Python/system CA trust store (or supply your trusted SSL_CERT_FILE). Certificate verification has NOT been disabled.')
            if not is_transient(error):
                raise
            if attempt == 4:
                sys.exit('Pinned parameter download failed after 5 attempts. Download the archive URL from Vendor/paramo1d/android/build-inputs.json in a browser, then set PARANO1D_PARAMETERS_ARCHIVE to that file and rerun validation. The local archive is checked against its pinned size and SHA-256 before extraction.')
            print(f'Parameter connection dropped; retrying verified download ({attempt + 2}/5).', file=sys.stderr)
            time.sleep(2 ** attempt)
