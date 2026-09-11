#!/usr/bin/env python3
"""Regenerates the Backend Diff dashboard from the main MongoDB Agent OTLP dashboard.

The diff dashboard is a derived artifact: every panel of the source dashboard is
emitted twice - left column pinned to the prometheus datasource, right column to
grafana-otel - at the source panel's exact grid position, so rows align for scroll
comparison AND the diff dashboard aligns 1:1 with the main one on a second screen.
Re-run after editing the main dashboard (quick-start.sh does this automatically).

The six stat panels of the source's top row are folded into one combined stat pair
(side by side at w12 they would not fit the 24-column grid otherwise).
"""

import json

SRC = "grafana/provisioning/dashboards/mongodb-agent-otel.json"
OUT = "grafana/provisioning/dashboards/mongodb-agent-otel-diff.json"
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
        "Side-by-side drift comparison: LEFT = prometheus (dedicated receiver), RIGHT = grafana-otel (Grafana backend). "
        "The agent exports to both simultaneously - the same panel on both sides should show the same shape. "
        "Divergence means one backend dropped or lagged data. Fully label-driven like the source dashboard."
    ),
    "tags": ["mongodb", "otel", "agent", "diff"],
    "timezone": "browser",
    "schemaVersion": 39,
    "editable": True,
    "refresh": "30s",
    "time": {"from": "now-3h", "to": "now"},
    "panels": [],
}

DS = {
    "left": {"type": "prometheus", "uid": "prometheus"},
    "right": {"type": "prometheus", "uid": "grafana-otel"},
}

lid, rid = 100, 200
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

    h, y = p["gridPos"]["h"], p["gridPos"]["y"]

    if p["id"] in STAT_IDS:
        continue  # combined stat pair, emitted after the loop

    for side, x in (("left", 0), ("right", 12)):
        clone = json.loads(json.dumps(p))
        clone["datasource"] = DS[side]
        for t in clone.get("targets", []):
            t["datasource"] = DS[side]
        clone["gridPos"] = {"h": h, "w": 12, "x": x, "y": y}
        clone["title"] = p.get("title", "") + (
            "  ◀ prom" if side == "left" else "  graf ▶"
        )
        diff["panels"].append(clone)

# the six source stats become one combined stat pair at the top
stat_panels = [p for p in src["panels"] if p["id"] in STAT_IDS]
for side, x in (("left", 0), ("right", 12)):
    targets = []
    for i, sp in enumerate(stat_panels):
        t = json.loads(json.dumps(sp["targets"][0]))
        t["datasource"] = DS[side]
        t["refId"] = chr(65 + i)
        t["legendFormat"] = STAT_LEGENDS[sp["id"]]
        targets.append(t)
    diff["panels"].insert(
        0 + (1 if side == "right" else 0),
        {
            "id": 500 if side == "left" else 600,
            "type": "stat",
            "title": "Fleet stats  ◀ prom" if side == "left" else "Fleet stats  graf ▶",
            "description": "agents, mongods, mongos, connections and version skew - one value per stat",
            "gridPos": {"h": 4, "w": 12, "x": x, "y": 0},
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
print(
    f"diff dashboard regenerated: {len(diff['panels'])} panels, grid copied from source"
)
