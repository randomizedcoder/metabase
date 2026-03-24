#!/usr/bin/env python3
"""Export Metabase dashboard configurations as JSON directly from Postgres.

Replicates the enterprise serialization export format without requiring a license.
Connects to the Metabase application database and outputs JSON files matching
the structure of enterprise YAML exports.

Environment variables for connection:
  MB_DB_HOST       (default: localhost)
  MB_DB_PORT       (default: 5432)
  MB_DB_DBNAME     (default: metabase)
  MB_DB_USER       (default: metabase)
  MB_DB_PASS       (default: empty)
  MB_DB_CONNECTION_URI  (full connection string, overrides individual vars)
"""

import argparse
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras


# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------

def connect():
    """Connect to the Metabase Postgres database using environment variables."""
    uri = os.environ.get("MB_DB_CONNECTION_URI")
    if uri:
        return psycopg2.connect(uri)
    return psycopg2.connect(
        host=os.environ.get("MB_DB_HOST", "localhost"),
        port=int(os.environ.get("MB_DB_PORT", "5432")),
        dbname=os.environ.get("MB_DB_DBNAME", "metabase"),
        user=os.environ.get("MB_DB_USER", "metabase"),
        password=os.environ.get("MB_DB_PASS", ""),
    )


# ---------------------------------------------------------------------------
# JSON column parsing
# ---------------------------------------------------------------------------

def parse_json_column(value):
    """Parse a JSON/JSONB column value, returning the parsed object or the value as-is."""
    if value is None:
        return None
    if isinstance(value, (dict, list)):
        return value
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (json.JSONDecodeError, TypeError):
            return value
    return value


def format_timestamp(value):
    """Format a datetime value to ISO 8601 string matching enterprise output."""
    if value is None:
        return None
    if isinstance(value, datetime):
        # Match enterprise format: 2024-08-28T09:46:24.726993Z
        return value.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    return str(value)


# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------

def resolve_user_emails(conn, user_ids):
    """Look up email addresses for a set of user IDs. Returns {id: email}."""
    if not user_ids:
        return {}
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(
            "SELECT id, email FROM core_user WHERE id = ANY(%(ids)s)",
            {"ids": list(user_ids)},
        )
        return {row["id"]: row["email"] for row in cur.fetchall()}


def resolve_collection_entity_ids(conn, collection_ids):
    """Look up entity_ids for a set of collection IDs. Returns {id: entity_id}."""
    if not collection_ids:
        return {}
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(
            "SELECT id, entity_id FROM collection WHERE id = ANY(%(ids)s)",
            {"ids": list(collection_ids)},
        )
        return {row["id"]: row["entity_id"] for row in cur.fetchall()}


def resolve_card_entity_ids(conn, card_ids):
    """Look up entity_ids for a set of card IDs. Returns {id: entity_id}."""
    if not card_ids:
        return {}
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(
            "SELECT id, entity_id FROM report_card WHERE id = ANY(%(ids)s)",
            {"ids": list(card_ids)},
        )
        return {row["id"]: row["entity_id"] for row in cur.fetchall()}


def resolve_action_entity_ids(conn, action_ids):
    """Look up entity_ids for a set of action IDs. Returns {id: entity_id}."""
    if not action_ids:
        return {}
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(
            "SELECT id, entity_id FROM action WHERE id = ANY(%(ids)s)",
            {"ids": list(action_ids)},
        )
        return {row["id"]: row["entity_id"] for row in cur.fetchall()}


# ---------------------------------------------------------------------------
# Query: list dashboards
# ---------------------------------------------------------------------------

def list_dashboards(conn, include_archived=False):
    """Fetch summary info for all dashboards."""
    query = """
        SELECT d.id, d.name, d.description, d.archived, d.collection_id,
               c.name AS collection_name, d.created_at, d.updated_at
        FROM report_dashboard d
        LEFT JOIN collection c ON d.collection_id = c.id
    """
    if not include_archived:
        query += " WHERE d.archived = false"
    query += " ORDER BY d.name"

    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(query)
        return cur.fetchall()


# ---------------------------------------------------------------------------
# Query: fetch full dashboard rows
# ---------------------------------------------------------------------------

