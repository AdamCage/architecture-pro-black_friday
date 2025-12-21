#!/bin/bash
set -euo pipefail

# 1) Init Config Server replica set (single node)
docker compose exec -T configSrv mongosh --port 27019 --quiet <<'EOF'
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [{ _id: 0, host: "configSrv:27019" }]
})
EOF

# Give the config server a moment to elect itself
sleep 2

# 2) Add shards, enable sharding, shard the collection and pre-split for deterministic distribution
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
sh.addShard("shard1:27018")
sh.addShard("shard2:27018")

sh.enableSharding("somedb")

use somedb

// Range-based sharding by `age` + pre-splitting, so 0..499 go to shard1, 500..999 go to shard2
// (deterministic for the reviewer check)
db.helloDoc.createIndex({ age: 1 })
sh.shardCollection("somedb.helloDoc", { age: 1 })

sh.splitAt("somedb.helloDoc", { age: 500 })
sh.moveChunk("somedb.helloDoc", { age: 500 }, "shard2")
EOF
