import re
lines = []
try:
    for l in open("build.log", errors="replace"):
        if re.search(r"error:|ld: |Undefined symbols|fatal error|Could not resolve|failed to", l):
            lines.append(l.strip()[:300])
except FileNotFoundError:
    lines = ["build.log not found"]
seen = []
for l in lines:
    if l not in seen:
        seen.append(l)
for i in range(0, min(len(seen), 40), 4):
    chunk = "%0A".join(seen[i:i+4])
    print("::error title=build-error-%d::%s" % (i // 4, chunk))