def fetch_dashboards(conn, name=None, include_archived=False):
    """Fetch full dashboard rows, optionally filtered by name."""
    query = """
        SELECT id, name, description, parameters, archived, archived_directly,
               collection_id, auto_apply_filters, cache_ttl, enable_embedding,
               embedding_params, public_uuid, made_public_by_id,
               position, collection_position, width, show_in_getting_started,
               caveats, points_of_interest, initially_published_at,
               created_at, updated_at, entity_id, creator_id
        FROM report_dashboard
    """
    conditions = []
    params = {}
    if not include_archived:
        conditions.append("archived = false")
    if name is not None:
        conditions.append("name = %(name)s")
        params["name"] = name
    if conditions:
        query += " WHERE " + " AND ".join(conditions)
    query += " ORDER BY name, id"

    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(query, params)
        return cur.fetchall()


# ---------------------------------------------------------------------------
# Query: dashboard tabs
# ---------------------------------------------------------------------------

def fetch_tabs(conn, dashboard_id):
    """Fetch tabs for a dashboard, ordered by position then id."""
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(
            """SELECT id, name, position, entity_id, created_at, updated_at
               FROM dashboard_tab
               WHERE dashboard_id = %(dashboard_id)s
               ORDER BY position ASC, id ASC""",
            {"dashboard_id": dashboard_id},
        )
        return cur.fetchall()


# ---------------------------------------------------------------------------
# Query: dashboard cards
# ---------------------------------------------------------------------------

def fetch_dashcards(conn, dashboard_id):
    """Fetch dashboard cards with archived-card filtering matching enterprise behavior."""
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(
            """SELECT dashcard.*
               FROM report_dashboardcard dashcard
               LEFT JOIN report_card card ON dashcard.card_id = card.id
               WHERE dashcard.dashboard_id = %(dashboard_id)s
                 AND (card.archived = false
                      OR (card.dashboard_id IS NOT NULL AND card.archived_directly = false)
                      OR card.archived IS NULL)
               ORDER BY dashcard.created_at ASC""",
            {"dashboard_id": dashboard_id},
        )
        return cur.fetchall()


# ---------------------------------------------------------------------------
# Query: series for dashboard cards
# ---------------------------------------------------------------------------

def fetch_series(conn, dashcard_ids):
    """Fetch series for a set of dashboard card IDs. Returns {dashcard_id: [series]}."""
    if not dashcard_ids:
        return {}
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(
            """SELECT series.dashboardcard_id, series.position, series.card_id
               FROM dashboardcard_series series
               JOIN report_card c ON series.card_id = c.id
               WHERE series.dashboardcard_id = ANY(%(ids)s)
               ORDER BY series.dashboardcard_id, series.position ASC""",
            {"ids": list(dashcard_ids)},
        )
        result = {}
        for row in cur.fetchall():
            result.setdefault(row["dashboardcard_id"], []).append(row)
        return result


# ---------------------------------------------------------------------------
# Query: card details (for --include-cards)
# ---------------------------------------------------------------------------

def fetch_cards(conn, card_ids):
    """Fetch full card details for a set of card IDs."""
    if not card_ids:
        return {}
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(
            """SELECT id, name, description, display, dataset_query, type,
                      visualization_settings, query_type, database_id, table_id,
                      collection_id, entity_id, parameters, result_metadata
               FROM report_card
               WHERE id = ANY(%(ids)s)""",
            {"ids": list(card_ids)},
        )
        return {row["id"]: dict(row) for row in cur.fetchall()}


# ---------------------------------------------------------------------------
# Export a single dashboard
# ---------------------------------------------------------------------------

