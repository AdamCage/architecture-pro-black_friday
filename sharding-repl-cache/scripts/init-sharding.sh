#!/bin/bash
set -euo pipefail

wait_ping() {
  local svc="$1"
  local port="$2"
  local tries="${3:-120}"

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

wait_primary_rs() {
  local exec_svc="$1"
  local uri="$2"
  local tries="${3:-120}"

  for _ in $(seq 1 "$tries"); do
    if docker compose exec -T "$exec_svc" mongosh "$uri" --quiet --eval 'db.adminCommand({ hello: 1 }).isWritablePrimary' 2>/dev/null | grep -q "true"; then
      return 0
    fi
    sleep 1
  done
  echo "Timeout waiting RS primary: $uri"
  exit 1
}

echo "Waiting config servers..."
wait_ping configSrv1 27019
wait_ping configSrv2 27019
wait_ping configSrv3 27019

echo "Waiting shards..."
wait_ping shard1-1 27018
wait_ping shard1-2 27018
wait_ping shard1-3 27018
wait_ping shard2-1 27018
wait_ping shard2-2 27018
wait_ping shard2-3 27018

echo "Init configReplSet (idempotent)..."
docker compose exec -T configSrv1 mongosh --port 27019 --quiet <<'EOF'
let initiated = false;
try { initiated = (rs.status().ok === 1); } catch(e) { initiated = false; }

if (!initiated) {
  rs.initiate({
    _id: "configReplSet",
    configsvr: true,
    members: [
      { _id: 0, host: "configSrv1:27019", priority: 2 },
      { _id: 1, host: "configSrv2:27019", priority: 1 },
      { _id: 2, host: "configSrv3:27019", priority: 1 }
    ]
  });
}
EOF

wait_primary_rs configSrv1 "mongodb://configSrv1:27019,configSrv2:27019,configSrv3:27019/?replicaSet=configReplSet"

echo "Init shard1RS (idempotent)..."
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
let initiated = false;
try { initiated = (rs.status().ok === 1); } catch(e) { initiated = false; }

if (!initiated) {
  rs.initiate({
    _id: "shard1RS",
    members: [
      { _id: 0, host: "shard1-1:27018", priority: 2 },
      { _id: 1, host: "shard1-2:27018", priority: 1 },
      { _id: 2, host: "shard1-3:27018", priority: 1 }
    ]
  });
}
EOF

wait_primary_rs shard1-1 "mongodb://shard1-1:27018,shard1-2:27018,shard1-3:27018/?replicaSet=shard1RS"

echo "Init shard2RS (idempotent)..."
docker compose exec -T shard2-1 mongosh --port 27018 --quiet <<'EOF'
let initiated = false;
try { initiated = (rs.status().ok === 1); } catch(e) { initiated = false; }

if (!initiated) {
  rs.initiate({
    _id: "shard2RS",
    members: [
      { _id: 0, host: "shard2-1:27018", priority: 2 },
      { _id: 1, host: "shard2-2:27018", priority: 1 },
      { _id: 2, host: "shard2-3:27018", priority: 1 }
    ]
  });
}
EOF

wait_primary_rs shard2-1 "mongodb://shard2-1:27018,shard2-2:27018,shard2-3:27018/?replicaSet=shard2RS"

echo "Restart mongos (after configRS init) and wait it..."
docker compose restart mongos >/dev/null
wait_ping mongos 27017

echo "Add shards + enable sharding + pre-split/move chunk..."
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
function addShardIfMissing(id, connString) {
  const shards = (db.adminCommand({ listShards: 1 }).shards || []);
  if (!shards.find(s => s._id === id)) {
    db.adminCommand({ addShard: connString, name: id });
  }
}

addShardIfMissing("shard1", "shard1RS/shard1-1:27018,shard1-2:27018,shard1-3:27018");
addShardIfMissing("shard2", "shard2RS/shard2-1:27018,shard2-2:27018,shard2-3:27018");

try { sh.enableSharding("somedb"); } catch(e) {}

const somedb = db.getSiblingDB("somedb");
try { somedb.helloDoc.createIndex({ age: 1 }); } catch(e) {}
try { sh.shardCollection("somedb.helloDoc", { age: 1 }); } catch(e) {}

// Детерминированное распределение: <500 -> shard1, >=500 -> shard2
try { sh.splitAt("somedb.helloDoc", { age: 500 }); } catch(e) {}
try { sh.moveChunk("somedb.helloDoc", { age: 500 }, "shard2"); } catch(e) {}
EOF

echo "OK: replica sets + sharding initialized"
