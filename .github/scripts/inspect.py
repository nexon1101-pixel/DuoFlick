import json, subprocess, urllib.request

def notice(title, text):
    print("::notice title=%s::%s" % (title, text))

notice("xcode", subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.replace("\n", " "))
try:
    info = json.loads(subprocess.run(["brew", "info", "xcodegen", "--json"], capture_output=True, text=True).stdout)
    notice("xcodegen", info[0]["versions"]["stable"])
except Exception as e:
    notice("xcodegen", "unknown %s" % e)

for m in ["zenz-v3-small-gguf", "zenz-v3.1-small-gguf", "zenz-v3-xsmall-gguf", "zenz-v3.1-xsmall-gguf"]:
    try:
        with urllib.request.urlopen("https://huggingface.co/api/models/Miwa-Keita/%s?blobs=true" % m, timeout=30) as r:
            d = json.load(r)
        notice(m, ", ".join("%s=%.1fMB" % (f["rfilename"], (f.get("size") or 0) / 1e6) for f in d["siblings"]))
    except Exception as e:
        notice(m, "none (%s)" % e)
