#!/bin/bash
set -euo pipefail

echo "Total docs via mongos:" 
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
print(db.helloDoc.countDocuments())
EOF

echo

echo "Shard distribution (mongos):"
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
db.helloDoc.getShardDistribution()
EOF

echo

echo "Shards + replica members (listShards):"
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
const r = db.adminCommand({listShards: 1});
for (const s of (r.shards || [])) {
  print(s._id + " => " + s.host);
}
EOF
