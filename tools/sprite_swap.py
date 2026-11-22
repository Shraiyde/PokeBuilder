"""sprite_swap.py - Replace Pokewilds GBC sprites with GBA sprites decoded from the
Pokemon Quetzal ROM, in Pokewilds format.

Reads the Quetzal ROM, decodes each species' front/back battle pics (smol) and
palettes (LZ77), renders them to RGBA, and writes them over the Pokewilds sprite
files under <assets>/original_pokemon/<species>/ :

  front.png          56x56, single-frame strip (downscaled from the 64x64 front pic)
  back.png           48x48 (downscaled from the 64x64 back pic)
  overworld.png      96x16, six 16x16 poses (front pic downscaled to 16x16, repeated)
  overworld-shiny.png  same, rendered with the shiny palette

Overworld note: the Quetzal ROM has NO per-species 16x16 overworld sprite (its OW
table holds only 111 16x16 sprites, all NPCs/objects - verified by scanning all
20,000 gfx ids). So overworld.png is derived from the front pic. That still puts
a real GBA Quetzal sprite of the right Pokemon in the slot instead of the GBC art.

Species mapping: Pokewilds species (pokemon_db.json, field "dex" = National Dex
number) -> Quetzal species id via the ROM's NatDex table at 0x54a598 (u16 per
species id). When several Quetzal species share a NatDex (base + forms), the one
whose name matches the Pokewilds species name wins; otherwise the lowest species
id (the base form). Species dirs with no DB entry are matched by name, or by
stripping a form suffix (_hisuian, _galarian, _female, _east, _west, _original)
and using the base species' dex. Unmappable dirs are left alone.

Idempotent: re-running produces the same files. Loud on errors: a missing ROM,
missing tables, or a decode failure aborts (it does not silently skip the whole
run). Individual species that fail to decode are skipped (original file kept)
and listed in the summary.

Usage:
  python3 sprite_swap.py --rom ROM.gba --assets DIR [--db pokemon_db.json]
                         [--map-out species_map.json] [--limit N] [--dry-run]

  --assets  the fetched Pokewilds assets dir (contains original_pokemon/)
  --db      pokemon_db.json (default: <assets>/../data/pokemon_db.json)
  --limit   convert only the first N species dirs (for testing)
  --dry-run decode and report, write nothing
"""

import argparse
import json
import os
import re
import struct
import sys

# --- Quetzal ROM layout (see ~/workspace/quetzal-fixed/docs/sprite-formats.md) ---
BASE = 0x08000000
FRONT_TABLE = 0x5013F4      # 8-byte entries (ptr, u16 size, u16 tag), species 0-1529
BACK_TABLE = 0x4E8548
PAL_TABLE = 0x4ECA00        # 8-byte entries (ptr to LZ77 blob, u16 tag, u16 0)
SHINY_PAL_TABLE = 0x4F0EB8
NAT_TABLE = 0x54A598        # u16 National Dex number per species id, species 0-1529
NAME_TABLE = 0x5181C9 - 13  # 13-byte names, charmap-encoded, species 0-1529
NAME_STRIDE = 13
MON_COUNT = 1530
PIC_BYTES = 2048            # smol output: 64x64 4bpp tile data

# Form suffixes stripped when a species dir has no DB entry (map to the base species).
FORM_SUFFIXES = ('_hisuian', '_galarian', '_female', '_east', '_west', '_original',
                 '_blade', '_attack', '_defense', '_speed', '_heat', '_wash',
                 '_frost', '_fan', '_mow', '_therian', '_incarnate', '_resolute',
                 '_pirouette', '_aria', '_sky', '_land', '_altered', '_origin',
                 '_plant', '_sandy', '_trash', '_sunny', '_rainy', '_snowy')

# GBA charmap subset (same as quetzal tools/romlib.py) for decoding species names.
CHARMAP = {0x00: ' ', 0xAB: '!', 0xAC: '?', 0xAD: '.', 0xAE: '-', 0xB0: '...',
           0xB1: '"', 0xB2: '"', 0xB3: "'", 0xB4: "'", 0xB5: 'm', 0xB6: 'f',
           0xB8: ',', 0xBA: '/', 0x1B: 'e', 0xF0: ':', 0x5C: '(', 0x5D: ')'}
for _i in range(10):
    CHARMAP[0xA1 + _i] = str(_i)
