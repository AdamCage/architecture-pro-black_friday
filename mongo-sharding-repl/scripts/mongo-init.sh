#!/bin/bash
set -euo pipefail

# Fill the sharded collection through mongos
# Expected total docs >= 1000

docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
for (var i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({ age: i, name: "ly" + i })
}
EOF