def export_dashboard(conn, dashboard_row, raw_ids=False, include_cards=False):
    """Build the export JSON for a single dashboard row."""
    d = dict(dashboard_row)
    dashboard_id = d["id"]

    # Fetch related data
    tabs = fetch_tabs(conn, dashboard_id)
    dashcards = fetch_dashcards(conn, dashboard_id)
    dashcard_ids = [dc["id"] for dc in dashcards]
    series_map = fetch_series(conn, dashcard_ids)

    # Collect IDs for batch resolution
    user_ids = set()
    collection_ids = set()
    card_ids = set()
    action_ids = set()

    if d.get("creator_id"):
        user_ids.add(d["creator_id"])
    if d.get("made_public_by_id"):
        user_ids.add(d["made_public_by_id"])
    if d.get("collection_id"):
        collection_ids.add(d["collection_id"])

    for dc in dashcards:
        if dc.get("card_id"):
            card_ids.add(dc["card_id"])
        if dc.get("action_id"):
            action_ids.add(dc["action_id"])

    for dc_series in series_map.values():
        for s in dc_series:
            if s.get("card_id"):
                card_ids.add(s["card_id"])

    # Batch resolve foreign keys
    if raw_ids:
        user_email_map = {}
        collection_eid_map = {}
        card_eid_map = {}
        action_eid_map = {}
    else:
        user_email_map = resolve_user_emails(conn, user_ids)
        collection_eid_map = resolve_collection_entity_ids(conn, collection_ids)
        card_eid_map = resolve_card_entity_ids(conn, card_ids)
        action_eid_map = resolve_action_entity_ids(conn, action_ids)

    # Optionally fetch full card details
    card_details = fetch_cards(conn, card_ids) if include_cards else {}

    # Build tab entity_id map for dashcard tab references
    tab_eid_map = {tab["id"]: tab["entity_id"] for tab in tabs}

    # Resolve helper
    def resolve_fk(value, mapping):
        if raw_ids or value is None:
            return value
        return mapping.get(value, value)

    # Build dashboard JSON
    result = {
        "name": d["name"],
        "description": d["description"],
        "entity_id": d["entity_id"],
        "created_at": format_timestamp(d["created_at"]),
        "creator_id": resolve_fk(d["creator_id"], user_email_map),
        "archived": d["archived"],
        "collection_id": resolve_fk(d["collection_id"], collection_eid_map),
        "auto_apply_filters": d["auto_apply_filters"],
        "collection_position": d["collection_position"],
        "position": d["position"],
        "enable_embedding": d["enable_embedding"],
        "embedding_params": parse_json_column(d["embedding_params"]),
        "made_public_by_id": resolve_fk(d["made_public_by_id"], user_email_map),
        "public_uuid": d["public_uuid"],
        "show_in_getting_started": d["show_in_getting_started"],
        "caveats": d["caveats"],
        "points_of_interest": d["points_of_interest"],
        "parameters": parse_json_column(d["parameters"]) or [],
        "archived_directly": d["archived_directly"],
        "initially_published_at": format_timestamp(d.get("initially_published_at")),
        "width": d.get("width", "fixed"),
    }

    # Build tabs
    result["tabs"] = [
        {
            "name": tab["name"],
            "entity_id": tab["entity_id"],
            "position": tab["position"],
            "created_at": format_timestamp(tab["created_at"]),
        }
        for tab in tabs
    ]

    # Build dashcards
    result["dashcards"] = []
    for dc in dashcards:
        dc_series = series_map.get(dc["id"], [])
        dashcard = {
            "entity_id": dc["entity_id"],
            "card_id": resolve_fk(dc.get("card_id"), card_eid_map),
            "created_at": format_timestamp(dc["created_at"]),
            "row": dc["row"],
            "col": dc["col"],
            "size_x": dc["size_x"],
            "size_y": dc["size_y"],
            "action_id": resolve_fk(dc.get("action_id"), action_eid_map),
            "dashboard_tab_id": resolve_fk(dc.get("dashboard_tab_id"), tab_eid_map) if not raw_ids else dc.get("dashboard_tab_id"),
            "inline_parameters": parse_json_column(dc.get("inline_parameters")) or [],
            "parameter_mappings": parse_json_column(dc.get("parameter_mappings")) or [],
            "visualization_settings": parse_json_column(dc.get("visualization_settings")) or {},
            "series": [
                {
                    "card_id": resolve_fk(s["card_id"], card_eid_map),
                    "position": s["position"],
                }
                for s in dc_series
            ],
        }
        result["dashcards"].append(dashcard)

    # Attach full card details if requested
    if include_cards and card_details:
        cards_out = []
        for cid, card in card_details.items():
            cards_out.append({
                "id": card["id"],
                "entity_id": card["entity_id"],
                "name": card["name"],
                "description": card["description"],
                "display": card["display"],
                "type": card["type"],
                "query_type": card["query_type"],
                "dataset_query": parse_json_column(card["dataset_query"]),
                "visualization_settings": parse_json_column(card["visualization_settings"]),
                "parameters": parse_json_column(card["parameters"]) or [],
                "result_metadata": parse_json_column(card["result_metadata"]),
            })
        result["_cards"] = cards_out

    return result


# ---------------------------------------------------------------------------
# File output
# ---------------------------------------------------------------------------

def sanitize_filename(name):
    """Convert a dashboard name to a safe filename component."""
    name = name.lower().strip()
    name = re.sub(r"[^\w\s-]", "", name)
    name = re.sub(r"[\s_-]+", "_", name)
    return name[:80]


