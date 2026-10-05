# /// script
# requires-python = ">=3.11"
# dependencies = ["pyodbc>=5.0", "rapidfuzz>=3.0"]
# ///
"""Build silver.ibge_municipality and silver.city_map: official IBGE names for the cities.

Customer and seller cities are typed by hand in the source ('sao paulo', 'são paulo', 'sp',
'sao paulo - sp', even a zip code or an e-mail). This script maps every distinct
(city, state, zip prefix) of silver.olist_customers_ds / silver.olist_sellers_ds to an IBGE
municipality code; gold.load_gold uses it to show the official name ('São Paulo').

Pipeline step (option A, reference rebuilt on demand):
    bronze.load_bronze -> silver.load_silver -> build_city_map.py -> gold.load_gold
Run it again only when the silver data or the rules below change.

Reference: IBGE API (servicodados.ibge.gov.br/api/v1/localidades/municipios), cached in
data/ibge_municipalities.json so the pipeline does not need internet; --refresh-ibge
downloads it again.

Rules, first one that applies wins (match_method):
    manual        MANUAL_OVERRIDES below
    exact         name without accents/case/symbols exists in the declared state
    alias         renamed municipality (ALIASES) in the declared state
    state_fixed   name exists in the zip prefix's state, not in the declared one
    admin_region  any city declared in DF (single municipality: Brasília)
    spelling      same skeleton in the declared state (no spaces/connectors, z=s, y=i, th=t)
    fuzzy         one edit on long names (>= 10 chars), Jaro-Winkler >= 0.90, no ties
    zip_city      the name did not match: most frequent geolocation city of the zip prefix
                  that is a municipality (covers districts, abbreviations like 'sbc', state
                  names and zip codes typed as city)
    unmatched     nothing matched: ibge_code NULL, gold keeps the source spelling

Both tables are replaced in one transaction (idempotent); the run is logged in
etl.batch_log / etl.table_load_log as process 'build_city_map' (layer silver).

Usage:
    python -m uv run src/build_city_map.py [--server localhost] [--database OlistDW]
                                           [--refresh-ibge]
"""

from __future__ import annotations

import argparse
import gzip
import html
import json
import re
import unicodedata
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

import pyodbc
from rapidfuzz import process
from rapidfuzz.distance import OSA, JaroWinkler

PROCESS_NAME = "build_city_map"
IBGE_URL = "https://servicodados.ibge.gov.br/api/v1/localidades/municipios"
IBGE_CACHE = Path(__file__).resolve().parents[1] / "data" / "ibge_municipalities.json"
EXPECTED_STATES = 27
MIN_MUNICIPALITIES = 5570  # Brazil has 5,570+ municipalities

# Renamed municipalities / historical names (normalized key -> IBGE normalized key).
# Used only when the name itself does not exist in the state.
ALIASES: dict[str, str] = {
    "embu": "embu das artes",
    "acu": "assu",
    "4o centenario": "quarto centenario",
    "santa cecilia de umbuzeiro": "santa cecilia",
    "florinia": "florinea",
    "bom jesus": "bom jesus de goias",
}

# Hand-checked corrections: (normalized city key, declared state) -> IBGE code.
MANUAL_OVERRIDES: dict[tuple[str, str], int] = {}

# Ignored by the loose skeleton ("amparo da serra" == "amparo do serra")
CONNECTORS = frozenset({"d", "de", "da", "do", "das", "dos", "e"})

# Fuzzy guards: short names are never fuzzy-matched ("campinal" -> "campinas" is wrong)
MIN_SIMILARITY = 0.90
MIN_FUZZY_LEN = 10
MAX_FUZZY_EDITS = 1
FUZZY_CANDIDATES = 5

COMBOS_SQL = """
WITH src AS (
    SELECT c.customer_city AS city_raw, c.customer_state AS state_raw,
           c.customer_zip_code_prefix AS zip
    FROM silver.olist_customers_ds AS c
    UNION ALL
    SELECT s.seller_city, s.seller_state, s.seller_zip_code_prefix
    FROM silver.olist_sellers_ds AS s
)
SELECT s.city_raw, s.state_raw, s.zip, COUNT(*) AS n_rows
FROM src AS s
GROUP BY s.city_raw, s.state_raw, s.zip;
"""

