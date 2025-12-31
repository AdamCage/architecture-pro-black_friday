#!/bin/bash
set -euo pipefail

wait_ping() {
  local svc="$1"
  local port="$2"
  local tries="${3:-90}"

  for _ in $(seq 1 "$tries"); do
    if docker compose exec -T "$svc" mongosh --port "$port" --quiet --eval 'db.adminCommand({ ping: 1 }).ok' 2>/dev/null | grep -q "1"; then
      return 0
    fi
    sleep 1
  done

  echo "Timeout waiting for $svc:$port"
  docker compose ps
  exit 1
}

wait_primary() {
  local svc="$1"
  local port="$2"
  local tries="${3:-90}"

  for _ in $(seq 1 "$tries"); do
    if docker compose exec -T "$svc" mongosh --port "$port" --quiet --eval 'db.adminCommand({ hello: 1 }).isWritablePrimary' 2>/dev/null | grep -q "true"; then
      return 0
    fi
    sleep 1
  done

  echo "Timeout waiting primary on $svc:$port"
  exit 1
}

echo "Waiting configSrv/shards..."
wait_ping configSrv 27019
wait_ping shard1 27018
wait_ping shard2 27018

echo "Init configRS (idempotent)..."
docker compose exec -T configSrv mongosh --port 27019 --quiet <<'EOF'
let initiated = false;
try { initiated = (rs.status().ok === 1); } catch(e) { initiated = false; }
if (!initiated) {
  rs.initiate({
    _id: "configReplSet",
    configsvr: true,
    members: [{ _id: 0, host: "configSrv:27019" }]
  });
}
EOF
wait_primary configSrv 27019

echo "Init shard1RS (single node, idempotent)..."
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
let initiated = false;
try { initiated = (rs.status().ok === 1); } catch(e) { initiated = false; }
if (!initiated) {
  rs.initiate({_id:"shard1RS", members:[{_id:0, host:"shard1:27018"}]});
}
EOF
wait_primary shard1 27018

echo "Init shard2RS (single node, idempotent)..."
docker compose exec -T shard2 mongosh --port 27018 --quiet <<'EOF'
let initiated = false;
try { initiated = (rs.status().ok === 1); } catch(e) { initiated = false; }
if (!initiated) {
  rs.initiate({_id:"shard2RS", members:[{_id:0, host:"shard2:27018"}]});
}
EOF
wait_primary shard2 27018

echo "Restart mongos and wait it..."
docker compose restart mongos >/dev/null
wait_ping mongos 27017

echo "Add shards + enable sharding + pre-split/move chunk..."
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
function addShardIfMissing(name, connString) {
  const shards = (db.adminCommand({ listShards: 1 }).shards || []);
  if (!shards.find(s => s._id === name)) {
    db.adminCommand({ addShard: connString, name });
  }
}

addShardIfMissing("shard1", "shard1RS/shard1:27018");
addShardIfMissing("shard2", "shard2RS/shard2:27018");

try { sh.enableSharding("somedb"); } catch(e) {}

const somedb = db.getSiblingDB("somedb");
try { somedb.helloDoc.createIndex({ age: 1 }); } catch(e) {}
try { sh.shardCollection("somedb.helloDoc", { age: 1 }); } catch(e) {}

try { sh.splitAt("somedb.helloDoc", { age: 500 }); } catch(e) {}
try { sh.moveChunk("somedb.helloDoc", { age: 500 }, "shard2"); } catch(e) {}
EOF

echo "Done."