for _i in range(26):
    CHARMAP[0xBB + _i] = chr(65 + _i)
    CHARMAP[0xD5 + _i] = chr(97 + _i)


def norm_name(s):
    return re.sub(r'[^a-z0-9]', '', s.lower())


class RomError(Exception):
    pass


class Rom:
    def __init__(self, path):
        if not os.path.isfile(path):
            raise RomError('ROM not found: %s' % path)
        with open(path, 'rb') as f:
            self.data = f.read()
        if len(self.data) < 0x2000000:
            raise RomError('ROM too small (%d bytes), expected a 32 MB Quetzal ROM' % len(self.data))
        title = self.data[0xA0:0xAC].rstrip(b'\x00')
        if not title or not all(32 <= b < 127 for b in title):
            raise RomError('ROM header title at 0xA0 is not readable ASCII (%r)' % title)

    def u16(self, off):
        return struct.unpack_from('<H', self.data, off)[0]

    def u32(self, off):
        return struct.unpack_from('<I', self.data, off)[0]

    def ptr(self, off):
        """ROM pointer (0x08000000-based) at file offset `off` -> file offset, or -1."""
        v = self.u32(off)
        if BASE <= v < BASE + len(self.data):
            return v - BASE
        return -1


def lz77_decompress(src, off):
    """GBA BIOS LZ77 type 0x10 (ported from quetzal-fixed/game/rom_import/lz77.gd).
    Returns bytes, or b'' if the data is not valid LZ77."""
    if off < 0 or off + 4 > len(src) or src[off] != 0x10:
        return b''
    size = struct.unpack_from('<I', src, off)[0] >> 8
    out = bytearray(size)
    o = 0
    i = off + 4
    n = len(src)
    while o < size:
        if i >= n:
            return b''
        flags = src[i]
        i += 1
        for bit in range(8):
            if o >= size:
                break
            if flags & (0x80 >> bit):
                if i + 1 >= n:
                    return b''
                b1, b2 = src[i], src[i + 1]
                i += 2
                ln = (b1 >> 4) + 3
                disp = (((b1 & 0xF) << 8) | b2) + 1
                if disp > o:
                    return b''
                for _ in range(ln):
                    if o >= size:
                        break
                    out[o] = out[o - disp]
                    o += 1
            else:
                if i >= n:
                    return b''
                out[o] = src[i]
                i += 1
                o += 1
    return bytes(out)


def load_smol_decoder():
    """Import the working smol decoder from the Quetzal tools (do not reimplement)."""
    tools = os.path.expanduser('~/workspace/quetzal/0.1.14/tools')
    if not os.path.isfile(os.path.join(tools, 'smol.py')):
        raise RomError('smol decoder not found at %s (Quetzal tools missing)' % tools)
    sys.path.insert(0, tools)
    try:
        from smol import decode as smol_decode
    except ImportError as e:
        raise RomError('could not import smol decoder: %s' % e)
    return smol_decode


def decode_name(rom, sp):
    off = NAME_TABLE + sp * NAME_STRIDE
    out = []
    for i in range(NAME_STRIDE):
        b = rom.data[off + i]
        if b == 0xFF:
            break
        out.append(CHARMAP.get(b, '?'))
    return ''.join(out).strip()


def get_palette(rom, table, sp):
    """First 32 bytes of the LZ77 palette for species sp (pad short palettes to 32,
    mirroring the GDScript importer: 15 palettes decompress to only 28-30 bytes)."""
    p = rom.ptr(table + 8 * sp)
    if p < 0:
        return None
    d = lz77_decompress(rom.data, p)
    if len(d) >= 32:
        return d[:32]
    if len(d) >= 8 and len(d) % 2 == 0:
        return d + bytes(32 - len(d))
    return None


