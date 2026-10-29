#!/usr/bin/env python3
"""SKK 辞書から、AzooKey の辞書にない語を選んで、キーボードに同梱する辞書ファイルを作る。

使い方:
  python3 tools/make_skk_dict.py <SKK辞書を置いた場所> <azooKey_dictionary_storage の場所>
  （SKK辞書: https://github.com/skk-dev/dict の SKK-JISYO.L / propernoun / jinmei / station）
出力: Keyboard/SkkDict/ （user.louds など。ライセンスは tools/SKK-LICENSE.md）
"""
import glob, os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from louds_writer import write_dict

skk_dir, storage = sys.argv[1], sys.argv[2]
louds_dir = os.path.join(storage, "Dictionary", "louds")
chid = open(os.path.join(louds_dir, "charID.chid"), encoding="utf8").read()
char2id = {c: i for i, c in enumerate(chid)}

# AzooKey に最初からある（読み, 語）
have = set()
for f in glob.glob(os.path.join(louds_dir, "*.loudstxt3")):
    d = open(f, "rb").read()
    cnt, = struct.unpack_from("<H", d, 0)
    offs = struct.unpack_from("<%dI" % cnt, d, 2) + (len(d),)
    for i in range(cnt):
        p = d[offs[i]:offs[i + 1]]
        n, = struct.unpack_from("<H", p, 0)
        if n == 0:
            continue
        t = p[2 + 10 * n:].decode("utf8", "replace").split("\t")
        for w in t[1:]:
            have.add((t[0], w or t[0]))
print("AzooKey の語数:", len(have))

KANA = re.compile(r"^[ぁ-ゖー]+$")
def kata(s): return "".join(chr(ord(c) + 96) if "ぁ" <= c <= "ゖ" else c for c in s)

def load(name):
    txt = open(os.path.join(skk_dir, name), encoding="euc-jp", errors="replace").read()
    sec, res = "nasi", []
    for line in txt.split("\n"):
        if line.startswith(";; okuri-ari"): sec = "ari"; continue
        if line.startswith(";; okuri-nasi"): sec = "nasi"; continue
        if line.startswith(";") or sec != "nasi" or " /" not in line: continue
        r, rest = line.split(" /", 1)
        if not KANA.match(r) or len(r) < 2: continue
        k = kata(r)
        if not all(c in char2id for c in k): continue
        for c in rest.strip("/").split("/"):
            w = c.split(";")[0]
            if not w or w.startswith("(") or w == r or "\t" in w: continue
            if (k, w) in have: continue
            res.append((k, w))
    return res

def kind_L(w):  # SKK-JISYO.L からは、英字まじりと、かな・漢字まじりの語だけ使う（漢字だけの珍しい熟語は除く）
    return bool(re.search(r"[A-Za-z]", w)) or not re.fullmatch(r"[一-龥々ヶ]+", w)

# (ファイル, 品詞ID(CID), スコア, 絞り込み)
CID_PROPER, CID_PERSON, CID_PLACE, MID = 1288, 1289, 1293, 501
sources = [
    ("SKK-JISYO.propernoun", CID_PROPER, -8.0, None),
    ("SKK-JISYO.jinmei",     CID_PERSON, -9.0, None),
    ("SKK-JISYO.station",    CID_PLACE,  -9.0, None),
    ("SKK-JISYO.L",          CID_PROPER, -9.0, kind_L),
]
seen, entries = set(), []
# 自分で選んだネット系の語（tools/net_words.tsv：読み<TAB>単語）。SKK より上の順位で足す
here = os.path.dirname(os.path.abspath(__file__))
n0 = 0
for line in open(os.path.join(here, "net_words.tsv"), encoding="utf8"):
    if "\t" not in line: continue
    r, w = line.rstrip("\n").split("\t", 1)
    k = kata(r)
    if w == k or not all(c in char2id for c in k) or (k, w) in have or (k, w) in seen: continue
    seen.add((k, w)); entries.append((k, w, CID_PROPER, CID_PROPER, MID, -6.0)); n0 += 1
print("net_words.tsv", n0)
for name, cid, score, flt in sources:
    n0 = len(entries)
    for k, w in load(name):
        if flt and not flt(w): continue
        if (k, w) in seen: continue
        seen.add((k, w))
        entries.append((k, w, cid, cid, MID, score))
    print(name, len(entries) - n0)
print("合計", len(entries))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Keyboard", "SkkDict")
for f in glob.glob(os.path.join(out, "user*")): os.remove(f)
write_dict(entries, char2id, out, "user")
print("書き出し:", os.path.normpath(out), sum(os.path.getsize(f) for f in glob.glob(out + "/*")) // 1024, "KB")
