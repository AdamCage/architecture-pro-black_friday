#!/bin/bash
set -euo pipefail

echo "Total docs via mongos:"
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
print(db.helloDoc.countDocuments())
EOF

echo "Docs on shard1 (via RS URI -> primary):"
docker compose exec -T shard1-1 mongosh "mongodb://shard1-1:27018,shard1-2:27018,shard1-3:27018/somedb?replicaSet=shard1RS" --quiet <<'EOF'
print(db.helloDoc.countDocuments())
EOF

echo "Docs on shard2 (via RS URI -> primary):"
docker compose exec -T shard2-1 mongosh "mongodb://shard2-1:27018,shard2-2:27018,shard2-3:27018/somedb?replicaSet=shard2RS" --quiet <<'EOF'
print(db.helloDoc.countDocuments())
EOF

echo "Shard distribution (mongos):"
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
db.helloDoc.getShardDistribution()
EOF
