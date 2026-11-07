# Lists every Authenticode signature in a PE file (all WIN_CERTIFICATE entries and nested signatures)
import sys, struct, subprocess, pefile
for path in sys.argv[1:]:
    pe = pefile.PE(path, fast_load=True)
    d = pe.OPTIONAL_HEADER.DATA_DIRECTORY[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_SECURITY']]
    raw = open(path, 'rb').read()[d.VirtualAddress:d.VirtualAddress + d.Size]
    print(f'== {path}: certificate table {d.Size} bytes')
    off, n = 0, 0
    while off + 8 <= len(raw):
        ln, rev, typ = struct.unpack_from('<IHH', raw, off)
        if ln == 0: break
        der = raw[off + 8:off + ln]
        n += 1
        out = subprocess.run(['openssl', 'pkcs7', '-inform', 'DER', '-print'], input=der, capture_output=True).stdout.decode(errors='replace')
        # issuer of each signer (signer_info) and nested signatures appear in the dump
        issuers = [l.strip() for l in out.splitlines() if 'issuer:' in l]
        print(f'  WIN_CERTIFICATE #{n} rev={rev:#x} type={typ} len={ln}')
        for i in dict.fromkeys(issuers): print('   ', i)
        print('    nested (1.3.6.1.4.1.311.2.4.1):', '1.3.6.1.4.1.311.2.4.1' in out)
        off += (ln + 7) & ~7