ZIP_CITIES_SQL = """
SELECT g.geolocation_zip_code_prefix AS zip, g.geolocation_state AS uf,
       g.geolocation_city AS city, COUNT(*) AS n
FROM silver.olist_geolocation_ds AS g
GROUP BY g.geolocation_zip_code_prefix, g.geolocation_state, g.geolocation_city;
"""


# --------------------------------------------------------------------------- text helpers


def _build_mojibake_map() -> dict[str, str]:
    """Broken sequences (UTF-8 read as Latin-1/CP1252, also lowercased) -> right character."""
    mapping: dict[str, str] = {}
    for ch in "áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ":
        for codec in ("latin-1", "cp1252"):
            try:
                broken = ch.encode("utf-8").decode(codec)
            except UnicodeDecodeError:
                continue
            mapping[broken] = ch
            mapping[broken.lower()] = ch.lower()
    return mapping


MOJIBAKE_MAP = _build_mojibake_map()
MOJIBAKE_RE = re.compile(
    "|".join(re.escape(k) for k in sorted(MOJIBAKE_MAP, key=len, reverse=True))
)
DISTRICT_SUFFIX_RE = re.compile(r"\s*-\s*distrito\s*$")
# Text after these separators is a state, a country or a district: 'sao paulo - sp',
# 'pinhais/pr', 'novo hamburgo, rio grande do sul, brasil', 'rio de janeiro \rio de janeiro'
QUALIFIER_RE = re.compile(r",|/|\\|\s-\s")


def repair_text(text: str) -> str:
    """Undo URL-encoding, HTML entities and mojibake; collapse whitespace."""
    fixed = html.unescape(html.unescape(urllib.parse.unquote(text)))
    fixed = MOJIBAKE_RE.sub(lambda m: MOJIBAKE_MAP[m.group(0)], fixed)
    return " ".join(fixed.replace(chr(0xA0), " ").split())


def normalize_key(text: str) -> str:
    """Lowercase, no accents, only letters/digits, single spaces ('São Paulo' -> 'sao paulo')."""
    decomposed = unicodedata.normalize("NFKD", text)
    no_accents = "".join(c for c in decomposed if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^a-z0-9]+", " ", no_accents.lower()).split())


def skeletons(key: str) -> tuple[str, str]:
    """(tight, loose) exact-match forms: phonetic without spaces, then without connectors."""
    phonetic = key.replace("th", "t").replace("ph", "f").replace("z", "s").replace("y", "i")
    words = re.sub(r"([a-z])\1+", r"\1", phonetic).split()
    return "".join(words), "".join(w for w in words if w not in CONNECTORS)


def name_keys(city_raw: str) -> list[str]:
    """Normalized keys to try, most specific first.

    'jacaré (cabreúva)' -> ['jacare cabreuva', 'jacare']; 'sao paulo - sp' -> [..., 'sao paulo'].
    """
    full = repair_text(city_raw)
    base = DISTRICT_SUFFIX_RE.sub("", full.lower())
    base = QUALIFIER_RE.split(base)[0]
    base = " ".join(re.sub(r"\(.*?\)", " ", base).split())
    return list(dict.fromkeys(k for k in (normalize_key(full), normalize_key(base)) if k))


# --------------------------------------------------------------------------- IBGE reference


@dataclass(frozen=True)
class Municipality:
    ibge_code: int
    name: str
    uf: str
    state_name: str
    region_name: str


def _state_of(m: dict) -> dict:
    """State record (sigla, nome, regiao) of an IBGE municipality; some lack 'microrregiao'."""
    if m.get("microrregiao"):
        return m["microrregiao"]["mesorregiao"]["UF"]
    if m.get("regiao-imediata"):
        return m["regiao-imediata"]["regiao-intermediaria"]["UF"]
    raise ValueError(f"Municipality without state: {m.get('id')} {m.get('nome')}")


