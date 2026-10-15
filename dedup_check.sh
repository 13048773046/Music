#!/bin/bash
# 线上推荐去重实测：两次匿名推荐，对比返回 id 交集
set -u
echo "== 曲库规模 =="
sqlite3 /www/wwwroot/music/tracks.db "SELECT 'tracks='||COUNT(*) FROM tracks WHERE offline=0 UNION ALL SELECT 'collected='||COUNT(*) FROM collected_tracks WHERE offline=0;"
echo "== 第一次推荐 =="
R1=$(curl -s "http://127.0.0.1:8788/api/recommend?userId=dedup_probe")
echo "$R1" | python3 -c "import json,sys; d=json.load(sys.stdin); print('count=',len(d)); print('ids=', ','.join(x['id'] for x in d))"
echo "== 第二次推荐 =="
R2=$(curl -s "http://127.0.0.1:8788/api/recommend?userId=dedup_probe")
echo "$R2" | python3 -c "import json,sys; d=json.load(sys.stdin); print('count=',len(d)); print('ids=', ','.join(x['id'] for x in d))"
echo "== 交集 =="
python3 - <<'PY'
import json, urllib.request
def fetch():
    r = urllib.request.urlopen("http://127.0.0.1:8788/api/recommend?userId=dedup_probe2")
    return json.load(r)
a = fetch(); b = fetch()
ida = {x['id'] for x in a}; idb = {x['id'] for x in b}
print("first=", len(ida), "second=", len(idb), "overlap=", len(ida & idb))
print("overlap ids:", list(ida & idb)[:8])
PY
