#!/usr/bin/env python3
"""Regenerates the Backend Diff dashboard from the main MongoDB Agent OTLP dashboard.

The diff dashboard is a derived artifact: every panel of the source dashboard is
emitted three times - one column per backend (prometheus, grafana-otel,
victoriametrics) - at identical grid positions, so rows align for scroll comparison.
The six source stat panels are folded into one combined stat panel per backend
(side by side at w8 they would not fit the 24-column grid otherwise).
Re-run after editing the main dashboard (quick-start.sh does this automatically).
"""

import json

SRC = "grafana/provisioning/dashboards/mongodb-agent-otel.json"
OUT = "grafana/provisioning/dashboards/mongodb-agent-otel-diff.json"

SRC_SUFFIX = {"prom": "  prom ▶", "graf": "  graf ▶", "vm": "  vm ▶"}
DS = {
    "prom": {"type": "prometheus", "uid": "prometheus"},
    "graf": {"type": "prometheus", "uid": "grafana-otel"},
    "vm": {"type": "prometheus", "uid": "victoriametrics"},
}
STAT_IDS = {1, 2, 3, 4, 41, 42}
STAT_LEGENDS = {
    1: "points",
    2: "mongods",
    3: "mongos",
    4: "conns",
    41: "mongod ver",
    42: "agent ver",
}

src = json.load(open(SRC))

diff = {
    "uid": "mongodb-agent-otel-diff",
    "title": "MongoDB Agent OTLP - Backend Diff",
    "description": (
        "Three-way drift comparison: prometheus | grafana-otel | victoriametrics - the same panels fed by the "
        "agent's export paths. The same metric on every column should show the same shape; divergence = a backend "
        "dropped or lagged data. Fully label-driven like the source dashboard."
    ),
    "tags": ["mongodb", "otel", "agent", "diff"],
    "timezone": "browser",
    "schemaVersion": 39,
    "editable": True,
    "refresh": "30s",
    "time": {"from": "now-3h", "to": "now"},
    "panels": [],
}

lid = 100
for p in src["panels"]:
    gp = p["gridPos"]
    if p["type"] == "row":
        diff["panels"].append(
            {
                "id": lid,
                "type": "row",
                "title": p["title"],
                "gridPos": {"h": 1, "w": 24, "x": 0, "y": gp["y"]},
            }
        )
        lid += 1
        continue

    h, y = gp["h"], gp["y"]

    if p["id"] in STAT_IDS:
        continue  # combined stat row, emitted after the loop

    for i, (side, x) in enumerate((("prom", 0), ("graf", 8), ("vm", 16))):
        clone = json.loads(json.dumps(p))
        clone["datasource"] = DS[side]
        for t in clone.get("targets", []):
            t["datasource"] = DS[side]
        clone["gridPos"] = {"h": h, "w": 8, "x": x, "y": y}
        clone["title"] = p.get("title", "") + SRC_SUFFIX[side]
        diff["panels"].append(clone)

# the six source stats become one combined stat panel per backend, across the top
stat_panels = [p for p in src["panels"] if p["id"] in STAT_IDS]
for i, (side, x) in enumerate((("prom", 0), ("graf", 8), ("vm", 16))):
    targets = []
    for j, sp in enumerate(stat_panels):
        t = json.loads(json.dumps(sp["targets"][0]))
        t["datasource"] = DS[side]
        t["refId"] = chr(65 + j)
        t["legendFormat"] = STAT_LEGENDS[sp["id"]]
        targets.append(t)
    diff["panels"].insert(
        i,
        {
            "id": 500 + i,
            "type": "stat",
            "title": f"Fleet stats  {SRC_SUFFIX[side]}",
            "description": "agents, mongods, mongos, connections and version skew - one value per stat",
            "gridPos": {"h": 4, "w": 8, "x": x, "y": 0},
            "datasource": DS[side],
            "targets": targets,
            "fieldConfig": {
                "defaults": {"color": {"mode": "palette-classic"}},
                "overrides": [],
            },
            "options": {
                "colorMode": "value",
                "graphMode": "none",
                "textMode": "auto",
                "reduceOptions": {
                    "calcs": ["lastNotNull"],
                    "fields": "",
                    "values": False,
                },
            },
        },
    )

json.dump(diff, open(OUT, "w"), indent=2)
print(f"diff dashboard regenerated: {len(diff['panels'])} panels from {SRC}")
