#!/usr/bin/env python3
# usage: drive.py <pixel|fire> <cmd> [args]   cmds: shot NAME | dump | tap REGEX [nth] | tapxy X Y | swipe X1 Y1 X2 Y2 [ms] | text STR | key CODE | back | launch | current | logmark TAG
import sys, os, re, subprocess, time

dev = sys.argv[1]; cmd = sys.argv[2]; args = sys.argv[3:]
ADB_L = ["adb", "-s", "8A8X0N6BY"]
def adb(*a, binary=False, binaryout=False):
    if dev == "pixel":
        r = subprocess.run(ADB_L + [str(x) for x in a], capture_output=True)
    else:
        joined = " ".join(str(x).replace(" ", "\\ ").replace("$", "\\$").replace('"', '\\"') for x in a)
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", "nuc",
            f"/home/abspuser/tools/platform-tools/adb -s G090MJ05736402TB {joined}"], capture_output=True)
    if r.returncode != 0 and not binaryout:
        sys.stderr.write(r.stderr.decode("utf-8", "ignore")[:300])
    return r.stdout

OUT = f"/home/phan/ka_uni/audit/{dev}"; os.makedirs(OUT, exist_ok=True)
XML = f"/tmp/dump-{dev}.xml"

def dump_xml():
    adb("shell", "uiautomator", "dump", "/sdcard/d.xml")
    open(XML, "wb").write(adb("exec-out", "cat", "/sdcard/d.xml", binaryout=True))
    return open(XML, encoding="utf-8", errors="ignore").read()

def nodes(x):
    out = []
    for m in re.finditer(r"<node\b[^>]*/?>", x):
        n = m.group(0)
        def g(k):
            mm = re.search(k + r'="([^"]*)"', n)
            return mm.group(1) if mm else ""
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        if not b: continue
        x1, y1, x2, y2 = map(int, b.groups())
        label = (g("text") or g("content-desc")).strip()
        out.append(dict(label=label, clickable=g("clickable") == "true",
            cls=g("class").split(".")[-1], cx=(x1+x2)//2, cy=(y1+y2)//2,
            x1=x1, y1=y1, x2=x2, y2=y2, enabled=g("enabled") == "true",
            scrollable=g("scrollable") == "true"))
    return out

def ensure_foreground():
    """Abort before touching the screen if KA.Uni isn't the resumed activity.
    The user shares this device; a stray tap into another app is unacceptable."""
    out = adb("shell", "dumpsys", "activity", "activities").decode("utf-8", "ignore")
    m = re.search(r"mResumedActivity.*?\s(\S+/\S+)", out)
    cur = m.group(1) if m else "?"
    if "com.dandemidov.kit_mobile" not in cur:
        print(f"NOT_FOREGROUND current={cur} — aborting (refusing to touch other apps)")
        sys.exit(3)

if cmd in {"tap", "tapxy", "swipe", "text", "key", "back"}:
    ensure_foreground()

if cmd == "shot":
    open(f"{OUT}/{args[0]}.png", "wb").write(adb("exec-out", "screencap", "-p", binaryout=True))
elif cmd == "dump":
    ns = nodes(dump_xml())
    for i, n in enumerate(ns):
        if not n["label"]: continue
        kind = "TAP" if (n["clickable"] or n["cls"] in ("Button", "EditText", "CheckBox", "Switch")) else "info"
        if n["y2"] < 0: continue
        print(f"{i}\t{kind}\t{n['cx']} {n['cy']}\t{n['label'][:70]}\t{n['cls']}")
elif cmd == "tap":
    pat = args[0]; nth = int(args[1]) if len(args) > 1 else 0
    ns = nodes(dump_xml())
    hits = [n for n in ns if n["label"] and re.search(pat, n["label"], re.I)]
    if not hits:
        print("NOMATCH", pat); sys.exit(1)
    n = hits[min(nth, len(hits)-1)]
    adb("shell", "input", "tap", str(n["cx"]), str(n["cy"]))
    print(f"tapped [{n['label'][:40]}] at {n['cx']},{n['cy']} ({len(hits)} hits)")
elif cmd == "tapxy":
    adb("shell", "input", "tap", args[0], args[1]); print("tapxy ok")
elif cmd == "swipe":
    ms = args[4] if len(args) > 4 else "450"
    adb("shell", "input", "swipe", *args[:4], ms); print("swipe ok")
elif cmd == "text":
    adb("shell", "input", "text", args[0]); print("text ok")
elif cmd == "key":
    adb("shell", "input", "keyevent", args[0]); print("key ok")
elif cmd == "back":
    adb("shell", "input", "keyevent", "4")
elif cmd == "launch":
    adb("shell", "monkey", "-p", "com.dandemidov.kit_mobile", "-c", "android.intent.category.LAUNCHER", "1")
elif cmd == "current":
    out = adb("shell", "dumpsys", "activity", "activities").decode("utf-8", "ignore")
    m = re.search(r"mResumedActivity.*?\s(\S+/\S+)", out)
    print(m.group(1) if m else "?")
elif cmd == "logmark":
    adb("shell", "log", "-t", "KAUNI_AUDIT", args[0])