def download_ibge() -> list[Municipality]:
    """GET the municipality list from the IBGE API (gzip bodies handled)."""
    try:
        with urllib.request.urlopen(IBGE_URL, timeout=120) as resp:
            body = resp.read()
    except OSError as exc:
        raise RuntimeError(f"Could not download {IBGE_URL}: {exc}") from exc
    if body[:2] == b"\x1f\x8b":  # IBGE may answer gzip even without Accept-Encoding
        body = gzip.decompress(body)
    municipalities = []
    for m in json.loads(body.decode("utf-8")):
        state = _state_of(m)
        municipalities.append(
            Municipality(
                int(m["id"]),
                m["nome"],
                state["sigla"],
                state["nome"],
                state["regiao"]["nome"],
            )
        )
    return municipalities


def load_ibge(refresh: bool) -> list[Municipality]:
    """IBGE municipalities from the local cache, downloading them when missing or asked."""
    if refresh or not IBGE_CACHE.exists():
        municipalities = download_ibge()
        validate_ibge(municipalities)
        IBGE_CACHE.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "source": IBGE_URL,
            "municipalities": [
                m.__dict__ for m in sorted(municipalities, key=lambda m: m.ibge_code)
            ],
        }
        IBGE_CACHE.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"IBGE list downloaded: {len(municipalities):,} municipalities -> {IBGE_CACHE}")
    else:
        payload = json.loads(IBGE_CACHE.read_text(encoding="utf-8"))
        municipalities = [Municipality(**m) for m in payload["municipalities"]]
        validate_ibge(municipalities)
    return municipalities


def validate_ibge(municipalities: list[Municipality]) -> None:
    """Fail fast on an incomplete or inconsistent reference."""
    if len(municipalities) < MIN_MUNICIPALITIES:
        raise RuntimeError(
            f"Expected >= {MIN_MUNICIPALITIES} municipalities, got {len(municipalities)}"
        )
    if len({m.uf for m in municipalities}) != EXPECTED_STATES:
        raise RuntimeError(f"Expected {EXPECTED_STATES} states in the IBGE list")
    if len({m.ibge_code for m in municipalities}) != len(municipalities):
        raise RuntimeError("Duplicated municipality codes in the IBGE list")


class RefIndex:
    """IBGE municipalities indexed by state for the matching rules."""

    def __init__(self, municipalities: list[Municipality]) -> None:
        self.codes = {m.ibge_code for m in municipalities}
        self.by_uf_key: dict[str, dict[str, int]] = defaultdict(dict)
        self.by_uf_skeleton: dict[str, dict[str, set[int]]] = defaultdict(lambda: defaultdict(set))
        for m in municipalities:
            key = normalize_key(m.name)
            self.by_uf_key[m.uf][key] = m.ibge_code
            for skeleton in skeletons(key):
                self.by_uf_skeleton[m.uf][skeleton].add(m.ibge_code)
        self.keys_by_uf = {uf: list(keys) for uf, keys in self.by_uf_key.items()}
        self.brasilia = self.by_uf_key["DF"]["brasilia"]

    def exact(self, key: str, uf: str) -> int | None:
        return self.by_uf_key.get(uf, {}).get(key)

    def alias(self, key: str, uf: str) -> int | None:
        return self.exact(ALIASES[key], uf) if key in ALIASES else None

    def skeleton(self, key: str, uf: str) -> int | None:
        """Unique municipality sharing the tight, then loose, skeleton."""
        by_skeleton = self.by_uf_skeleton.get(uf, {})
        for skeleton in skeletons(key):
            hits = by_skeleton.get(skeleton, set())
            if len(hits) == 1:
                return next(iter(hits))
        return None

    def fuzzy(self, key: str, uf: str) -> int | None:
        """Best candidate passing similarity, single-edit and no-tie guards."""
        if len(key) < MIN_FUZZY_LEN:
            return None
        candidates = process.extract(
            key,
            self.keys_by_uf.get(uf, []),
            scorer=JaroWinkler.normalized_similarity,
            score_cutoff=MIN_SIMILARITY,
            limit=FUZZY_CANDIDATES,
        )
        passing = sorted(
            (OSA.distance(key, choice), -score, choice)
            for choice, score, _ in candidates
            if OSA.distance(key, choice) <= MAX_FUZZY_EDITS
        )
        if not passing or (len(passing) > 1 and passing[0][:2] == passing[1][:2]):
            return None
        return self.by_uf_key[uf][passing[0][2]]


