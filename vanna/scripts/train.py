#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import chromadb
import psycopg2
import yaml


TRAINING_DIR = Path(os.getenv("VANNA_TRAINING_DIR", "/app/training"))
CHROMA_DIR = Path(os.getenv("VANNA_CHROMA_DIR", "/var/lib/vanna/chroma"))
OPS_DIR = Path(os.getenv("VANNA_OPS_DIR", "/var/lib/vanna/ops"))
COLLECTION_NAME = os.getenv("VANNA_CHROMA_COLLECTION", "tool_memories")
TRAINING_SOURCE = "sead-vanna-training"
PUBLIC_SCHEMA = "public"
RELATION_TYPES = {
    "r": "base table",
    "v": "view",
    "m": "materialized view",
    "p": "partitioned table",
    "f": "foreign table",
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def stable_id(prefix: str, text: str) -> str:
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:24]
    return f"{prefix}-{digest}"


def chroma_collection():
    CHROMA_DIR.mkdir(parents=True, exist_ok=True)
    client = chromadb.PersistentClient(path=str(CHROMA_DIR))
    return client.get_or_create_collection(name=COLLECTION_NAME)


def training_memory_filter(kind: str | None = None, title: str | None = None) -> dict[str, Any]:
    clauses: list[dict[str, Any]] = [{"source": TRAINING_SOURCE}]
    if kind is not None:
        clauses.append({"kind": kind})
    if title is not None:
        clauses.append({"title": title})
    return clauses[0] if len(clauses) == 1 else {"$and": clauses}


def delete_training_memories(
    collection: Any,
    kind: str | None = None,
    title: str | None = None,
) -> None:
    existing = collection.get(where=training_memory_filter(kind=kind, title=title), include=["metadatas"])
    if existing["ids"]:
        collection.delete(ids=existing["ids"])


def upsert_memory(kind: str, title: str, text: str, extra: dict[str, Any] | None = None) -> None:
    text = text.strip()
    if not text:
        return

    metadata = {
        "kind": kind,
        "title": title,
        "source": TRAINING_SOURCE,
        "updated_at": now_iso(),
    }
    if extra:
        metadata.update({k: v for k, v in extra.items() if v is not None})

    collection = chroma_collection()
    delete_training_memories(collection, kind=kind, title=title)
    collection.upsert(
        ids=[stable_id(f"sead-{kind}", title)],
        documents=[text],
        metadatas=[metadata],
    )
    print(f"stored {kind}: {title}")


