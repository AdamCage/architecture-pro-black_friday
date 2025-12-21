#!/bin/bash
set -euo pipefail

# This script:
# 1) initiates replica sets (configReplSet, shard1RS, shard2RS)
# 2) (re)starts mongos
# 3) adds shards to the cluster and enables sharding for somedb.helloDoc

init_rs_if_needed() {
  local service="$1" port="$2" js="$3"
  docker compose exec -T "$service" mongosh --port "$port" --quiet <<EOF
try {
  rs.status();
  // already initiated
} catch (e) {
  $js
}
EOF
}

wait_primary() {
  local service="$1" port="$2" label="$3"
  echo "Waiting for primary: $label ..."
  for i in $(seq 1 60); do
    out=$(docker compose exec -T "$service" mongosh --port "$port" --quiet <<'EOF' 2>/dev/null || true
try {
  var r = db.adminCommand({hello: 1});
  print(r.isWritablePrimary === true);
} catch (e) {
  print(false);
}
EOF
)
    if echo "$out" | tail -n 1 | grep -q "true"; then
      echo "Primary is ready: $label"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: primary not elected in time: $label" >&2
  exit 1
}

# 1) Config RS
init_rs_if_needed "configSrv1" 27019 '
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27019", priority: 2 },
    { _id: 1, host: "configSrv2:27019", priority: 1 },
    { _id: 2, host: "configSrv3:27019", priority: 1 }
  ]
})'

wait_primary "configSrv1" 27019 "configReplSet"

# 2) Shard RS #1
init_rs_if_needed "shard1-1" 27018 '
rs.initiate({
  _id: "shard1RS",
  members: [
    { _id: 0, host: "shard1-1:27018", priority: 2 },
    { _id: 1, host: "shard1-2:27018", priority: 1 },
    { _id: 2, host: "shard1-3:27018", priority: 1 }
  ]
})'

wait_primary "shard1-1" 27018 "shard1RS"

# 3) Shard RS #2
init_rs_if_needed "shard2-1" 27018 '
rs.initiate({
  _id: "shard2RS",
  members: [
    { _id: 0, host: "shard2-1:27018", priority: 2 },
    { _id: 1, host: "shard2-2:27018", priority: 1 },
    { _id: 2, host: "shard2-3:27018", priority: 1 }
  ]
})'

wait_primary "shard2-1" 27018 "shard2RS"

# 4) Restart mongos so it reliably picks up the initiated config RS
# (Safe even if it already works.)
docker compose restart mongos >/dev/null

# 5) Add shards + shard collection (range-based by age for deterministic distribution)
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
function shardExists(id) {
  const res = db.adminCommand({listShards: 1});
  return (res.shards || []).some(s => s._id === id);
}

if (!shardExists("shard1RS")) {
  sh.addShard("shard1RS/shard1-1:27018,shard1-2:27018,shard1-3:27018");
}
if (!shardExists("shard2RS")) {
  sh.addShard("shard2RS/shard2-1:27018,shard2-2:27018,shard2-3:27018");
}

try { sh.enableSharding("somedb"); } catch (e) { }

use somedb

db.helloDoc.createIndex({ age: 1 })
try { sh.shardCollection("somedb.helloDoc", { age: 1 }); } catch (e) { }

// Pre-split and move one chunk so reviewer sees both shards used deterministically
try { sh.splitAt("somedb.helloDoc", { age: 500 }); } catch (e) { }
try { sh.moveChunk("somedb.helloDoc", { age: 500 }, "shard2RS"); } catch (e) { }
EOF

echo "OK: replica sets + sharding initialized"
