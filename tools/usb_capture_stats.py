#!/usr/bin/env python3
"""Summarize an MSI Xpander USB capture exported by tshark (no third-party modules).

Usage:
  tshark -r capture.pcapng -Y "usb.idVendor == 0x0db0 || usb.bus_id" \
         -T fields -E separator=, -e frame.time_relative -e usb.endpoint_address \
         -e usb.transfer_type -e usb.data_len -e usb.capdata > capture.csv
  python3 tools/usb_capture_stats.py capture.csv

Prints: packets per endpoint, a size histogram, and every packet whose payload
starts with (or contains at offset 0) the bulk magic  <kind> 2b c6 a1, grouped by kind.
Kind 1 is the full-frame JPEG the open driver already sends; any other kind, or
many tiny packets while only the mouse moves, is the evidence we are looking for.
"""
import sys, csv, collections

MAGIC = bytes.fromhex("2bc6a1")

def main(path):
    per_ep = collections.Counter(); sizes = collections.Counter(); kinds = collections.defaultdict(list); n = 0
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if len(row) < 5: continue
            t, ep, ttype, dlen, data = row[:5]
            if not dlen or not dlen.isdigit(): continue
            n += 1; dlen = int(dlen); per_ep[(ep, ttype)] += 1
            bucket = "<64" if dlen < 64 else "<1K" if dlen < 1024 else "<16K" if dlen < 16384 else "<128K" if dlen < 131072 else ">=128K"
            sizes[bucket] += 1
            raw = bytes.fromhex(data.replace(":", "")) if data else b""
            if len(raw) >= 20 and raw[1:4] == MAGIC and raw[17:20] == MAGIC:
                kind = raw[0]; length = int.from_bytes(raw[4:8], "little"); seq = int.from_bytes(raw[8:12], "little"); unknown = raw[12:16].hex()
                kinds[kind].append((float(t), length, seq, unknown, dlen))
    print(f"packets with data: {n}")
    print("per endpoint/transfer-type:", dict(per_ep))
    print("size histogram:", dict(sizes))
    for kind, rows in sorted(kinds.items()):
        lens = sorted(r[1] for r in rows); uniq_unknown = collections.Counter(r[3] for r in rows)
        print(f"\nkind 0x{kind:02x}: {len(rows)} headers; declared length min/median/max = {lens[0]}/{lens[len(lens)//2]}/{lens[-1]}")
        print(f"  unknown bytes [12..16] distinct values: {len(uniq_unknown)} e.g. {list(uniq_unknown.items())[:6]}")
        if len(rows) > 1:
            gaps = [b[0] - a[0] for a, b in zip(rows, rows[1:])]; gaps.sort()
            print(f"  header interval median {gaps[len(gaps)//2]*1000:.1f} ms  (≈{1/max(gaps[len(gaps)//2],1e-6):.0f} per second)")
        for r in rows[:5]: print("  ", r)

if __name__ == "__main__":
    if len(sys.argv) != 2: sys.exit(__doc__)
    main(sys.argv[1])
