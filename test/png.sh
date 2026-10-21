#!/usr/bin/env bash
# tuppet png: a screen with ASCII, box drawing, CJK, and emoji renders at
# the cell size the reply names, with real glyphs; font settings and font
# files take effect on the next png. Medium and full builds draw with
# JetBrains Mono and read TrueType files; lean builds refuse them. Full
# builds also have the cjk font.
set -euo pipefail

BIN="$(realpath "${BIN:-./zig-out/bin/tuppet}")"
root="$(cd "$(dirname "$0")/.." && pwd)"
variant=$("$BIN" --version | sed -n 's/.*variant: \([a-z]*\).*/\1/p')
dir="$(mktemp -d)"
# Session data goes to the test directory, never to the user's store.
export XDG_STATE_HOME="$dir/state"
export TUPPET_SOCKET="$dir/s.sock"
export TUPPET_CONFIG=
unset TUPPET_PNG_FONTS TUPPET_PNG_FONT_SIZE
daemon_pid=
cleanup() {
    [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null
    wait 2>/dev/null
    rm -rf -- "$dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

"$BIN" daemon --socket "$TUPPET_SOCKET" 2>"$dir/log" &
daemon_pid=$!
for _ in $(seq 100); do "$BIN" list >/dev/null 2>&1 && break; sleep 0.02; done
"$BIN" list >/dev/null || fail "the daemon did not start"

# Row 1: A, a box-drawing line, a CJK ideograph, an emoji, and U+20000,
# a wide character no built-in font has, which draws as U+FFFD.
id=$("$BIN" run -s 20x3 -- sh -c 'printf "A─界\360\237\230\200\360\240\200\200\n"; exec sleep 300')
"$BIN" wait "$id" -m '界' -t 5s >/dev/null

# check PNG JSON: the PNG's size matches the reply's cell, and cells 0
# (A), 1 (─), 2-3 (界), 4-5 (the emoji) are neither background nor the
# U+FFFD of cells 6-7; the emoji has color.
check() {
    python3 - "$1" "$2" <<'EOF'
import json, struct, sys, zlib
data = open(sys.argv[1], 'rb').read()
reply = json.loads(sys.argv[2])
w, h = struct.unpack('>II', data[16:24])
cw, ch = map(int, reply['cell'].split('x'))
if (w, h) != (20 * cw, 3 * ch):
    sys.exit(f"PNG is {w}x{h}, but 20x3 cells of {reply['cell']} make {20 * cw}x{3 * ch}")
if reply['renderer'] == 'bitmap' and reply['cell'] != '8x16':
    sys.exit(f"the bitmap renderer used {reply['cell']} cells")
pos, idat = 8, b''
while pos < len(data):
    n, kind = struct.unpack('>I4s', data[pos:pos + 8])
    if kind == b'IDAT':
        idat += data[pos + 8:pos + 8 + n]
    pos += 12 + n
raw, stride, rows, prev = zlib.decompress(idat), w * 4, [], bytearray(w * 4)
for y in range(h):
    f, cur = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for i in range(stride):
        a, b, c = cur[i - 4] if i >= 4 else 0, prev[i], prev[i - 4] if i >= 4 else 0
        p = a + b - c
        pred = [0, a, b, (a + b) // 2, a if abs(p - a) <= abs(p - b) and abs(p - a) <= abs(p - c) else b if abs(p - b) <= abs(p - c) else c][f]
        cur[i] = (cur[i] + pred) & 255
    rows.append(bytes(cur))
    prev = cur
def cells(x, n):
    return b''.join(rows[y][x * cw * 4:(x + n) * cw * 4] for y in range(ch))
bg = rows[-1][:4]
replacement = cells(6, 2)
for x, n, what in [(0, 1, 'A'), (1, 1, 'the box-drawing line'), (2, 2, 'the CJK ideograph'), (4, 2, 'the emoji')]:
    block = cells(x, n)
    if block == bg * (len(block) // 4):
        sys.exit(f"{what} drew nothing")
    if n == 2 and block == replacement:
        sys.exit(f"{what} drew U+FFFD")
emoji = cells(4, 2)
if not any(max(emoji[i:i + 3]) - min(emoji[i:i + 3]) > 60 for i in range(0, len(emoji), 4)):
    sys.exit("the emoji has no color")
EOF
}

# expect REPLY RENDERER CELL [FIRST FACE]
expect() {
    python3 -c 'import json, sys; r = json.loads(sys.argv[1]); assert (r["renderer"], r["cell"]) == (sys.argv[2], sys.argv[3]) and (len(sys.argv) < 5 or r["faces"][1] == sys.argv[4]), r' "$@"
}

reply=$("$BIN" png "$id" "$dir/a.png" -j)
check "$dir/a.png" "$reply" || fail "the default fonts: $reply"
if [ "$variant" = lean ]; then
    expect "$reply" bitmap 8x16 || fail "lean draws with Unifont: $reply"
else
    expect "$reply" ttf 9x19 jetbrains || fail "the default is JetBrains Mono at 14 pixels: $reply"
fi
reply=$(TUPPET_PNG_FONTS=bitmap "$BIN" png "$id" "$dir/b.png" -j)
check "$dir/b.png" "$reply" || fail "TUPPET_PNG_FONTS=bitmap: $reply"
expect "$reply" bitmap 8x16 || fail "bitmap draws with Unifont in 8x16 cells: $reply"

# A TrueType file goes first at the given size; under bitmap it is skipped.
ttf=$(ls "$root"/zig-pkg/*/fonts/ttf/JetBrainsMono-Regular.ttf 2>/dev/null | head -n 1 || true)
if [ "$variant" != lean ]; then
    [ -n "$ttf" ] || fail "no JetBrainsMono-Regular.ttf under $root/zig-pkg; build tuppet in this checkout first"
    cp "$ttf" "$dir/user.ttf"
    reply=$("$BIN" png "$id" "$dir/u.png" -f "$dir/user.ttf,default" --font-size 20 -j)
    check "$dir/u.png" "$reply" || fail "a TrueType file: $reply"
    expect "$reply" ttf 12x27 "$dir/user.ttf" || fail "the TrueType file did not draw first at 20 pixels: $reply"
fi
# Full builds embed a CJK font, which then sets the cell; medium ones
# name the build that has it.
if [ "$variant" = full ]; then
    reply=$("$BIN" png "$id" "$dir/k.png" -f cjk -j)
    check "$dir/k.png" "$reply" || fail "-f cjk: $reply"
    expect "$reply" ttf 7x21 cjk || fail "-f cjk did not draw with the CJK font first: $reply"
elif [ "$variant" = medium ]; then
    if "$BIN" png "$id" "$dir/k.png" -f cjk 2>"$dir/err"; then fail "-f cjk rendered in a medium build"; fi
    grep -q "does not include cjk; a full build does" "$dir/err" || fail "-f cjk in medium: $(cat "$dir/err")"
fi
printf 'junk' >"$dir/bad.ttf"
reply=$("$BIN" png "$id" "$dir/b.png" -f "$dir/bad.ttf,bitmap" -j) || fail "bitmap did not skip a TrueType file"
expect "$reply" bitmap 8x16 || fail "bitmap with a TrueType file: $reply"

# A font file goes first and sets the cell; a changed file is read anew.
printf '0041:%s\n' "$(printf 'F%.0s' $(seq 32))" >"$dir/f.hex"
reply=$("$BIN" png "$id" "$dir/c.png" -f "$dir/f.hex" -j)
python3 -c 'import json, sys; r = json.loads(sys.argv[1]); assert r["faces"][1].endswith("/f.hex") and r["cell"] == "8x16", r' "$reply" ||
    fail "the hex font did not draw first: $reply"
printf '0041:%s\n0042:%s\n' "$(printf '0%.0s' $(seq 64))" "$(printf '0%.0s' $(seq 64))" >"$dir/f.hex"
(cd "$dir" && "$BIN" png "$id" d.png -f ./f.hex) || fail "a relative font path failed"
cmp -s "$dir/c.png" "$dir/d.png" && fail "the daemon kept the old font after the file changed"

# Relative paths in the config file start at its directory.
mkdir "$dir/conf"
cp "$dir/f.hex" "$dir/conf/rel.hex"
printf '[png]\nfonts = ["rel.hex"]\n[png.presets]\nbig = { fonts = "default", size = 20 }\n' >"$dir/conf/config.toml"
reply=$(cd / && TUPPET_CONFIG="$dir/conf/config.toml" "$BIN" png "$id" "$dir/r.png" -j)
python3 -c 'import json, sys; r = json.loads(sys.argv[1]); assert r["faces"][1] == sys.argv[2], r' "$reply" "$dir/conf/rel.hex" ||
    fail "a relative path in the config did not start at its directory: $reply"

# The size of a preset given with -f beats TUPPET_PNG_FONT_SIZE.
if [ "$variant" != lean ]; then
    reply=$(TUPPET_CONFIG="$dir/conf/config.toml" TUPPET_PNG_FONT_SIZE=10 "$BIN" png "$id" "$dir/r.png" -f big -j)
    expect "$reply" ttf 12x27 || fail "TUPPET_PNG_FONT_SIZE beat the size of a preset given with -f: $reply"
fi

# A font of bitmap sizes only refuses a size far from all of them.
if [ "$variant" != lean ]; then
    printf '%s\n' 'STARTFONT 2.1' 'FONT -x-big-medium-r-normal--128-1280-75-75-c-640-iso10646-1' 'SIZE 128 75 75' \
        'FONTBOUNDINGBOX 64 128 0 -32' 'STARTPROPERTIES 5' 'PIXEL_SIZE 128' 'FONT_ASCENT 96' 'FONT_DESCENT 32' \
        'CHARSET_REGISTRY "ISO10646"' 'CHARSET_ENCODING "1"' 'ENDPROPERTIES' 'CHARS 1' 'STARTCHAR A' 'ENCODING 65' \
        'SWIDTH 500 0' 'DWIDTH 64 0' 'BBX 1 1 0 0' 'BITMAP' '80' 'ENDCHAR' 'ENDFONT' >"$dir/big.bdf"
    if "$BIN" png "$id" "$dir/e.png" -f "$dir/big.bdf" 2>"$dir/err"; then fail "a 128-pixel bitmap font rendered at 14 pixels"; fi
    grep -q "its bitmap sizes, 128 to 128 pixels, are all far from the font size 14" "$dir/err" || fail "a far bitmap size: $(cat "$dir/err")"
    "$BIN" png "$id" "$dir/e.png" -f "$dir/big.bdf" --font-size 32 || fail "a 128-pixel bitmap font at 32 pixels"
fi

# Errors name the font.
if "$BIN" png "$id" "$dir/e.png" -f nosuch 2>"$dir/err"; then fail "an unknown font name rendered"; fi
grep -q "unknown font 'nosuch'" "$dir/err" || fail "unknown font: $(cat "$dir/err")"
printf 'junk' >"$dir/bad.psf"
if "$BIN" png "$id" "$dir/e.png" -f "$dir/bad.psf" 2>"$dir/err"; then fail "a broken font rendered"; fi
grep -q "bad.psf: " "$dir/err" || fail "broken font: $(cat "$dir/err")"
if "$BIN" png "$id" "$dir/e.png" -f "$dir/bad.ttf" 2>"$dir/err"; then fail "a corrupt TrueType font rendered"; fi
if [ "$variant" = lean ]; then
    grep -q "bad.ttf: this tuppet build (lean) has no TrueType support" "$dir/err" || fail "TrueType in lean: $(cat "$dir/err")"
else
    grep -q "bad.ttf: FreeType cannot read it" "$dir/err" || fail "corrupt TrueType font: $(cat "$dir/err")"
fi
"$BIN" list >/dev/null || fail "the daemon died"
echo "PASS: png size and glyphs ($variant), bitmap, font files and reloads, font errors"
