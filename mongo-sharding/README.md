# mongo-sharding

Variant 1 of the scheme: MongoDB sharding with 2 shards.

```
pymongo_api ──► mongos_router ──► configSrv        (cluster metadata)
                              ├──► shard1          (data, part 1)
                              └──► shard2          (data, part 2)
```

| Service         | Role                                       | Port (default MongoDB port) |
|-----------------|--------------------------------------------|-----------------------------|
| `configSrv`     | config server, replica set `config_server` | 27019                       |
| `shard1`        | shard server, replica set `shard1`         | 27018                       |
| `shard2`        | shard server, replica set `shard2`         | 27018                       |
| `mongos_router` | query router (`mongos`)                    | 27017 (published to host)   |
| `pymongo_api`   | application                                | 8080 (published to host)    |

Database: `somedb`. Collection: `helloDoc`, sharded by the hashed key `{ name: "hashed" }`.

## How to run

All commands are run from the `mongo-sharding` directory.

Requirements: Docker with Docker Compose v2 and a bash shell (Linux / macOS terminal;
on Windows use Git Bash or WSL, the script does not run in cmd or PowerShell).

> If another project from this repository is running, stop it first (`docker compose down` in its directory),
> because ports 8080/27017 and the container name `pymongo_api` are shared.

### 1. Start the containers

```shell
docker compose up -d
```

Wait until `configSrv`, `shard1` and `shard2` are `healthy`:

```shell
docker compose ps
```

> Until step 2 is done the cluster is not initialized, so http://localhost:8080 answers
> `Internal Server Error`. This is expected — open the application after the initialization.

### 2. Initialize sharding and fill the database

Run the script, which does all the steps below automatically:

```shell
./scripts/mongo-init.sh
```

The last lines of its output show the total count and the count on each shard, for example:

```
Total documents (via mongos_router): 1000
==> 5. Documents on each shard
shard1: 492
shard2: 508
```

#### What the script does (the same steps can be run manually)

1. Initialize the config server replica set:

   ```shell
   docker compose exec -T configSrv mongosh --port 27019 --quiet <<EOF
   rs.initiate({_id: "config_server", configsvr: true, members: [{_id: 0, host: "configSrv:27019"}]})
   EOF
   ```

2. Initialize the replica set of each shard:

   ```shell
   docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
   rs.initiate({_id: "shard1", members: [{_id: 0, host: "shard1:27018"}]})
   EOF

   docker compose exec -T shard2 mongosh --port 27018 --quiet <<EOF
   rs.initiate({_id: "shard2", members: [{_id: 0, host: "shard2:27018"}]})
   EOF
   ```

3. Register the shards in the router, enable sharding for `somedb`, shard `helloDoc` and insert 1000 documents:

   ```shell
   docker compose exec -T mongos_router mongosh --port 27017 --quiet <<EOF
   sh.addShard("shard1/shard1:27018")
   sh.addShard("shard2/shard2:27018")
   sh.enableSharding("somedb")
   sh.shardCollection("somedb.helloDoc", { name: "hashed" })
   use somedb
   for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({age: i, name: "ly" + i})
   EOF
   ```

   Wait a few seconds after steps 1–2 before running step 3, so that the replica sets elect a primary
   and `mongos_router` connects to the config server.

## How to check

### In the application

Open http://localhost:8080 (or `http://<VM ip>:8080` on the provided virtual machine;
the ip can be found with `curl --silent http://ifconfig.me`).

The response contains:

- `mongo_topology_type: "Sharded"`, `mongo_is_mongos: true`;
- `shards` – the list of shards;
- `collections.helloDoc.documents_count` – total number of documents (1000);
- `collections.helloDoc.shards_documents_count` – number of documents on each shard.

```json
"collections": {
  "helloDoc": {
    "documents_count": 1000,
    "shards_documents_count": { "shard1": 492, "shard2": 508 }
  }
},
"shards": {
  "shard1": "shard1/shard1:27018",
  "shard2": "shard2/shard2:27018"
}
```

Total count only: http://localhost:8080/helloDoc/count. Swagger: http://localhost:8080/docs.

### With mongosh

```shell
# total number of documents (through the router)
docker compose exec -T mongos_router mongosh --port 27017 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'

# number of documents on each shard
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'
docker compose exec -T shard2 mongosh --port 27018 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'

# data distribution between shards
docker compose exec -T mongos_router mongosh --port 27017 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.getShardDistribution()'
```

## Stop

```shell
docker compose down      # keep data
docker compose down -v   # remove data volumes as well
```