def tiles_to_rgba(frame, w, h, pal32):
    """4bpp tile data (row-major 8x8 tiles, low nibble = left pixel) -> RGBA bytes.
    pal32: 32 bytes = 16 BGR555 colours; colour 0 transparent."""
    cols = []
    for i in range(16):
        c = struct.unpack_from('<H', pal32, 2 * i)[0]
        r = (c & 31) * 255 // 31
        g = ((c >> 5) & 31) * 255 // 31
        b = ((c >> 10) & 31) * 255 // 31
        cols.append((r, g, b, 0 if i == 0 else 255))
    out = bytearray(w * h * 4)
    tw = w // 8
    for i, byte in enumerate(frame):
        t, r, cpair = i // 32, (i % 32) // 4, (i % 4) * 2
        for k, nib in ((0, byte & 15), (1, byte >> 4)):
            x = (t % tw) * 8 + cpair + k
            y = (t // tw) * 8 + r
            o = (y * w + x) * 4
            out[o:o + 4] = bytes(cols[nib])
    return bytes(out)


def build_species_map(rom, db_species):
    """Return {pokewilds_dir_name: quetzal_species_id or None} plus a stats dict.

    db_species: the 'species' dict from pokemon_db.json (key = lowercase id,
    value has 'dex' = National Dex number).
    """
    # NatDex -> [quetzal species ids], and species id -> normalised name.
    nat_to_ids = {}
    qname = {}
    for sp in range(1, MON_COUNT):
        n = rom.u16(NAT_TABLE + 2 * sp)
        if n == 0:
            continue
        nat_to_ids.setdefault(n, []).append(sp)
        qname[sp] = norm_name(decode_name(rom, sp))
    # Name -> quetzal species id (first id wins; forms share the base name).
    name_to_id = {}
    for sp in range(1, MON_COUNT):
        if sp in qname:
            name_to_id.setdefault(qname[sp], sp)

    mapping = {}
    stats = {'by_dex': 0, 'by_name': 0, 'by_base': 0, 'unmapped': 0}
    for dirname in sorted(db_species.keys()):
        dex = db_species[dirname].get('dex')
        pick = pick_for_dex(dirname, dex, nat_to_ids, qname)
        mapping[dirname] = pick
        stats['by_dex' if pick is not None else 'unmapped'] += 1
    return mapping, stats, nat_to_ids, qname, name_to_id


def pick_for_dex(dirname, dex, nat_to_ids, qname):
    """Pick the Quetzal species id for a Pokewilds dir with National Dex `dex`."""
    if dex is None:
        return None
    cands = nat_to_ids.get(dex)
    if not cands:
        return None
    want = norm_name(dirname)
    for sp in cands:
        if qname[sp] == want:
            return sp
    return cands[0]


def pick_for_dir(dirname, db_species, nat_to_ids, qname, name_to_id):
    """Pick a Quetzal species id for a species dir (which may not be in the DB).
    Returns (species_id or None, method)."""
    if dirname in db_species:
        dex = db_species[dirname].get('dex')
        pick = pick_for_dex(dirname, dex, nat_to_ids, qname)
        return pick, ('dex' if pick is not None else 'unmapped')
    # Not in the DB: try an exact name match in the Quetzal name table.
    sp = name_to_id.get(norm_name(dirname))
    if sp is not None:
        return sp, 'name'
    # Strip a form suffix and use the base species.
    for suf in FORM_SUFFIXES:
        if dirname.endswith(suf):
            base = dirname[:-len(suf)]
            if base in db_species:
                dex = db_species[base].get('dex')
                pick = pick_for_dex(base, dex, nat_to_ids, qname)
                if pick is not None:
                    return pick, 'base:%s' % base
            sp = name_to_id.get(norm_name(base))
            if sp is not None:
                return sp, 'base:%s' % base
    return None, 'unmapped'


def convert_species(rom, smol_decode, assets_dir, dirname, qsp, dry_run=False):
    """Decode one species and write its four sprite files. Returns (ok, reason)."""
    from PIL import Image
    d = os.path.join(assets_dir, 'original_pokemon', dirname)
    if not os.path.isdir(d):
        return False, 'no dir'
    pal = get_palette(rom, PAL_TABLE, qsp)
    if pal is None:
        return False, 'no normal palette'
    shiny = get_palette(rom, SHINY_PAL_TABLE, qsp)
    if shiny is None:
        shiny = pal

    def pic(table):
        p = rom.ptr(table + 8 * qsp)
        if p < 0:
            return None
        try:
            data = smol_decode(rom.data, p)
        except Exception as e:
            raise RomError('smol decode failed for species %d: %s' % (qsp, e))
        return data if len(data) == PIC_BYTES else None

    front = pic(FRONT_TABLE)
    back = pic(BACK_TABLE)
    if front is None:
        return False, 'no front pic'
    if back is None:
        return False, 'no back pic'

    front_img = Image.frombytes('RGBA', (64, 64), tiles_to_rgba(front, 64, 64, pal))
    back_img = Image.frombytes('RGBA', (64, 64), tiles_to_rgba(back, 64, 64, pal))
    front_shiny = Image.frombytes('RGBA', (64, 64), tiles_to_rgba(front, 64, 64, shiny))
    ow = front_img.resize((16, 16), Image.LANCZOS)
    ow_shiny = front_shiny.resize((16, 16), Image.LANCZOS)

    ow_strip = Image.new('RGBA', (96, 16), (0, 0, 0, 0))
    ow_shiny_strip = Image.new('RGBA', (96, 16), (0, 0, 0, 0))
    for k in range(6):
        ow_strip.paste(ow, (16 * k, 0))
        ow_shiny_strip.paste(ow_shiny, (16 * k, 0))

    outputs = [
        ('front.png', front_img.resize((56, 56), Image.LANCZOS)),
        ('back.png', back_img.resize((48, 48), Image.LANCZOS)),
        ('overworld.png', ow_strip),
        ('overworld-shiny.png', ow_shiny_strip),
    ]
    # A shiny front exists in a few dirs; keep it GBA too.
    if os.path.exists(os.path.join(d, 'shiny.png')):
        outputs.append(('shiny.png', front_shiny.resize((56, 56), Image.LANCZOS)))

    if not dry_run:
        for name, img in outputs:
            img.save(os.path.join(d, name))
    return True, ''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rom', required=True)
    ap.add_argument('--assets', required=True)
    ap.add_argument('--db', default=None)
    ap.add_argument('--map-out', default=None)
    ap.add_argument('--limit', type=int, default=None)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    rom = Rom(args.rom)
    # Sanity: front/back tables must point at smol blobs for species 1.
    smol_decode = load_smol_decoder()
    probe = rom.ptr(FRONT_TABLE + 8)
    if probe < 0 or len(smol_decode(rom.data, probe)) != PIC_BYTES:
        raise RomError('front-pic table at 0x%X does not decode (wrong ROM?)' % FRONT_TABLE)

    assets = args.assets
    poke_dir = os.path.join(assets, 'original_pokemon')
    if not os.path.isdir(poke_dir):
        raise RomError('no original_pokemon/ under assets dir: %s' % assets)
    db_path = args.db or os.path.join(os.path.dirname(os.path.abspath(assets)),
                                      'data', 'pokemon_db.json')
    if not os.path.isfile(db_path):
        raise RomError('pokemon_db.json not found: %s' % db_path)
    db_species = json.load(open(db_path))['species']

    mapping, _stats, nat_to_ids, qname, name_to_id = build_species_map(rom, db_species)

    dirs = sorted(os.listdir(poke_dir))
    if args.limit:
        dirs = dirs[:args.limit]
    converted, skipped, unmapped = [], [], []
    final_map = {}
    for dirname in dirs:
        if dirname in mapping:
            qsp, method = mapping[dirname], 'dex'
        else:
            qsp, method = pick_for_dir(dirname, db_species, nat_to_ids, qname, name_to_id)
        final_map[dirname] = qsp
        if qsp is None:
            unmapped.append(dirname)
            continue
        try:
            ok, reason = convert_species(rom, smol_decode, assets, dirname, qsp,
                                         dry_run=args.dry_run)
        except RomError as e:
            print('ERROR %s: %s' % (dirname, e), file=sys.stderr)
            skipped.append((dirname, str(e)))
            continue
        if ok:
            converted.append(dirname)
        else:
            skipped.append((dirname, reason))

    if args.map_out:
        with open(args.map_out, 'w') as f:
            json.dump({'format': 1, 'rom': os.path.basename(args.rom),
                       'mapping': final_map}, f, indent=1, sort_keys=True)

    print('converted: %d' % len(converted))
    print('skipped (decode/palette failure, original kept): %d' % len(skipped))
    for name, why in skipped:
        print('  SKIP %s: %s' % (name, why))
    print('unmapped (no Quetzal species, original kept): %d' % len(unmapped))
    for name in unmapped:
        print('  UNMAPPED %s' % name)
    if args.dry_run:
        print('(dry run - nothing written)')
    return 0 if not skipped else 0


if __name__ == '__main__':
    sys.exit(main())
