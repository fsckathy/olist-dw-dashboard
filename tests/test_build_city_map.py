"""Unit tests for the matching rules of src/build_city_map.py (no database needed).

Run:
    python -m uv run --no-project --with pytest --with pyodbc --with rapidfuzz \
        pytest tests/test_build_city_map.py
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_PATH = Path(__file__).resolve().parents[1] / "src" / "build_city_map.py"
_SPEC = importlib.util.spec_from_file_location("build_city_map", _PATH)
assert _SPEC and _SPEC.loader
bcm = importlib.util.module_from_spec(_SPEC)
sys.modules["build_city_map"] = bcm
_SPEC.loader.exec_module(bcm)

M = bcm.Municipality
REF = bcm.RefIndex(
    [
        M(3550308, "São Paulo", "SP", "São Paulo", "Sudeste"),
        M(3548708, "São Bernardo do Campo", "SP", "São Paulo", "Sudeste"),
        M(3543402, "Ribeirão Preto", "SP", "São Paulo", "Sudeste"),
        M(3547502, "Santa Bárbara d'Oeste", "SP", "São Paulo", "Sudeste"),
        M(3515004, "Embu das Artes", "SP", "São Paulo", "Sudeste"),
        M(4205407, "Florianópolis", "SC", "Santa Catarina", "Sul"),
        M(3303807, "Paraty", "RJ", "Rio de Janeiro", "Sudeste"),
        M(5300108, "Brasília", "DF", "Distrito Federal", "Centro-Oeste"),
    ]
)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("São Paulo", ["sao paulo"]),
        ("sao paulo - sp", ["sao paulo sp", "sao paulo"]),
        ("pinhais/pr", ["pinhais pr", "pinhais"]),
        (
            "novo hamburgo, rio grande do sul, brasil",
            ["novo hamburgo rio grande do sul brasil", "novo hamburgo"],
        ),
        ("jacaré (cabreúva)", ["jacare cabreuva", "jacare"]),
        ("santa barbara d´oeste", ["santa barbara d oeste"]),
    ],
)
def test_name_keys(raw: str, expected: list[str]) -> None:
    assert bcm.name_keys(raw) == expected


@pytest.mark.parametrize(
    ("city", "state", "zip_info", "expected"),
    [
        # accents and symbols do not matter
        ("são paulo", "SP", None, (3550308, "exact")),
        ("santa barbara d'oeste", "SP", None, (3547502, "exact")),
        ("santa barbara d´oeste", "SP", None, (3547502, "exact")),
        ("sao paulo - sp", "SP", None, (3550308, "exact")),
        # renamed municipality
        ("embu", "SP", None, (3515004, "alias")),
        # declared state wrong, zip state right
        ("florianopolis", "SP", [("SC", "florianopolis")], (4205407, "state_fixed")),
        # any DF locality is Brasília
        ("taguatinga", "DF", None, (5300108, "admin_region")),
        # spelling skeleton (y = i) and one-typo fuzzy on a long name
        ("parati", "RJ", None, (3303807, "spelling")),
        ("sao bernardo do capo", "SP", None, (3548708, "fuzzy")),
        # name unusable: city of the zip; a district is skipped for its municipality
        ("sbc", "SP", [("SP", "sao bernardo do campo")], (3548708, "zip_city")),
        ("vendas@creditparts.com.br", "SP", [("SP", "sao paulo")], (3550308, "zip_city")),
        (
            "bonfim paulista",
            "SP",
            [("SP", "bonfim paulista"), ("SP", "ribeirao preto")],
            (3543402, "zip_city"),
        ),
        # nothing matches
        ("lugar nenhum", "SP", [("SP", "lugar nenhum")], (None, "unmatched")),
    ],
)
def test_resolve(
    city: str, state: str, zip_info: list[tuple[str, str]] | None, expected: tuple[int | None, str]
) -> None:
    assert bcm.resolve(city, state, zip_info, REF) == expected


def test_short_names_are_never_fuzzy_matched() -> None:
    assert REF.fuzzy("sao paulx", "SP") is None  # 9 chars < MIN_FUZZY_LEN


def test_zip_cities_groups_spellings() -> None:
    rows = [
        ("01001", "SP", "sao paulo", 5),
        ("01001", "SP", "são paulo", 4),
        ("01001", "SP", "osasco", 8),
    ]
    assert bcm.zip_cities(rows) == {"01001": [("SP", "sao paulo"), ("SP", "osasco")]}