def write_dashboard(dashboard_json, dashboard_id, output_dir, compact=False):
    """Write a dashboard JSON to a file. Returns the filename."""
    slug = sanitize_filename(dashboard_json["name"])
    filename = f"dashboard_{dashboard_id}_{slug}.json"
    filepath = os.path.join(output_dir, filename)
    with open(filepath, "w") as f:
        if compact:
            json.dump(dashboard_json, f, sort_keys=True, ensure_ascii=False)
        else:
            json.dump(dashboard_json, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    return filename


def write_manifest(dashboards_info, output_dir):
    """Write manifest.json summarizing the export."""
    manifest = {
        "exported_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "dashboard_count": len(dashboards_info),
        "dashboards": dashboards_info,
    }
    filepath = os.path.join(output_dir, "manifest.json")
    with open(filepath, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")


# ---------------------------------------------------------------------------
# CLI: print dashboard list
# ---------------------------------------------------------------------------

def print_dashboard_list(dashboards):
    """Print a formatted table of dashboards."""
    if not dashboards:
        print("No dashboards found.")
        return

    # Column widths
    headers = ["ID", "Name", "Collection", "Archived", "Created"]
    rows = []
    for d in dashboards:
        rows.append([
            str(d["id"]),
            d["name"] or "(unnamed)",
            d["collection_name"] or "(root)",
            "Yes" if d["archived"] else "No",
            format_timestamp(d["created_at"])[:10] if d["created_at"] else "",
        ])

    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*headers))
    print(fmt.format(*["-" * w for w in widths]))
    for row in rows:
        print(fmt.format(*row))
    print(f"\n{len(rows)} dashboard(s)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Export Metabase dashboard configurations as JSON from Postgres.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment variables:
  MB_DB_HOST            Postgres host (default: localhost)
  MB_DB_PORT            Postgres port (default: 5432)
  MB_DB_DBNAME          Database name (default: metabase)
  MB_DB_USER            Database user (default: metabase)
  MB_DB_PASS            Database password (default: empty)
  MB_DB_CONNECTION_URI  Full connection string (overrides individual vars)

Examples:
  %(prog)s --list
  %(prog)s --export "Sales Overview"
  %(prog)s --export-all --output-dir ./exports
  %(prog)s --export-all --raw-ids --compact
""",
    )

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true", help="List all dashboards")
    group.add_argument("--export", metavar="NAME", help="Export dashboard(s) matching NAME")
    group.add_argument("--export-all", action="store_true", help="Export all non-archived dashboards")

    parser.add_argument("--output-dir", metavar="DIR", help="Output directory (default: temp dir)")
    parser.add_argument("--include-archived", action="store_true", help="Include archived dashboards")
    parser.add_argument("--include-cards", action="store_true", help="Include full card/question definitions")
    parser.add_argument("--raw-ids", action="store_true", help="Use numeric IDs instead of entity_ids")
    parser.add_argument("--compact", action="store_true", help="Compact JSON output (no indentation)")

    args = parser.parse_args()

    try:
        conn = connect()
    except psycopg2.Error as e:
        print(f"Error: Could not connect to database: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        if args.list:
            dashboards = list_dashboards(conn, include_archived=args.include_archived)
            print_dashboard_list(dashboards)
            return

        # Export mode
        if args.export:
            dashboard_rows = fetch_dashboards(conn, name=args.export, include_archived=args.include_archived)
            if not dashboard_rows:
                print(f"Error: No dashboard found with name '{args.export}'", file=sys.stderr)
                sys.exit(1)
        else:
            dashboard_rows = fetch_dashboards(conn, include_archived=args.include_archived)
            if not dashboard_rows:
                print("No dashboards to export.", file=sys.stderr)
                sys.exit(0)

        # Determine output directory
        if args.output_dir:
            output_dir = args.output_dir
            os.makedirs(output_dir, exist_ok=True)
        else:
            output_dir = tempfile.mkdtemp(prefix="metabase-dashboards-")

        # Export each dashboard
        manifest_entries = []
        for row in dashboard_rows:
            dashboard_json = export_dashboard(
                conn, row,
                raw_ids=args.raw_ids,
                include_cards=args.include_cards,
            )
            filename = write_dashboard(dashboard_json, row["id"], output_dir, compact=args.compact)
            manifest_entries.append({
                "id": row["id"],
                "name": row["name"],
                "file": filename,
            })
            print(f"Exported: {row['name']} -> {filename}")

        write_manifest(manifest_entries, output_dir)
        print(f"\n{len(manifest_entries)} dashboard(s) exported to {output_dir}")

    finally:
        conn.close()


if __name__ == "__main__":
    main()
