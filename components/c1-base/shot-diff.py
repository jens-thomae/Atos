# Compares two QEMU screendumps (PPM) for shell-boot-test.sh: <dock.ppm> <launcher.ppm>.
# Exit 0 when the dock is drawn and the launcher changed more than 30% of the samples; otherwise the assertion says why.
import sys
def ppm(p):
    d = open(p, "rb").read(); parts = d.split(b"\n", 3)
    assert parts[0] == b"P6"; w, h = map(int, parts[1].split()); return w, h, parts[3]
w, h, a = ppm(sys.argv[1]); w2, h2, b = ppm(sys.argv[2])
assert (w, h) == (w2, h2) and len(a) == len(b) == w * h * 3, "screendump incomplete"
row = lambda px, y: px[y * w * 3:(y + 1) * w * 3]
bg = row(a, 2)[:3]                                   # top-left corner: the desktop background
strip = sum(row(a, y)[i:i + 3] != bg for y in range(int(h * .85), h) for i in range(0, w * 3, 3))
diff = sum(a[i] != b[i] for i in range(0, len(a), 97)) / (len(a) / 97)
print(f"dock strip: {strip} px off the background; launcher changed {diff:.0%} of the samples")
assert strip > 500, "no dock in the bottom strip"
assert diff > .3, "the launcher did not change the screen"
