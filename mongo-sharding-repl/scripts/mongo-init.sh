#!/bin/bash
#
# Initializes MongoDB sharding with replication (variant 2):
#   config server replica set (3 members) + 2 shards, each a replica set of 3 members + mongos.
# Fills somedb.helloDoc with 1000 documents.
# Run from the mongo-sharding-repl directory after `docker compose up -d`.
#
set -e
cd "$(dirname "$0")/.."

# init_replica_set <container> <port> <replica set name> <configsvr: true|false> <member> <member> <member>
# Runs rs.initiate on the first member and waits until all 3 members are PRIMARY/SECONDARY.
init_replica_set() {
  local container=$1 port=$2 name=$3 configsvr=$4
  shift 4
  local members="" i=0
  for host in "$@"; do
    members+="{ _id: $i, host: \"$host:$port\" },"
    i=$((i + 1))
  done
  docker compose exec -T "$container" mongosh --port "$port" --quiet <<EOF
try {
  rs.initiate({ _id: "$name", configsvr: $configsvr, members: [ $members ] });
} catch (e) { print("$name: " + e.codeName); }
// Wait until some member (not necessarily this one, e.g. after a failover) is PRIMARY
// and all the others are SECONDARY.
while (true) {
  try {
    const m = rs.status().members;
    if (m.some(x => x.state === 1) && m.every(x => x.state === 1 || x.state === 2)) break;
  } catch (e) {}
  sleep(1000);
}
print("$name is ready: " + rs.status().members.map(m => m.name + " " + m.stateStr).join(", "));
EOF
}

echo "==> 1. Initialize the config server replica set (config_server: 3 members)"
init_replica_set configSrv-1 27019 config_server true configSrv-1 configSrv-2 configSrv-3

echo "==> 2. Initialize the shard replica sets (shard1, shard2: 3 members each)"
init_replica_set shard1-1 27018 shard1 false shard1-1 shard1-2 shard1-3
init_replica_set shard2-1 27018 shard2 false shard2-1 shard2-2 shard2-3

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
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018");
sh.addShard("shard2/shard2-1:27018,shard2-2:27018,shard2-3:27018");

sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { name: "hashed" });

db = db.getSiblingDB("somedb");
if (db.helloDoc.countDocuments() === 0) {
  const docs = [];
  for (let i = 0; i < 1000; i++) docs.push({ age: i, name: "ly" + i });
  const res = db.helloDoc.insertMany(docs, { writeConcern: { w: "majority" } });
  print("Inserted: " + Object.keys(res.insertedIds).length);
}
print("Total documents (via mongos_router): " + db.helloDoc.countDocuments());
EOF

echo "==> 5. Documents on each replica of each shard"
for member in shard1-1 shard1-2 shard1-3 shard2-1 shard2-2 shard2-3; do
  info=$(docker compose exec -T "$member" mongosh --port 27018 --quiet --eval '
    db.getMongo().setReadPref("primaryPreferred");
    print(db.hello().isWritablePrimary ? "PRIMARY  " : "SECONDARY", db.getSiblingDB("somedb").helloDoc.countDocuments())')
  echo "$member: $info"
done
