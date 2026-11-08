#!/bin/bash
# Spike #100: can the Fedora 45 signing tools sign a UKI (Secure Boot) and its PCR11 policy with a
# TPM-resident, non-exportable key? Runs in a throwaway fedora-bootc 45 container with a software
# TPM (swtpm), started by: spikes/c1-dev-image/run.sh tpm
# Prints ATOS-TPM <check> ok|FAIL lines. Nothing here touches real keys; the TPM state is discarded.
set -uo pipefail
dnf -y -q install --setopt=install_weak_deps=False systemd-ukify systemd-boot-unsigned sbsigntools swtpm swtpm-tools \
  tpm2-tools tpm2-openssl openssl >/dev/null || exit 1
rpm -q systemd systemd-ukify sbsigntools tpm2-openssl openssl swtpm
cd "$(mktemp -d)" || exit 1
r() { if "${@:2}" >"$1.log" 2>&1; then echo "ATOS-TPM $1 ok"; else echo "ATOS-TPM $1 FAIL"; tail -n 8 "$1.log"; fi; }

mkdir tpm
swtpm socket --tpm2 --tpmstate dir=tpm --server type=tcp,port=2321 --ctrl type=tcp,port=2322 \
  --flags not-need-init,startup-clear --daemon
export TPM2TOOLS_TCTI=swtpm:port=2321 TPM2OPENSSL_TCTI=swtpm:port=2321
H=0x81000100
# The developer key: RSA-2048 (as D-014's db keys), generated inside the TPM, fixedtpm|fixedparent
# so it can never leave it, persisted at handle $H. Unrestricted signing key, scheme chosen per call.
# No resource manager in front of swtpm: flush transient objects between calls, or its few object
# slots fill up.
tpm2_createprimary -Q -C o -c primary.ctx && tpm2_flushcontext -t
tpm2_create -Q -C primary.ctx -G rsa2048 -a 'fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign' \
  -u key.pub -r key.priv && tpm2_flushcontext -t
tpm2_load -Q -C primary.ctx -u key.pub -r key.priv -c key.ctx
tpm2_evictcontrol -Q -C o -c key.ctx $H && tpm2_flushcontext -t
tpm2_readpublic -c $H | grep -A1 attributes
P=(-provider tpm2 -provider default)
r cert openssl req "${P[@]}" -new -x509 -sha256 -days 3650 -key handle:$H \
  -subj '/CN=Atos TEST developer key (TPM) - not for release/' -out dev.crt
openssl pkey "${P[@]}" -in handle:$H -pubout -out dev.pub.pem
# Can the private part leave the TPM? It must not. (1) The TPM enforces it: fixedtpm and fixedparent
# are set. (2) Whatever the provider writes for the key cannot be loaded without this TPM.
# (3) TPM2_Duplicate, the TPM's only way to move a key out, is refused (logged, not asserted: the
# error may come from the missing policy session before the attribute check).
attrs=$(tpm2_readpublic -c $H | grep -A1 attributes)
if grep -q fixedtpm <<<"$attrs" && grep -q fixedparent <<<"$attrs"; then echo "ATOS-TPM fixed-attributes ok"
else echo "ATOS-TPM fixed-attributes FAIL"; fi
openssl pkey "${P[@]}" -in handle:$H -out exported.pem 2>/dev/null; echo "provider wrote: $(head -1 exported.pem 2>/dev/null || echo nothing)"
if openssl pkey -in exported.pem -noout 2>/dev/null; then echo "ATOS-TPM no-plain-key FAIL"; else echo "ATOS-TPM no-plain-key ok"; fi
if tpm2_duplicate -c $H -C null -G null -r dup.priv -s dup.seed >dup.log 2>&1; then echo "ATOS-TPM duplicate ACCEPTED"
else echo "ATOS-TPM duplicate refused: $(grep -E '^ERROR: Esys_Duplicate' dup.log || tail -n 1 dup.log)"; fi
tpm2_flushcontext -t 2>/dev/null

k=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 | head -1)
# 1. Secure Boot signature through the provider (systemd-sbsign), the UKI's PCR11 policy too (systemd-measure).
r ukify-systemd-sbsign ukify build --linux "$k/vmlinuz" --initrd "$k/initramfs.img" --cmdline 'quiet' \
  --signtool systemd-sbsign --no-sign-kernel --signing-provider tpm2 --certificate-provider default \
  --secureboot-private-key handle:$H --secureboot-certificate dev.crt \
  --pcr-private-key handle:$H --pcr-certificate dev.crt --phases enter-initrd \
  --output uki.efi
r sbverify sbverify --cert dev.crt uki.efi
r pcrsig-section sh -c 'ukify inspect uki.efi | grep -q "\.pcrsig"'
# 2. The same through `bootc container ukify`, which passes everything after `--` to ukify
# (as components/c1-base/Containerfile does). It refuses the running root, so a tiny stand-in rootfs.
mkdir -p rootfs/usr/lib rootfs/boot rootfs/sysroot && cp /usr/lib/os-release rootfs/usr/lib/
r bootc-ukify bootc container ukify --rootfs rootfs --kernel-dir "$k" -- \
  --signtool systemd-sbsign --no-sign-kernel --signing-provider tpm2 --certificate-provider default \
  --secureboot-private-key handle:$H --secureboot-certificate "$PWD/dev.crt" --output "$PWD/bootc-uki.efi"
r sbverify-bootc sbverify --cert dev.crt bootc-uki.efi
# 3. sbsign (what our Containerfile uses today): no engine or provider option under OpenSSL 4.
if sbsign --engine tpm2 --key handle:$H --cert dev.crt --output sbsign.efi "$k/vmlinuz" >sbsign.log 2>&1; then
  echo "ATOS-TPM sbsign-engine accepted"; else echo "ATOS-TPM sbsign-engine unsupported: $(head -1 sbsign.log)"; fi
# 4. systemd-measure on its own, as the build tool would call it for the PCR11 policy.
r measure /usr/lib/systemd/systemd-measure sign --linux="$k/vmlinuz" --initrd="$k/initramfs.img" \
  --cmdline=<(echo quiet) --osrel=/usr/lib/os-release --bank=sha256 \
  --private-key=handle:$H --private-key-source=provider:tpm2 --certificate=dev.crt
