#!/bin/bash
set -euo pipefail

echo "Total docs via mongos:" 
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
print(db.helloDoc.countDocuments())
EOF

echo "Docs on shard1:" 
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
use somedb
print(db.helloDoc.countDocuments())
EOF

echo "Docs on shard2:" 
docker compose exec -T shard2 mongosh --port 27018 --quiet <<'EOF'
use somedb
print(db.helloDoc.countDocuments())
EOF

echo "Shard distribution (mongos):" 
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
db.helloDoc.getShardDistribution()
EOF
