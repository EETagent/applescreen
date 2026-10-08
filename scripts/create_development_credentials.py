#!/usr/bin/env python3
"""Explicit local Cast development CA creation; never replace existing credentials.

The receiver uses both files to issue its Cast device-authentication certificate.
The sender selects only the CA certificate as a development trust root. TLS
transport credentials and the Cast authentication challenge remain distinct.
"""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--days', type=int, default=365)
    parser.add_argument('--openssl', default='/usr/bin/openssl')
    args = parser.parse_args()
    if not 1 <= args.days <= 365:
        parser.error('--days must be between 1 and 365')
    directory = args.directory.resolve()
    if directory.exists() and any(directory.iterdir()):
        parser.error('Use a new or empty directory; credentials are never overwritten')
    os.umask(0o077)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    configuration = Path(__file__).with_name('development-ca.cnf')
    certificate, key = directory / 'development-ca.crt', directory / 'development-ca.key'
    subprocess.run([args.openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-sha256', '-days', str(args.days), '-config', str(configuration),
                    '-keyout', str(key), '-out', str(certificate)], check=True)
    subprocess.run([args.openssl, 'verify', '-CAfile', str(certificate), str(certificate)], check=True)
    subprocess.run([args.openssl, 'x509', '-in', str(certificate), '-noout', '-dates',
                    '-fingerprint', '-sha256'], check=True)
    print(f'Receiver CA: {certificate}\nReceiver private key: {key}\n'
          f'Sender development trust root: {certificate}')


if __name__ == '__main__':
    main()
