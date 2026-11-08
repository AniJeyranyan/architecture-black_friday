#!/bin/bash
#
# Initializes MongoDB sharding (variant 1: config server + 2 shards + mongos)
# and fills somedb.helloDoc with 1000 documents.
# Run from the mongo-sharding directory after `docker compose up -d`.
#
set -e
cd "$(dirname "$0")/.."

echo "==> 1. Initialize the config server replica set (config_server)"
docker compose exec -T configSrv mongosh --port 27019 --quiet <<EOF
try {
  rs.initiate({
    _id: "config_server",
    configsvr: true,
    members: [{ _id: 0, host: "configSrv:27019" }]
  });
} catch (e) { print("config_server: " + e.codeName); }
while (!db.hello().isWritablePrimary) { sleep(1000); }
print("config_server is ready");
EOF

echo "==> 2. Initialize the shard replica sets (shard1, shard2)"
for shard in shard1 shard2; do
docker compose exec -T "$shard" mongosh --port 27018 --quiet <<EOF
try {
  rs.initiate({
    _id: "$shard",
    members: [{ _id: 0, host: "$shard:27018" }]
  });
} catch (e) { print("$shard: " + e.codeName); }
while (!db.hello().isWritablePrimary) { sleep(1000); }
print("$shard is ready");
EOF
done

echo "==> 3. Wait for mongos_router to connect to the config server"
for attempt in $(seq 1 30); do
  if docker compose exec -T mongos_router mongosh --port 27017 --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; then
    echo "mongos_router is ready"
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    echo "ERROR: mongos_router is not reachable after 60 seconds." >&2
    echo "Check its logs: docker compose logs mongos_router" >&2
    exit 1
  fi
  sleep 2
done

echo "==> 4. Register the shards, shard somedb.helloDoc and insert 1000 documents"
docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
sh.addShard("shard1/shard1:27018");
sh.addShard("shard2/shard2:27018");

sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { name: "hashed" });

db = db.getSiblingDB("somedb");
if (db.helloDoc.countDocuments() === 0) {
  const docs = [];
  for (let i = 0; i < 1000; i++) docs.push({ age: i, name: "ly" + i });
  const res = db.helloDoc.insertMany(docs);
  print("Inserted: " + Object.keys(res.insertedIds).length);
}
print("Total documents (via mongos_router): " + db.helloDoc.countDocuments());
EOF

echo "==> 5. Documents on each shard"
for shard in shard1 shard2; do
  count=$(docker compose exec -T "$shard" mongosh --port 27018 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()')
  echo "$shard: $count"
done
