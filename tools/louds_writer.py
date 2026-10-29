"""AzooKey（v0.9）の辞書ファイル（.louds / .loudschars2 / .loudstxt3）を書き出す。
LearningMemory.update と同じ形式。entries は (ruby, word, lcid, rcid, mid, score) の並び。"""
import struct, os
SPLIT = 2048

def write_dict(entries, char2id, out_dir, name="user"):
    # 読みごとにまとめる（スコアの高い順）
    by_ruby = {}
    for ruby, word, lcid, rcid, mid, score in entries:
        by_ruby.setdefault(ruby, []).append((word, lcid, rcid, mid, score))
    # トライ木
    nodes = [dict()]          # children: id -> node index
    data = [None]             # node index -> ruby (終端なら)
    for ruby in by_ruby:
        cur = 0
        for ch in ruby:
            cid = char2id[ch]
            nxt = nodes[cur].get(cid)
            if nxt is None:
                nodes.append(dict()); data.append(None)
                nxt = len(nodes) - 1
                nodes[cur][cid] = nxt
            cur = nxt
        data[cur] = ruby
    # 幅優先で並べる
    bits = [True, False]
    chars = [0, 0]
    blocks = [None, None]
    cur = sorted(nodes[0].items())
    bits += [True] * len(cur) + [False]
    while cur:
        nxt = []
        for ch, ni in cur:
            chars.append(ch)
            blocks.append(data[ni])
            kids = sorted(nodes[ni].items())
            bits += [True] * len(kids) + [False]
            nxt += kids
        cur = nxt
    # LOUDS ビット列（64bit ごと、先頭が最上位ビット、足りない分は 1 で埋める）
    pad = (-len(bits)) % 64
    bits += [True] * pad
    words = []
    for i in range(0, len(bits), 64):
        v = 0
        for b in bits[i:i+64]:
            v = (v << 1) | (1 if b else 0)
        words.append(v)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, name + ".louds"), "wb") as f:
        f.write(struct.pack("<%dQ" % len(words), *words))
    with open(os.path.join(out_dir, name + ".loudschars2"), "wb") as f:
        f.write(bytes(chars))
    # loudstxt3
    def entry(ruby):
        if ruby is None:
            return struct.pack("<H", 0)
        rows = by_ruby[ruby]
        b = struct.pack("<H", len(rows))
        for word, lcid, rcid, mid, score in rows:
            b += struct.pack("<HHHf", lcid, rcid, mid, score)
        text = "\t".join([ruby] + ["" if w == ruby else w for w in (r[0] for r in rows)])
        return b + text.encode("utf-8")
    payloads = [entry(r) for r in blocks]
    nfiles = len(payloads) // SPLIT + 1
    for k in range(nfiles):
        part = payloads[k*SPLIT:(k+1)*SPLIT]
        head_end = 2 + 4 * len(part)
        offs = []; o = head_end
        for p in part:
            offs.append(o); o += len(p)
        with open(os.path.join(out_dir, "%s%d.loudstxt3" % (name, k)), "wb") as f:
            f.write(struct.pack("<H", len(part)))
            f.write(struct.pack("<%dI" % len(offs), *offs))
            for p in part: f.write(p)
