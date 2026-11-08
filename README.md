# pymongo-api: MongoDB sharding, replication and Redis caching

The final solution is in the **`sharding-repl-cache`** directory (tasks 2, 3 and 4):

- MongoDB sharding: 2 shards (`shard1`, `shard2`) behind the router `mongos_router`;
- replication: config server replica set (`configSrv-1..3`) and every shard is a replica set of 3 members
  (`shard1-1..3`, `shard2-1..3`);
- Redis cache for the application (`redis`);
- the application `pymongo_api` on port 8080.

## Repository contents

| Path                                                     | Task | Description                                                         |
|----------------------------------------------------------|------|---------------------------------------------------------------------|
| `mongodb-sharding-replication-caching-scaling-cdn.drawio` | 1, 5, 6 | Final scheme: sharding + replication + Redis, horizontal scaling with API Gateway and Consul, CDN in several regions (PNG export: `mongodb-sharding-replication-caching-scaling-cdn.png`) |
| `mongo-sharding/`                                        | 2    | MongoDB with 2 shards                                               |
| `mongo-sharding-repl/`                                   | 3    | MongoDB with 2 shards, each a replica set of 3 members              |
| `sharding-repl-cache/`                                   | 4    | **Final solution:** sharding + replication + Redis cache            |

Every project directory has its own `README.md` with the details.

## How to run the final solution

Requirements: Docker with Docker Compose v2 and a bash shell
(Linux / macOS terminal; on Windows use Git Bash or WSL).

> If another project from this repository is running, stop it first (`docker compose down` in its directory):
> the projects share ports 8080/27017 and container names.

### 1. Start the containers

```shell
cd sharding-repl-cache
docker compose up -d
```

Check that all 12 services are running and the `configSrv-*`, `shard*-*` and `redis` containers are `healthy`:

```shell
docker compose ps
```

Until step 2 is done the cluster is not initialized and http://localhost:8080 answers `Internal Server Error` —
this is expected.

### 2. Initialize replication and sharding, fill the database

```shell
./scripts/mongo-init.sh
```

The script initializes the replica sets, registers the shards in the router, shards the collection
`somedb.helloDoc` by the hashed key `{ name: "hashed" }` and inserts 1000 documents.
At the end it prints the number of documents on every replica of every shard.
The script can be run again safely.

## How to check

### MongoDB settings

Open http://localhost:8080 (on the provided virtual machine — `http://<VM ip>:8080`,
the ip can be found with `curl --silent http://ifconfig.me`).

The JSON response shows:

- `"mongo_topology_type": "Sharded"`, `"mongo_is_mongos": true` — the application works through `mongos_router`;
- `collections.helloDoc.documents_count` — 1000 documents;
- `shards` — 2 shards, each with the hosts of its 3 replicas:
  `"shard1": "shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018"`;
- `"cache_enabled": true` — the application uses Redis.

Distribution of the documents between the shards:

```shell
docker compose exec -T mongos_router mongosh --port 27017 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.getShardDistribution()'
```

State of the replica set members:

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval 'rs.status().members.map(m => m.name + " " + m.stateStr)'
```

### Cache

```shell
for i in 1 2 3; do
  curl -s -o /dev/null -w "call $i: %{time_total}s\n" http://localhost:8080/helloDoc/users
done
```

The first call goes to MongoDB (about 1 second), the next ones are served from Redis (< 100 ms).

Swagger with all endpoints: http://localhost:8080/docs.

## Stop

```shell
docker compose down -v
```
