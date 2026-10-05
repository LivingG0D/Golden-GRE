#!/bin/bash
# Point an x-ui VLESS outbound at a new address, safely (run on the x-ui server, as root):
# used to move Turkey-Multipath-GoldenGRE onto a Golden GRE tunnel's overlay address.
#  1. back up the x-ui database and the current outbound (root-only files)
#  2. change only that outbound's address in the panel template (exact text replace) so a panel/xray restart keeps it
#  3. hot-swap it in the running xray over its API (no restart)
#  4. write a rollback script
# usage: xui-set-outbound-address.sh <old_address> <new_address> [outbound_tag]
# Rollback afterwards: /root/golden-gre-rollback.sh (written by this script).
set -u
OLD=${1:?old address}
NEW=${2:?new address}
TAG=${3:-Turkey-Multipath-GoldenGRE}
DB=/etc/x-ui/x-ui.db
XRAY=/usr/local/x-ui/bin/xray-linux-amd64
API=127.0.0.1:62789
TS=$(date +%Y%m%d-%H%M%S)
umask 077

echo "== 1. backups"
sqlite3 "$DB" ".backup /root/x-ui.db.bak-golden-gre-$TS" && echo "db backup: /root/x-ui.db.bak-golden-gre-$TS"
python3 - "$DB" "$TAG" "$OLD" "$NEW" "$TS" <<'PY'
import json, sqlite3, sys
db_path, tag, old, new, ts = sys.argv[1:6]
db = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
raw = db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]
t = json.loads(raw)
ob = next(o for o in t["outbounds"] if o["tag"] == tag)
assert ob["settings"]["vnext"][0]["address"] == old, "outbound address is not %s" % old
json.dump({"outbounds": [ob]}, open("/root/xui-outbound-before-golden-gre-%s.json" % ts, "w"), indent=2)
new_ob = json.loads(json.dumps(ob))
new_ob["settings"]["vnext"][0]["address"] = new
json.dump({"outbounds": [new_ob]}, open("/root/xui-outbound-golden-gre-%s.json" % ts, "w"), indent=2)
print("outbound saved before/after (address %s -> %s)" % (old, new))
PY

echo "== 2. panel template (database)"
python3 - "$DB" "$OLD" "$NEW" <<'PY'
import json, sqlite3, sys
db_path, old, new = sys.argv[1:4]
db = sqlite3.connect(db_path, timeout=20)
raw = db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]
needle = '"address": "%s"' % old
assert raw.count(needle) == 1, "expected exactly one %s in the template, found %d" % (needle, raw.count(needle))
fixed = raw.replace(needle, '"address": "%s"' % new, 1)
a, b = json.loads(raw), json.loads(fixed)
changed = [o["tag"] for o, p in zip(a["outbounds"], b["outbounds"]) if o != p]
assert changed == ["Turkey-Multipath-GoldenGRE"], changed
assert len(fixed) - len(raw) == len(new) - len(old)
with db:
    db.execute("update settings set value=? where key='xrayTemplateConfig'", (fixed,))
print("template updated; only outbound changed:", changed)
PY

echo "== 3. hot-swap in the running xray"
BEFORE=/root/xui-outbound-before-golden-gre-$TS.json
AFTER=/root/xui-outbound-golden-gre-$TS.json
"$XRAY" api rmo -s "$API" "$TAG" 2>&1 | head -3
if "$XRAY" api ado -s "$API" "$AFTER" 2>&1 | head -3; then :; fi
count=$("$XRAY" api lso -s "$API" 2>&1 | grep -c "$TAG")
echo "outbound present in running xray: $count mention(s)"
if [ "$count" -lt 1 ]; then
  echo "!! outbound missing, restoring the old one"
  "$XRAY" api ado -s "$API" "$BEFORE" 2>&1 | head -3
fi

echo "== 4. rollback script"
cat > /root/golden-gre-rollback.sh <<EOF
#!/bin/bash
# Put Turkey-Multipath-GoldenGRE back on $OLD (template + running xray). Written $TS.
python3 - <<'PY'
import sqlite3
db = sqlite3.connect("$DB", timeout=20)
raw = db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]
needle = '"address": "$NEW"'
assert raw.count(needle) == 1, "template does not contain exactly one $NEW"
with db:
    db.execute("update settings set value=? where key='xrayTemplateConfig'", (raw.replace(needle, '"address": "$OLD"', 1),))
print("template restored")
PY
$XRAY api rmo -s $API $TAG
$XRAY api ado -s $API $BEFORE
echo "running xray restored"
EOF
chmod 700 /root/golden-gre-rollback.sh
echo "rollback: /root/golden-gre-rollback.sh"
echo "== xray still healthy: $(pgrep -fc 'bin/xray-linux-amd64 -c') process(es), x-ui $(systemctl is-active x-ui)"