# --------------------------------------------------------------------------- resolution


ZipCities = list[tuple[str, str]]  # (state, city key), most frequent first


def zip_cities(rows: list[pyodbc.Row]) -> dict[str, ZipCities]:
    """zip prefix -> its (state, city key) pairs in silver geolocation, most frequent first.

    Spellings are grouped by normalized key, so 'sao paulo' and 'são paulo' count together.
    """
    counts: dict[str, Counter[tuple[str, str]]] = defaultdict(Counter)
    for zip_prefix, uf, city, n in rows:
        if key := normalize_key(city):
            counts[zip_prefix][(uf, key)] += n
    return {z: [pair for pair, _ in c.most_common()] for z, c in counts.items()}


def resolve(
    city_raw: str, state: str, zip_info: ZipCities | None, ref: RefIndex
) -> tuple[int | None, str]:
    """(IBGE code, match_method) of one (city, state, zip prefix) combination."""
    keys = name_keys(city_raw)
    zip_state = zip_info[0][0] if zip_info else None

    for key in keys:
        if (key, state) in MANUAL_OVERRIDES:
            return MANUAL_OVERRIDES[(key, state)], "manual"
    for key in keys:
        if code := ref.exact(key, state):
            return code, "exact"
    for key in keys:
        if code := ref.alias(key, state):
            return code, "alias"
    if zip_state and zip_state != state:
        for key in keys:
            if code := ref.exact(key, zip_state) or ref.alias(key, zip_state):
                return code, "state_fixed"
    if state == "DF" and keys:
        return ref.brasilia, "admin_region"
    for key in keys:
        if code := ref.skeleton(key, state):
            return code, "spelling"
    for key in keys:
        if code := ref.fuzzy(key, state):
            return code, "fuzzy"
    # Most frequent geolocation city of the zip that is a municipality (districts such as
    # 'bonfim paulista' are skipped in favour of their municipality, when the zip has it)
    for zip_uf, zip_key in zip_info or []:
        code = (
            ref.exact(zip_key, zip_uf)
            or ref.alias(zip_key, zip_uf)
            or ref.skeleton(zip_key, zip_uf)
        )
        if code:
            return code, "zip_city"
    return None, "unmatched"


# --------------------------------------------------------------------------- database


def connect(server: str, database: str) -> pyodbc.Connection:
    """Windows-authenticated connection with the newest SQL Server ODBC driver installed."""
    drivers = [d for d in pyodbc.drivers() if re.fullmatch(r"ODBC Driver \d+ for SQL Server", d)]
    if not drivers:
        raise RuntimeError("No 'ODBC Driver NN for SQL Server' installed")
    driver = max(drivers, key=lambda d: int(re.findall(r"\d+", d)[0]))
    return pyodbc.connect(
        f"DRIVER={{{driver}}};SERVER={server};DATABASE={database};"
        "Trusted_Connection=yes;TrustServerCertificate=yes",
        autocommit=True,
    )


def echo_messages(cur: pyodbc.Cursor) -> None:
    """Print the PRINT output of the etl.* logging procedures."""
    for _, text in cur.messages:
        print(re.sub(r"^\[[^\]]*\]\[[^\]]*\]\[[^\]]*\]", "", text))


def log_table(
    cur: pyodbc.Cursor,
    batch_id: int,
    table: str,
    start: object,
    rows: int,
    status: str = "SUCCESS",
    error: str | None = None,
) -> None:
    cur.execute(
        "EXEC etl.log_table_load @batch_id = ?, @schema_name = 'silver', @table_name = ?, "
        "@start_time = ?, @rows_loaded = ?, @status = ?, @error_message = ?;",
        batch_id,
        table,
        start,
        rows,
        status,
        error,
    )
    echo_messages(cur)


