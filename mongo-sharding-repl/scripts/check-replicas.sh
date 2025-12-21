#!/bin/bash
set -euo pipefail

echo "Config RS members:" 
docker compose exec -T configSrv1 mongosh --port 27019 --quiet <<'EOF'
var st = rs.status();
print(st.set + ": " + st.members.length + " members");
for (const m of st.members) { print(" - " + m.name + " " + m.stateStr); }
EOF

echo

echo "Shard1 RS members:" 
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
var st = rs.status();
print(st.set + ": " + st.members.length + " members");
for (const m of st.members) { print(" - " + m.name + " " + m.stateStr); }
EOF

echo

echo "Shard2 RS members:" 
docker compose exec -T shard2-1 mongosh --port 27018 --quiet <<'EOF'
var st = rs.status();
print(st.set + ": " + st.members.length + " members");
for (const m of st.members) { print(" - " + m.name + " " + m.stateStr); }
EOF