def load_yaml(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def train_baseline() -> None:
    base_dir = TRAINING_DIR / "base"

    instructions_path = base_dir / "instructions.md"
    if instructions_path.exists():
        upsert_memory("instruction", "SEAD SQL assistant instructions", instructions_path.read_text(encoding="utf-8"))

    domain_context_path = base_dir / "domain_context.md"
    if domain_context_path.exists():
        upsert_memory(
            "domain_context",
            "SEAD domain interpretation rules",
            domain_context_path.read_text(encoding="utf-8"),
        )

    join_patterns_path = base_dir / "public_join_patterns.md"
    if join_patterns_path.exists():
        upsert_memory(
            "join_pattern",
            "SEAD public schema common join patterns",
            join_patterns_path.read_text(encoding="utf-8"),
        )

    glossary_path = base_dir / "business_glossary.yaml"
    if glossary_path.exists():
        glossary = load_yaml(glossary_path)
        for item in glossary.get("terms", []):
            term = item.get("term", "").strip()
            meaning = item.get("meaning", "").strip()
            if term and meaning:
                upsert_memory("glossary", term, f"{term}: {meaning}")

        for item in glossary.get("synonyms", []):
            canonical = item.get("canonical", "").strip()
            aliases = item.get("aliases", [])
            if canonical and aliases:
                upsert_memory("synonym", canonical, f"{canonical} is also referred to as: {', '.join(aliases)}")

    questions_path = base_dir / "golden_questions.yaml"
    if questions_path.exists():
        questions = load_yaml(questions_path)
        for item in questions.get("questions", []):
            question = item.get("question", "").strip()
            sql = item.get("sql", "").strip()
            notes = item.get("notes", "").strip()
            if question and sql:
                text = f"Question: {question}\nSQL:\n{sql}"
                if notes:
                    text = f"{text}\nNotes: {notes}"
                upsert_memory("golden_question", question, text)


def db_connect():
    return psycopg2.connect(
        host=os.getenv("VANNA_DB_HOST", "postgresql"),
        port=int(os.getenv("VANNA_DB_PORT", "5432")),
        dbname=os.getenv("VANNA_DB_NAME", os.getenv("DATABASE_NAME", "sead_staging")),
        user=os.getenv("VANNA_DB_USER", os.getenv("DATABASE_READ_ONLY_USER", "sead_ro")),
        password=os.getenv("VANNA_DB_PASSWORD", os.getenv("DATABASE_READ_ONLY_PASSWORD", "")),
    )


def configured_public_schemas() -> list[str]:
    configured = [x.strip() for x in os.getenv("VANNA_DB_SCHEMAS", PUBLIC_SCHEMA).split(",") if x.strip()]
    ignored = [schema for schema in configured if schema != PUBLIC_SCHEMA]
    if ignored:
        print(f"ignoring non-public schemas for Vanna training: {', '.join(ignored)}")
    return [PUBLIC_SCHEMA]


def fallback_table_description(table_name: str, columns: list[dict[str, Any]]) -> str:
    column_names = [column["name"] for column in columns[:8]]
    if not column_names:
        return "No database comment is available."
    return "No database comment is available. Columns suggest this relation contains: " + ", ".join(column_names) + "."


def format_join(source_table: str, source_columns: list[str], target_table: str, target_columns: list[str]) -> str:
    pairs = [f"{source_table}.{source} = {target_table}.{target}" for source, target in zip(source_columns, target_columns)]
    return " AND ".join(pairs)


def table_guide_text(schema: str, table_name: str, table_obj: dict[str, Any]) -> str:
    relation_type = table_obj.get("relation_type", "relation")
    columns = table_obj.get("columns", [])
    description = table_obj.get("description") or fallback_table_description(table_name, columns)
    primary_key = table_obj.get("primary_key", [])

    column_bits = []
    for column in columns[:16]:
        label = f"{column['name']} {column['data_type']}"
        if column["name"] in primary_key:
            label = f"{label} primary key"
        if not column["is_nullable"]:
            label = f"{label} not null"
        column_bits.append(label)

    lines = [
        f"Relation: {schema}.{table_name}",
        f"Type: {relation_type}",
        f"Description: {description}",
    ]

    if primary_key:
        lines.append(f"Primary key: {', '.join(primary_key)}")
    if column_bits:
        lines.append(f"Key columns: {', '.join(column_bits)}")

    outgoing = table_obj.get("foreign_keys_out", [])
    incoming = table_obj.get("foreign_keys_in", [])
    if outgoing:
        lines.append("Joins from this relation:")
        for fk in outgoing[:10]:
            lines.append(
                "- "
                + format_join(
                    table_name,
                    fk["source_columns"],
                    fk["target_table"],
                    fk["target_columns"],
                )
            )
    if incoming:
        lines.append("Other public relations commonly join to this relation:")
        for fk in incoming[:10]:
            lines.append(
                "- "
                + format_join(
                    fk["source_table"],
                    fk["source_columns"],
                    table_name,
                    fk["target_columns"],
                )
            )

    return "\n".join(lines)


def public_table_guide_markdown(catalog: dict[str, Any]) -> str:
    tables = catalog["schemas"].get(PUBLIC_SCHEMA, {}).get("tables", {})
    lines = [
        "# SEAD Public Schema Table Guide",
        "",
        "Use only `public` schema relations when answering questions. Prefer explicit joins through the foreign-key paths listed below.",
        "",
    ]

    for table_name in sorted(tables):
        table_obj = tables[table_name]
        lines.extend(
            [
                f"## public.{table_name}",
                "",
                table_guide_text(PUBLIC_SCHEMA, table_name, table_obj),
                "",
            ]
        )

    return "\n".join(lines).strip() + "\n"


def train_schema_refresh() -> None:
    schemas = configured_public_schemas()
    generated_dir = TRAINING_DIR / "generated"
    generated_dir.mkdir(parents=True, exist_ok=True)
    delete_training_memories(chroma_collection(), title="SEAD PostgreSQL schema catalog")

    tables_query = """
        SELECT
            n.nspname AS table_schema,
            c.relname AS table_name,
            c.relkind,
            obj_description(c.oid, 'pg_class') AS description
        FROM pg_class AS c
        JOIN pg_namespace AS n
            ON n.oid = c.relnamespace
        WHERE n.nspname = ANY(%s)
          AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
        ORDER BY n.nspname, c.relname;
    """

    query = """
        SELECT
            c.table_schema,
            c.table_name,
            c.column_name,
            c.data_type,
            c.is_nullable,
            c.ordinal_position
        FROM information_schema.columns AS c
        WHERE c.table_schema = ANY(%s)
        ORDER BY c.table_schema, c.table_name, c.ordinal_position;
    """

    primary_key_query = """
        SELECT
            tc.table_schema,
            tc.table_name,
            kcu.column_name
        FROM information_schema.table_constraints AS tc
        JOIN information_schema.key_column_usage AS kcu
            ON kcu.constraint_schema = tc.constraint_schema
           AND kcu.constraint_name = tc.constraint_name
           AND kcu.table_schema = tc.table_schema
           AND kcu.table_name = tc.table_name
        WHERE tc.constraint_type = 'PRIMARY KEY'
          AND tc.table_schema = ANY(%s)
        ORDER BY tc.table_schema, tc.table_name, kcu.ordinal_position;
    """

    foreign_key_query = """
        SELECT
            ns.nspname AS source_schema,
            src.relname AS source_table,
            con.conname AS constraint_name,
            nt.nspname AS target_schema,
            tgt.relname AS target_table,
            array_agg(src_att.attname ORDER BY src_cols.ordinality) AS source_columns,
            array_agg(tgt_att.attname ORDER BY src_cols.ordinality) AS target_columns
        FROM pg_constraint AS con
        JOIN pg_class AS src
            ON src.oid = con.conrelid
        JOIN pg_namespace AS ns
            ON ns.oid = src.relnamespace
        JOIN pg_class AS tgt
            ON tgt.oid = con.confrelid
        JOIN pg_namespace AS nt
            ON nt.oid = tgt.relnamespace
        JOIN unnest(con.conkey) WITH ORDINALITY AS src_cols(attnum, ordinality)
            ON true
        JOIN unnest(con.confkey) WITH ORDINALITY AS tgt_cols(attnum, ordinality)
            ON tgt_cols.ordinality = src_cols.ordinality
        JOIN pg_attribute AS src_att
            ON src_att.attrelid = src.oid
           AND src_att.attnum = src_cols.attnum
        JOIN pg_attribute AS tgt_att
            ON tgt_att.attrelid = tgt.oid
           AND tgt_att.attnum = tgt_cols.attnum
        WHERE con.contype = 'f'
          AND ns.nspname = ANY(%s)
          AND nt.nspname = ANY(%s)
        GROUP BY ns.nspname, src.relname, con.conname, nt.nspname, tgt.relname
        ORDER BY ns.nspname, src.relname, con.conname;
    """

    catalog: dict[str, Any] = {"generated_at": now_iso(), "schemas": {}}
    with db_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(tables_query, (schemas,))
            for schema, table, relkind, description in cur.fetchall():
                schema_obj = catalog["schemas"].setdefault(schema, {"tables": {}})
                schema_obj["tables"].setdefault(
                    table,
                    {
                        "relation_type": RELATION_TYPES.get(relkind, "relation"),
                        "description": (description or "").strip(),
                        "columns": [],
                        "primary_key": [],
                        "foreign_keys_out": [],
                        "foreign_keys_in": [],
                    },
                )

            cur.execute(query, (schemas,))
            for schema, table, column, data_type, nullable, ordinal in cur.fetchall():
                schema_obj = catalog["schemas"].setdefault(schema, {"tables": {}})
                table_obj = schema_obj["tables"].setdefault(
                    table,
                    {
                        "relation_type": "relation",
                        "description": "",
                        "columns": [],
                        "primary_key": [],
                        "foreign_keys_out": [],
                        "foreign_keys_in": [],
                    },
                )
                table_obj["columns"].append(
                    {
                        "name": column,
                        "data_type": data_type,
                        "is_nullable": nullable == "YES",
                        "ordinal_position": ordinal,
                    }
                )

            cur.execute(primary_key_query, (schemas,))
            for schema, table, column in cur.fetchall():
                table_obj = catalog["schemas"][schema]["tables"][table]
                table_obj["primary_key"].append(column)

            cur.execute(foreign_key_query, (schemas, schemas))
            for source_schema, source_table, constraint, target_schema, target_table, source_columns, target_columns in cur.fetchall():
                source_obj = catalog["schemas"][source_schema]["tables"][source_table]
                target_obj = catalog["schemas"][target_schema]["tables"][target_table]
                fk = {
                    "constraint": constraint,
                    "source_schema": source_schema,
                    "source_table": source_table,
                    "source_columns": list(source_columns),
                    "target_schema": target_schema,
                    "target_table": target_table,
                    "target_columns": list(target_columns),
                }
                source_obj["foreign_keys_out"].append(fk)
                target_obj["foreign_keys_in"].append(fk)

    output_path = generated_dir / "schema_catalog.json"
    output_path.write_text(json.dumps(catalog, indent=2, sort_keys=True), encoding="utf-8")
    guide_path = generated_dir / "public_table_guide.md"
    guide_text = public_table_guide_markdown(catalog)
    guide_path.write_text(guide_text, encoding="utf-8")

    upsert_memory("schema_catalog", "SEAD public PostgreSQL schema catalog", json.dumps(catalog, indent=2, sort_keys=True))
    upsert_memory("table_guide", "SEAD public schema table and join guide", guide_text)

    for table_name, table_obj in sorted(catalog["schemas"].get(PUBLIC_SCHEMA, {}).get("tables", {}).items()):
        upsert_memory(
            "table_guide",
            f"{PUBLIC_SCHEMA}.{table_name}",
            table_guide_text(PUBLIC_SCHEMA, table_name, table_obj),
            {"schema": PUBLIC_SCHEMA, "table": table_name},
        )

    print(f"wrote {output_path}")
    print(f"wrote {guide_path}")


def train_ops_note(text: str) -> None:
    OPS_DIR.mkdir(parents=True, exist_ok=True)
    entry = {"created_at": now_iso(), "text": text}
    ledger = OPS_DIR / "training_notes.jsonl"
    with ledger.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, sort_keys=True) + "\n")
    upsert_memory("ops_note", "Operational training note", text)
    print(f"appended {ledger}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Train SEAD Vanna memory.")
    parser.add_argument("mode", choices=["baseline", "schema-refresh", "apply", "ops-note"])
    parser.add_argument("--text", help="Operational note text for ops-note mode.")
    args = parser.parse_args()

    if args.mode == "baseline":
        train_baseline()
    elif args.mode == "schema-refresh":
        train_schema_refresh()
    elif args.mode == "apply":
        train_baseline()
        train_schema_refresh()
    elif args.mode == "ops-note":
        if not args.text:
            parser.error("ops-note requires --text")
        train_ops_note(args.text)


if __name__ == "__main__":
    main()
