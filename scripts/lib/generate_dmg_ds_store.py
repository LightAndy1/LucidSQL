#!/usr/bin/env python3
"""Deterministic macOS .DS_Store generator for DMG Finder window layout.

Generates a clean Bud1 B-tree .DS_Store with:
  - Fixed Finder window bounds (hidden toolbar, status bar, sidebar, tab bar)
  - Custom background image reference via Carbon HFS+ AliasRecord (v2)
  - Icon positions (Iloc) for LucidSQL.app, Applications, and hidden entries

Zero external Python packages, AppleScript, or live Finder GUI state required.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import struct
from typing import Iterable


def encode_hfs_alias_v2(volume_name: str, relative_parts: list[str]) -> bytes:
    """Build a minimal macOS AliasRecord (version 2) for '/.background/<file>'."""
    if not relative_parts:
        raise ValueError("relative_parts must not be empty")

    target_name = relative_parts[-1]
    vol_mac = volume_name[:27].encode("mac_roman", errors="replace")
    tgt_mac = target_name[:63].encode("mac_roman", errors="replace")

    vol_block = struct.pack(">B", len(vol_mac)) + vol_mac.ljust(27, b"\x00")
    tgt_block = struct.pack(">B", len(tgt_mac)) + tgt_mac.ljust(63, b"\x00")

    # Tagged extra records understood by Carbon/Finder alias resolution:
    #   tag 0: parent directory name
    #   tag 2: Carbon colon path (Vol:.background:bg.png)
    #   tag 14: target name UTF-16BE with char count prefix
    #   tag 15: volume name UTF-16BE with char count prefix
    #   tag 18: volume-relative POSIX path (/.background/bg.png)
    tags: list[tuple[int, bytes]] = []

    if len(relative_parts) >= 2:
        parent = relative_parts[-2].encode("utf-8")
        tags.append((0, parent))

    colon_path = f"{volume_name}:{':'.join(relative_parts)}".encode("utf-8")
    tags.append((2, colon_path))

    tgt_u16 = target_name.encode("utf-16-be")
    tags.append((14, struct.pack(">H", len(target_name)) + tgt_u16))

    vol_u16 = volume_name.encode("utf-16-be")
    tags.append((15, struct.pack(">H", len(volume_name)) + vol_u16))

    posix_rel = ("/" + "/".join(relative_parts)).encode("utf-8")
    tags.append((18, posix_rel))

    tagged_bytes = bytearray()
    for tag, payload in tags:
        tagged_bytes += struct.pack(">hH", tag, len(payload))
        tagged_bytes += payload
        if len(payload) % 2 == 1:
            tagged_bytes += b"\x00"
    tagged_bytes += struct.pack(">hH", -1, 0)

    # Fixed 150-byte AliasRecord v2 header before tagged entries:
    # appinfo(4) + recsize(2) + version(2) + kind(2) + volname(28) + voldate(4)
    # + fstype(2='H+') + disktype(2=5 fixed/other) + dirid(4) + fname(64) + fnum(4)
    # + fdate(4) + ftype(4) + fcreator(4) + nlvlFrom(2) + nlvlTo(2) + volattrs(4)
    # + volfsid(2) + reserved(10) = 150 bytes.
    total_size = 150 + len(tagged_bytes)
    header = struct.pack(
        ">4sHhH28sI2shI64sII4s4shhIH10s",
        b"\x00\x00\x00\x00",
        total_size,
        2,              # version 2
        0,              # kind: file
        vol_block,
        0,              # volume creation date
        b"H+",          # filesystem signature
        5,              # disk type (other)
        0,              # parent dir CNID (0 -> resolve by path)
        tgt_block,
        0,              # file CNID
        0,              # file creation date
        b"\x00\x00\x00\x00",
        b"\x00\x00\x00\x00",
        -1,             # nlvlFrom
        -1,             # nlvlTo
        0,              # volAttrs
        0,              # volFSId
        b"\x00" * 10,
    )
    assert len(header) == 150
    return header + bytes(tagged_bytes)


def encode_record(filename: str, record_type: str, data_type: str, value: bytes) -> bytes:
    """Encode a single DS_Store B-tree record."""
    name_u16 = filename.encode("utf-16-be")
    rec = bytearray()
    rec += struct.pack(">I", len(filename))
    rec += name_u16
    rec += record_type.encode("ascii")
    rec += data_type.encode("ascii")
    if data_type == "blob":
        rec += struct.pack(">I", len(value))
        rec += value
    elif data_type == "long":
        rec += value
    else:
        raise ValueError(f"Unsupported data_type: {data_type}")
    return bytes(rec)


def build_ds_store_bytes(records: Iterable[tuple[str, str, str, bytes]]) -> bytes:
    """Serialize DS_Store records into a valid Bud1 container with one B-tree leaf."""
    # Sort strictly by case-insensitive UTF-16 code units, matching Finder expectations.
    sorted_records = sorted(
        records,
        key=lambda r: (r[0].lower().encode("utf-16-be"), r[1].encode("ascii")),
    )
    encoded_recs = [encode_record(*r) for r in sorted_records]

    # Fixed 4096-byte blocks in the Bud1 buddy allocator after a 4-byte file header:
    #   file[0:4]   = b'\x00\x00\x00\x01'
    #   block 0 (addr 0x0020): Bud1 header (32 bytes, power-of-2 size 32) -> actually standard layout:
    #   Use 2048-byte file-space blocks with buddy addresses:
    #     root/header at offset 0x1000 (block size 2048, log2=11, addr = (0x1000 | 11) -> 0x100b)
    #     DSDB superblock at offset 0x2000 (size 32 bytes, log2=5 -> addr = 0x2005)
    #     B-tree root node at offset 0x3000 (size 4096 bytes, log2=12 -> addr = 0x300c)
    leaf_payload = struct.pack(">II", 0, len(encoded_recs)) + b"".join(encoded_recs)
    if len(leaf_payload) > 4096:
        raise ValueError(f"DS_Store leaf exceeded 4096 bytes ({len(leaf_payload)} bytes)")
    btree_node = leaf_payload.ljust(4096, b"\x00")

    root_block_num = 2  # points to btree_node at 0x3000
    dsdb_superblock = struct.pack(">IIIII", root_block_num, 0, len(encoded_recs), 1, 4096).ljust(32, b"\x00")

    # Allocator directory (at 0x1000, size 2048):
    #   count=3 offsets: [allocator_dir, dsdb, btree_node]
    #   followed by 256 table offsets? Standard DS_Store allocator:
    #     uint32 num_blocks
    #     uint32 unknown (0)
    #     uint32 addresses[num_blocks] padded up to 256 entries (or count + padded)
    #     uint32 num_dir_entries (1: b"DSDB" -> block_id 1)
    #     dir entry: uint8 name_len, name, uint32 block_id
    #     32 freelist buckets (power 0..31): each uint32 count (+ addresses)
    addr_alloc = 0x1000 | 11   # size 2048 (1 << 11)
    addr_dsdb = 0x2000 | 5     # size 32   (1 << 5)
    addr_btree = 0x3000 | 12   # size 4096 (1 << 12)

    alloc_buf = bytearray()
    alloc_buf += struct.pack(">II", 3, 0)
    alloc_buf += struct.pack(">III", addr_alloc, addr_dsdb, addr_btree)
    alloc_buf += struct.pack(">I", 0) * (256 - 3)
    alloc_buf += struct.pack(">I", 1)
    alloc_buf += struct.pack(">B4sI", 4, b"DSDB", 1)
    # 32 freelist buckets (5-bit..31-bit; mark rest unused/empty).
    # For a clean 16KB buddy arena (0x0000..0x4000), put unused 0x2000.. slots cleanly:
    for p in range(32):
        if p == 13:
            # Put a valid non-overlapping free block or zero lists; 0 free blocks is valid!
            alloc_buf += struct.pack(">I", 0)
        else:
            alloc_buf += struct.pack(">I", 0)

    alloc_padded = bytes(alloc_buf).ljust(2048, b"\x00")

    # 36-byte Bud1 header at file offset 0 (logical offset 0 -> data starts at file offset +4):
    # Note: Buddy allocator addresses are relative to file offset +4!
    # So:
    #   alloc_offset = 0x1000 -> file offset 0x1004
    #   dsdb_offset  = 0x2000 -> file offset 0x2004
    #   btree_offset = 0x3000 -> file offset 0x3004
    header = struct.pack(
        ">4s4sIII16s",
        b"\x00\x00\x00\x01",
        b"Bud1",
        0x1000,
        len(alloc_padded),
        0x1000,
        b"\x00" * 16,
    )

    out = bytearray(b"\x00" * (4 + 0x3000 + 4096))
    out[0:len(header)] = header
    out[4 + 0x1000 : 4 + 0x1000 + len(alloc_padded)] = alloc_padded
    out[4 + 0x2000 : 4 + 0x2000 + len(dsdb_superblock)] = dsdb_superblock
    out[4 + 0x3000 : 4 + 0x3000 + len(btree_node)] = btree_node
    return bytes(out)


def generate_dmg_ds_store(
    output_path: str,
    volume_name: str,
    background_rel_path: str,
    window_bounds: str = "{{220, 220}, {660, 448}}",
    icon_size: float = 112.0,
    text_size: float = 13.0,
    left_pos: tuple[int, int] = (190, 170),
    right_pos: tuple[int, int] = (470, 170),
    hidden_names: Iterable[str] = (".background", ".VolumeIcon.icns", ".fseventsd", ".Trashes"),
) -> None:
    rel_parts = [p for p in background_rel_path.strip("/").split("/") if p]
    alias_blob = encode_hfs_alias_v2(volume_name, rel_parts)

    bwsp_plist = plistlib.dumps(
        {
            "ContainerShowSidebar": False,
            "PreviewPaneVisibility": False,
            "ShowPathbar": False,
            "ShowSidebar": False,
            "ShowStatusBar": False,
            "ShowTabView": False,
            "ShowToolbar": False,
            "SidebarWidth": 0,
            "WindowBounds": window_bounds,
        },
        fmt=plistlib.FMT_BINARY,
    )

    icvp_plist = plistlib.dumps(
        {
            "arrangeBy": "none",
            "backgroundColorBlue": 0.988,
            "backgroundColorGreen": 0.961,
            "backgroundColorRed": 0.929,
            "backgroundImageAlias": alias_blob,
            "backgroundType": 2,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "iconSize": float(icon_size),
            "labelOnBottom": True,
            "showIconPreview": True,
            "showItemInfo": False,
            "textSize": float(text_size),
            "viewOptionsVersion": 1,
        },
        fmt=plistlib.FMT_BINARY,
    )

    def iloc_blob(x: int, y: int) -> bytes:
        return struct.pack(">IIQ", x, y, 0xFFFFFFFFFFFF0000)

    records: list[tuple[str, str, str, bytes]] = [
        (".", "bwsp", "blob", bwsp_plist),
        (".", "icvp", "blob", icvp_plist),
        (".", "vSrn", "long", struct.pack(">I", 1)),
        ("LucidSQL.app", "Iloc", "blob", iloc_blob(*left_pos)),
        ("Applications", "Iloc", "blob", iloc_blob(*right_pos)),
    ]

    for idx, name in enumerate(hidden_names):
        records.append((name, "Iloc", "blob", iloc_blob(1200, 100 + idx * 120)))

    data = build_ds_store_bytes(records)
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(data)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate deterministic .DS_Store for LucidSQL DMG")
    parser.add_argument("--output", required=True, help="Output .DS_Store path")
    parser.add_argument("--volume-name", default="LucidSQL", help="DMG volume name")
    parser.add_argument("--background-rel", default=".background/bg.png", help="Background path inside volume")
    args = parser.parse_args()
    generate_dmg_ds_store(
        output_path=args.output,
        volume_name=args.volume_name,
        background_rel_path=args.background_rel,
    )
    print(f"Generated {args.output}")


if __name__ == "__main__":
    main()