def build(server: str, database: str, refresh_ibge: bool) -> None:
    municipalities = load_ibge(refresh_ibge)
    ref = RefIndex(municipalities)
    bad_overrides = set(MANUAL_OVERRIDES.values()) - ref.codes
    if bad_overrides:
        raise RuntimeError(f"MANUAL_OVERRIDES point to unknown IBGE codes: {sorted(bad_overrides)}")

    with connect(server, database) as conn:
        cur = conn.cursor()
        cur.execute(
            "SET NOCOUNT ON; DECLARE @id INT; "
            "EXEC etl.start_batch @process_name = ?, @layer_name = 'silver', "
            "@batch_id = @id OUTPUT; SELECT @id;",
            PROCESS_NAME,
        )
        batch_id = int(cur.fetchval())
        echo_messages(cur)

        table = "ibge_municipality"
        start = None
        try:
            combos = cur.execute(COMBOS_SQL).fetchall()
            if not combos:
                raise RuntimeError(
                    "silver customers/sellers are empty: run silver.load_silver first"
                )
            zips = zip_cities(cur.execute(ZIP_CITIES_SQL).fetchall())

            map_rows = []
            for city_raw, state_raw, zip_prefix, n_rows in combos:
                code, method = resolve(city_raw, state_raw, zips.get(zip_prefix), ref)
                map_rows.append((city_raw, state_raw, zip_prefix, code, method, n_rows, batch_id))

            conn.autocommit = False
            cur.fast_executemany = True
            cur.execute("DELETE FROM silver.city_map; DELETE FROM silver.ibge_municipality;")

            start = cur.execute("SELECT SYSDATETIME();").fetchval()
            cur.executemany(
                "INSERT INTO silver.ibge_municipality (ibge_code, municipality_name, name_key, uf, "
                "state_name, region_name, dwh_batch_id) VALUES (?, ?, ?, ?, ?, ?, ?);",
                [
                    (
                        m.ibge_code,
                        m.name,
                        normalize_key(m.name),
                        m.uf,
                        m.state_name,
                        m.region_name,
                        batch_id,
                    )
                    for m in municipalities
                ],
            )
            log_table(cur, batch_id, table, start, len(municipalities))

            table = "city_map"
            start = cur.execute("SELECT SYSDATETIME();").fetchval()
            cur.executemany(
                "INSERT INTO silver.city_map (city_raw, state_raw, zip_code_prefix, ibge_code, "
                "match_method, n_rows, dwh_batch_id) VALUES (?, ?, ?, ?, ?, ?, ?);",
                map_rows,
            )
            log_table(cur, batch_id, table, start, len(map_rows))
            conn.commit()
        except Exception as exc:
            if not conn.autocommit:
                conn.rollback()
                conn.autocommit = True
            log_table(
                cur,
                batch_id,
                table,
                start or cur.execute("SELECT SYSDATETIME();").fetchval(),
                0,
                "FAILED",
                str(exc)[:4000],
            )
            cur.execute(
                "EXEC etl.end_batch @batch_id = ?, @status = 'FAILED', @error_message = ?;",
                batch_id,
                str(exc)[:4000],
            )
            echo_messages(cur)
            raise

        conn.autocommit = True
        cur.execute("EXEC etl.end_batch @batch_id = ?, @status = 'SUCCESS';", batch_id)
        echo_messages(cur)

    summary: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for row in map_rows:
        summary[row[4]][0] += 1
        summary[row[4]][1] += row[5]
    print(f"{'match_method':<13} {'combinations':>12} {'rows':>8}")
    for method, (n_combos, n_rows) in sorted(summary.items(), key=lambda kv: -kv[1][1]):
        print(f"{method:<13} {n_combos:>12,} {n_rows:>8,}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--server", default="localhost")
    parser.add_argument("--database", default="OlistDW")
    parser.add_argument(
        "--refresh-ibge",
        action="store_true",
        help="download the IBGE list again instead of using the cache",
    )
    args = parser.parse_args()
    build(args.server, args.database, args.refresh_ibge)


if __name__ == "__main__":
    main()
