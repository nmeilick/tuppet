#!/usr/bin/env bash
# Every release binary is one self-contained executable: Linux ones are
# static (no program interpreter, no needed libraries), macOS ones link
# only libSystem, and Windows ones import only the system DLLs below.
#
#     test/static.sh [DIR]
#
# checks every tuppet and tuppet.exe below DIR (default zig-out/matrix).
set -euo pipefail

python3 -I - "${1:-zig-out/matrix}" <<'EOF'
import os, struct, sys

# What Windows binaries may import, compared case-insensitively; the
# Universal C Runtime comes as api-ms-win-crt-*.dll API sets.
WINDOWS_DLLS = {"kernel32.dll", "ntdll.dll", "advapi32.dll"}
MACOS_DYLIBS = {"/usr/lib/libSystem.B.dylib"}


def cstr(data, off):
    end = data.index(b"\0", off)
    return data[off:end].decode("latin-1")


def elf(data):
    if data[4] != 2 or data[5] != 1:
        return ["not a 64-bit little-endian ELF file"]
    phoff, = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    problems, loads = [], 0
    for i in range(phnum):
        p_type, _, p_offset, _, _, p_filesz = struct.unpack_from("<IIQQQQ", data, phoff + i * phentsize)
        loads += p_type == 1
        if p_offset + p_filesz > len(data):
            raise ValueError("a segment overruns the file")
        if p_type == 3:
            problems.append("has a program interpreter (PT_INTERP)")
        elif p_type == 2:
            for j in range(0, p_filesz, 16):
                tag, = struct.unpack_from("<q", data, p_offset + j)
                if tag == 0:
                    break
                if tag == 1:
                    problems.append("needs a shared library (DT_NEEDED)")
    if loads == 0:
        problems.append("has no loadable segment")
    return problems


def macho(data):
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    end = 32 + sizeofcmds
    if end > len(data):
        raise ValueError("the load commands overrun the file")
    off, problems, linked = 32, [], set()
    # LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
    # LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB
    dylib_cmds = {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if size < 8 or off + size > end:
            raise ValueError(f"a load command at {off:#x} overruns the load commands")
        if cmd in dylib_cmds:
            name_off, = struct.unpack_from("<I", data, off + 8)
            name = cstr(data[:off + size], off + name_off)
            linked.add(name)
            if name not in MACOS_DYLIBS:
                problems.append(f"links {name}")
        off += size
    for name in sorted(MACOS_DYLIBS - linked):
        problems.append(f"does not link {name}")
    return problems


def pe(data):
    pe_off, = struct.unpack_from("<I", data, 0x3C)
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        return ["no PE header"]
    coff = pe_off + 4
    nsections, = struct.unpack_from("<H", data, coff + 2)
    opt_size, = struct.unpack_from("<H", data, coff + 16)
    opt = coff + 20
    if struct.unpack_from("<H", data, opt)[0] != 0x20B:
        return ["not a PE32+ file"]
    sections = []
    for i in range(nsections):
        s = opt + opt_size + i * 40
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, s + 8)
        sections.append((vaddr, min(vsize, rawsize), rawptr))

    def at(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size and rawptr + rva - vaddr < len(data):
                return rawptr + rva - vaddr
        raise ValueError(f"RVA {rva:#x} is in no section's file data")

    image_base, = struct.unpack_from("<Q", data, opt + 24)
    ndirs, = struct.unpack_from("<I", data, opt + 108)
    problems = []
    # The import table (1, 20-byte descriptors, name at 12) and the delay
    # import table (13, 32-byte descriptors, name at 4).
    for index, size, name_at in ((1, 20, 12), (13, 32, 4)):
        if index >= ndirs:
            continue
        rva, _ = struct.unpack_from("<II", data, opt + 112 + index * 8)
        if rva == 0:
            continue
        off = at(rva)
        while True:
            if off + size > len(data):
                raise ValueError("the import table overruns the file")
            if not any(data[off:off + size]):
                break
            name_rva, = struct.unpack_from("<I", data, off + name_at)
            # An old-style delay descriptor (attribute bit 0 clear) holds
            # virtual addresses rather than RVAs.
            if index == 13 and struct.unpack_from("<I", data, off)[0] & 1 == 0:
                name_rva -= image_base
            name = cstr(data, at(name_rva))
            lower = name.lower()
            if lower not in WINDOWS_DLLS and not lower.startswith("api-ms-win-crt-"):
                problems.append(f"imports {name}")
            off += size
    return problems


paths = sorted(os.path.join(root, f) for root, _, files in os.walk(sys.argv[1]) for f in files if f in ("tuppet", "tuppet.exe"))
if not paths:
    sys.exit(f"FAIL: no tuppet binaries below {sys.argv[1]}")
failed = False
for path in paths:
    data = open(path, "rb").read()
    if data[:4] == b"\x7fELF":
        kind, check = "ELF", elf
    elif data[:4] == b"\xcf\xfa\xed\xfe":
        kind, check = "Mach-O", macho
    elif data[:2] == b"MZ":
        kind, check = "PE", pe
    else:
        kind, check = "?", lambda _: ["not an ELF, 64-bit Mach-O, or PE file"]
    try:
        problems = check(data)
    except (struct.error, ValueError, IndexError) as err:
        problems = [f"malformed: {err}"]
    for p in problems:
        print(f"FAIL: {path} ({kind}): {p}", file=sys.stderr)
    failed = failed or bool(problems)
if failed:
    sys.exit(1)
print(f"PASS: {len(paths)} binaries are self-contained")
EOF
