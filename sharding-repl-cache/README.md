# sharding-repl-cache

Variant 2 of the scheme: MongoDB sharding (2 shards) + replication (3 replicas in every replica set)
+ Redis caching of the application responses.

```
                ┌──► redis (cache)
                │                                 ┌──► config_server: configSrv-1 (PRIMARY), configSrv-2, configSrv-3 (SECONDARY)
pymongo_api ────┴──► mongos_router ───────────────┼──► shard1:        shard1-1    (PRIMARY), shard1-2,    shard1-3    (SECONDARY)
                                                  └──► shard2:        shard2-1    (PRIMARY), shard2-2,    shard2-3    (SECONDARY)
```

| Service                                     | Role                                                   | Port                        |
|---------------------------------------------|--------------------------------------------------------|-----------------------------|
| `configSrv-1`, `configSrv-2`, `configSrv-3` | config server, replica set `config_server` (3 members) | 27019                       |
| `shard1-1`, `shard1-2`, `shard1-3`          | shard 1, replica set `shard1` (3 members)              | 27018                       |
| `shard2-1`, `shard2-2`, `shard2-3`          | shard 2, replica set `shard2` (3 members)              | 27018                       |
| `mongos_router`                             | query router (`mongos`)                                | 27017 (published to host)   |
| `redis`                                     | cache (Redis)                                          | 6379 (internal only)        |
| `pymongo_api`                               | application                                            | 8080 (published to host)    |

Database: `somedb`. Collection: `helloDoc`, sharded by the hashed key `{ name: "hashed" }`.

Each shard is a replica set: the PRIMARY accepts writes and replicates them to the two SECONDARY members.
If the PRIMARY fails, the remaining members elect a new one, so the shard stays available.

Caching is enabled in the application with the environment variable `REDIS_URL: "redis://redis:6379"`
(see `pymongo_api` in `compose.yaml`). Responses of the endpoint `/<collection_name>/users` are stored
in Redis for 60 seconds, so repeated calls are answered from the cache without going to MongoDB.

## How to run

All commands are run from the `sharding-repl-cache` directory.

Requirements: Docker with Docker Compose v2 and a bash shell (Linux / macOS terminal;
on Windows use Git Bash or WSL, the script does not run in cmd or PowerShell).

> If another project from this repository is running, stop it first (`docker compose down` in its directory),
> because ports 8080/27017 and the container names (`pymongo_api`, `mongos_router`, `shard1-1`, ...) are shared.

### 1. Start the containers

```shell
docker compose up -d
```

Wait until all `configSrv-*`, `shard*-*` and `redis` containers are `healthy`:

```shell
docker compose ps
```

> Until step 2 is done the cluster is not initialized, so http://localhost:8080 answers
> `Internal Server Error`. This is expected — open the application after the initialization.

### 2. Initialize replication and sharding, fill the database

Run the script, which does all the steps below automatically:

```shell
./scripts/mongo-init.sh
```

The output shows the state of every replica set, the total count and the count on every replica, for example:

```
config_server is ready: configSrv-1:27019 PRIMARY, configSrv-2:27019 SECONDARY, configSrv-3:27019 SECONDARY
shard1 is ready: shard1-1:27018 PRIMARY, shard1-2:27018 SECONDARY, shard1-3:27018 SECONDARY
shard2 is ready: shard2-1:27018 PRIMARY, shard2-2:27018 SECONDARY, shard2-3:27018 SECONDARY
...
Total documents (via mongos_router): 1000
==> 5. Documents on each replica of each shard
shard1-1: PRIMARY   492
shard1-2: SECONDARY 492
shard1-3: SECONDARY 492
shard2-1: PRIMARY   508
shard2-2: SECONDARY 508
shard2-3: SECONDARY 508
```

The script can be run again safely: already initialized replica sets and existing data are left as they are.

> If something goes wrong (for example, data volumes are left over from an earlier unfinished run),
> start from scratch: `docker compose down -v`, then repeat steps 1 and 2.

Redis needs no initialization: it starts together with the other containers.

#### What the script does (the same steps can be run manually)

1. Initialize the config server replica set (3 members):

   ```shell
   docker compose exec -T configSrv-1 mongosh --port 27019 --quiet <<EOF
   rs.initiate({
     _id: "config_server",
     configsvr: true,
     members: [
       { _id: 0, host: "configSrv-1:27019" },
       { _id: 1, host: "configSrv-2:27019" },
       { _id: 2, host: "configSrv-3:27019" }
     ]
   })
   EOF
   ```

