#!/bin/bash
# Generates the TEST Secure Boot keys for the sealed base image (#54, D-014).
# TEST ONLY: the db private key is committed on purpose, so anyone can sign a UKI that boots
# where these keys are enrolled (dev VM, NUC). Never enrol them on a machine you care about,
# never put them in a release db. Release keys live on offline tokens (D-014).
#
# Writes into this directory: db.key, db.crt (signs systemd-boot and the UKI) and
# {PK,KEK,db}.auth (signed EFI signature lists that systemd-boot enrols). The PK and KEK
# private keys are deleted: nothing needs them after the .auth files exist.
# Needs openssl and sbsigntool (sbsiglist, sbvarsign); runs in the dev VM.
set -euo pipefail
cd "$(dirname "$0")"

# Fixed owner GUID, so a rerun differs only in the keys.
GUID=4a3d6e0b-5f2c-4b7e-9a51-7465737400a7

for k in PK KEK db; do
  openssl req -quiet -newkey rsa:2048 -nodes -keyout "$k.key" -new -x509 -sha256 -days 3650 \
    -subj "/CN=Atos TEST $k - not for release, do not trust/" -out "$k.crt"
  openssl x509 -outform DER -in "$k.crt" -out "$k.der"
  sbsiglist --owner "$GUID" --type x509 --output "$k.esl" "$k.der"
done
# PK and KEK are signed by PK, db by KEK.
sbvarsign --key PK.key --cert PK.crt --output PK.auth PK PK.esl
sbvarsign --key PK.key --cert PK.crt --output KEK.auth KEK KEK.esl
sbvarsign --key KEK.key --cert KEK.crt --output db.auth db db.esl

rm -f PK.key KEK.key PK.crt KEK.crt ./*.der ./*.esl
