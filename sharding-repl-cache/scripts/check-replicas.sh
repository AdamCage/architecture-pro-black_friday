#!/bin/bash
set -euo pipefail

echo "Config RS members:"
docker compose exec -T configSrv1 mongosh "mongodb://configSrv1:27019,configSrv2:27019,configSrv3:27019/?replicaSet=configReplSet" --quiet --eval \
'const s=rs.status(); print("members="+s.members.length); printjson(s.members.map(m=>({name:m.name,state:m.stateStr})))'

echo
echo "Shard1 RS members:"
docker compose exec -T shard1-1 mongosh "mongodb://shard1-1:27018,shard1-2:27018,shard1-3:27018/?replicaSet=shard1RS" --quiet --eval \
'const s=rs.status(); print("members="+s.members.length); printjson(s.members.map(m=>({name:m.name,state:m.stateStr})))'

echo
echo "Shard2 RS members:"
docker compose exec -T shard2-1 mongosh "mongodb://shard2-1:27018,shard2-2:27018,shard2-3:27018/?replicaSet=shard2RS" --quiet --eval \
'const s=rs.status(); print("members="+s.members.length); printjson(s.members.map(m=>({name:m.name,state:m.stateStr})))'