2. Initialize the replica set of each shard (3 members each):

   ```shell
   docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
   rs.initiate({
     _id: "shard1",
     members: [
       { _id: 0, host: "shard1-1:27018" },
       { _id: 1, host: "shard1-2:27018" },
       { _id: 2, host: "shard1-3:27018" }
     ]
   })
   EOF

   docker compose exec -T shard2-1 mongosh --port 27018 --quiet <<EOF
   rs.initiate({
     _id: "shard2",
     members: [
       { _id: 0, host: "shard2-1:27018" },
       { _id: 1, host: "shard2-2:27018" },
       { _id: 2, host: "shard2-3:27018" }
     ]
   })
   EOF
   ```

   Wait 10–20 seconds until every replica set elects a PRIMARY. Check it with:

   ```shell
   docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval 'rs.status().members.map(m => m.name + " " + m.stateStr)'
   ```

3. Register the shards (as replica sets) in the router, enable sharding for `somedb`, shard `helloDoc`
   and insert 1000 documents.

   `mongos_router` accepts connections only after the config server replica set is initialized, which can take
   up to a minute. Repeat this command until it prints `{ ok: 1, ... }` instead of `ECONNREFUSED`:

   ```shell
   docker compose exec -T mongos_router mongosh --port 27017 --quiet --eval "db.adminCommand('ping')"
   ```

   Then run:

   ```shell
   docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
   sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
   sh.addShard("shard2/shard2-1:27018,shard2-2:27018,shard2-3:27018")
   sh.enableSharding("somedb")
   sh.shardCollection("somedb.helloDoc", { name: "hashed" })
   use somedb
   for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({age: i, name: "ly" + i})
   EOF
   ```

## How to check

### In the application

Open http://localhost:8080 (or `http://<VM ip>:8080` on the provided virtual machine;
the ip can be found with `curl --silent http://ifconfig.me`).

The response contains:

- `mongo_topology_type: "Sharded"`, `mongo_is_mongos: true`;
- `collections.helloDoc.documents_count` – total number of documents (1000);
- `collections.helloDoc.shards_documents_count` – number of documents on each shard;
- `shards` – the shards with the hosts of their replicas;
- `shards_replicas_count` – number of replicas in each shard (3);
- `cache_enabled: true` – the application uses Redis.

```json
"collections": {
  "helloDoc": {
    "documents_count": 1000,
    "shards_documents_count": { "shard1": 492, "shard2": 508 }
  }
},
"shards": {
  "shard1": "shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018",
  "shard2": "shard2/shard2-1:27018,shard2-2:27018,shard2-3:27018"
},
"shards_replicas_count": { "shard1": 3, "shard2": 3 },
"cache_enabled": true
```

Total count only: http://localhost:8080/helloDoc/count. Swagger: http://localhost:8080/docs.

### Caching

Call the cached endpoint several times and look at the response time:

```shell
for i in 1 2 3 4; do
  curl -s -o /dev/null -w "call $i: %{time_total}s\n" http://localhost:8080/helloDoc/users
done
```

The first call goes to MongoDB and takes about 1 second; the next calls are served from Redis in under 100 ms:

```
call 1: 1.057225s
call 2: 0.018291s
call 3: 0.009733s
call 4: 0.008432s
```

The cache entry lives for 60 seconds; after that the next call goes to MongoDB again.
The cached keys can be seen in Redis:

```shell
docker compose exec -T redis redis-cli keys '*'     # api:cache::<hash>
docker compose exec -T redis redis-cli flushall     # clear the cache
```

### With mongosh

```shell
# total number of documents (through the router)
docker compose exec -T mongos_router mongosh --port 27017 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'

# replica set members and their state
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval 'rs.status().members.map(m => m.name + " " + m.stateStr)'
docker compose exec -T shard2-1 mongosh --port 27018 --quiet --eval 'rs.status().members.map(m => m.name + " " + m.stateStr)'

# number of documents on a replica (a SECONDARY has the same data as its PRIMARY)
docker compose exec -T shard1-2 mongosh --port 27018 --quiet --eval 'db.getMongo().setReadPref("secondaryPreferred"); db.getSiblingDB("somedb").helloDoc.countDocuments()'

# data distribution between shards
docker compose exec -T mongos_router mongosh --port 27017 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.getShardDistribution()'
```

## Stop

```shell
docker compose down      # keep data
docker compose down -v   # remove data volumes as well
```
