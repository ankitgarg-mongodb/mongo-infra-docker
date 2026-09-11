#!/bin/bash

# Generates CRUD activity on every topology (standalone, replica set, sharded)
# so the MongoDB Agent OTLP dashboard shows spikes and usage.
#
# Each round, per topology:  insert DOCS_PER_ROUND docs, read all documents,
# delete half of the round's docs, update the other half.
# Defaults: ROUNDS=5 DOCS_PER_ROUND=1000  -> 5k inserts, 2.5k deletes, 2.5k updates.
#
#   ROUNDS=5 DOCS_PER_ROUND=1000 bash crud-workload.sh
#   SA_HOST / RS_HOST / SH_HOST override the connection strings (defaults match
#   the deployment the receiver stack is currently watching). The RS string uses
#   the seed list so mongosh finds the primary - single-host writes to a
#   secondary fail with "not primary".

ROUNDS=${ROUNDS:-5}
DOCS=${DOCS_PER_ROUND:-1000}
HALF=$((DOCS / 2))
SA_HOST=${SA_HOST:-127.0.0.1:27000}
RS_HOST=${RS_HOST:-myReplicaSet/127.0.0.1:27001,127.0.0.1:27002,127.0.0.1:27003}
SH_HOST=${SH_HOST:-127.0.0.1:27016}
PHASE_SLEEP=${PHASE_SLEEP:-1}

mongosh_eval() {
  local host=$1 db=$2 js=$3
  mongosh --quiet --host "$host" "$db" --eval "$js" 2>&1 | grep -v "^$"
}

run_topology() {
  local name=$1 host=$2 db=$3
  echo "[$name] starting crud on $host/$db"
  for round in $(seq 1 "$ROUNDS"); do
    local base=$(( (round - 1) * DOCS ))

    # insert this round's docs in batches of 500
    mongosh_eval "$host" "$db" "
      for (let b = 0; b < $DOCS; b += 500) {
        const docs = [];
        for (let i = 0; i < Math.min(500, $DOCS - b); i++) {
          docs.push({seq: $base + b + i, round: $round, val: Math.random(), payload: 'p'.repeat(128)});
        }
        db.crud.insertMany(docs);
      }
    " > /dev/null
    echo "[$name] round $round: inserted $DOCS"
    sleep "$PHASE_SLEEP"

    # read all documents currently in the collection
    mongosh_eval "$host" "$db" "
      let n = 0; const c = db.crud.find();
      while (c.hasNext()) { c.next(); n++; }
      print('[$name] round $round: read all ' + n + ' docs');
    "
    sleep "$PHASE_SLEEP"

    # delete the first half of this round's docs, one by one
    mongosh_eval "$host" "$db" "
      for (let i = 0; i < $HALF; i++) { db.crud.deleteOne({seq: $base + i}); }
    " > /dev/null
    echo "[$name] round $round: deleted $HALF"
    sleep "$PHASE_SLEEP"

    # update the remaining half, one by one
    mongosh_eval "$host" "$db" "
      for (let i = 0; i < $HALF; i++) {
        db.crud.updateOne({seq: $base + $HALF + i}, {\$set: {updated: true, round: $round, val: Math.random()}});
      }
    " > /dev/null
    echo "[$name] round $round: updated $HALF"
    sleep "$PHASE_SLEEP"
  done
  local left
  left=$(mongosh_eval "$host" "$db" "print(db.crud.countDocuments())" | tail -1)
  echo "[$name] done, $left docs remain in $db.crud"
}

echo "CRUD workload: $ROUNDS rounds x $DOCS docs on standalone($SA_HOST), rs($RS_HOST), sharded($SH_HOST)"
echo

run_topology "standalone" "$SA_HOST" "otelcrud_sa" &
p1=$!
run_topology "rs" "$RS_HOST" "otelcrud_rs" &
p2=$!
run_topology "sharded" "$SH_HOST" "otelcrud_sh" &
p3=$!
wait $p1 $p2 $p3

echo
echo "Workload complete - check the dashboard: operations by type should show"
echo "insert/query/update/delete spikes, plus latency, cache and network activity."
