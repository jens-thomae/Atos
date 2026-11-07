# Drives a QEMU serial console over a unix socket, like a person at the keyboard (#76 spike).
#   drive.py <socket> <log> <step>...
# Steps run in order:
#   e[<s>]:<regex>   wait up to <s> seconds (default 120) for <regex> in the output, ANSI codes removed
#   s:<keys>         type <keys>; Python escapes work (\r Enter, \x1b[B arrow down)
#   w<s>:            just log for <s> seconds
#   until:<regex>    keep logging until <regex> appears or QEMU exits
# The raw console output goes to <log>. Exits 1 if an expected text does not appear in time.
import re, socket, sys, time

sock_path, log_path, *steps = sys.argv[1:]
ansi = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-Za-z]')
s = socket.socket(socket.AF_UNIX)
for _ in range(100):
    try:
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.2)
log, buf = open(log_path, 'wb'), ''

def read_until(pat, timeout):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        m = re.search(pat, buf)
        if m:
            buf = buf[m.end():]
            return True
        s.settimeout(max(0.1, end - time.time()))
        try:
            data = s.recv(65536)
        except socket.timeout:
            continue
        if not data:  # QEMU exited
            return bool(re.search(pat, buf))
        log.write(data)
        log.flush()
        buf += ansi.sub(b'', data).replace(b'\r', b'').decode('utf-8', 'replace')
    return False

for step in steps:
    kind, arg = step.split(':', 1)
    if kind == 's':
        time.sleep(0.5)  # let the menu settle before typing
        s.sendall(arg.encode().decode('unicode_escape').encode('latin-1'))
        print(f'typed {arg!r}', flush=True)
    elif kind[0] == 'w':  # w<s>: just log for <s> seconds
        read_until(r'(?!)', int(kind[1:]))
    elif kind == 'until':
        print(f'waiting for {arg!r}:', 'seen' if read_until(arg, 3600) else 'QEMU exited', flush=True)
    else:
        timeout = int(kind[1:] or 120)
        if not read_until(arg, timeout):
            print(f'did not see {arg!r} within {timeout} s', flush=True)
            sys.exit(1)
        print(f'saw {arg!r}', flush=True)
