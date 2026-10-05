/*
===============================================================================
DDL Script: Create City Reference Tables (IBGE)
===============================================================================
PURPOSE:
    Official municipality names for the customer and seller cities, which come typed by
    hand in the source.
        silver.ibge_municipality - one row per Brazilian municipality (IBGE API)
        silver.city_map          - one row per (city, state, zip prefix) found in silver
                                   customers/sellers -> IBGE municipality code
    Both tables are filled by src/build_city_map.py: the dataset is static, so 
    the map is rebuilt on demand, after silver and before gold.
    gold.load_gold reads the map with a LEFT JOIN and falls back to the source spelling, so
    an empty or stale map never breaks the gold load (tests/silver_quality_checks.sql
    reports it).
    Unlike the other silver tables, city_map has a foreign key: both tables are always
    replaced together, in one transaction, by the same script.
    Drops and recreates the tables.
USAGE:
    Run after silver/ddl_silver_tables.sql, then:
        python -m uv run src/build_city_map.py
===============================================================================
*/
USE OlistDW;
GO

DROP TABLE IF EXISTS silver.city_map;
DROP TABLE IF EXISTS silver.ibge_municipality;
GO

-- ----------------------------------------------------------------------------
-- TABLE 1: silver.ibge_municipality
-- Source: https://servicodados.ibge.gov.br/api/v1/localidades/municipios
-- ----------------------------------------------------------------------------
CREATE TABLE silver.ibge_municipality (
    ibge_code         INT           NOT NULL,  -- 7-digit IBGE municipality code
    municipality_name NVARCHAR(100) NOT NULL,  -- official name, e.g. 'São Paulo'
    name_key          NVARCHAR(100) NOT NULL,  -- lowercase, no accents: 'sao paulo'
    uf                CHAR(2)       NOT NULL,
    state_name        NVARCHAR(50)  NOT NULL,
    region_name       NVARCHAR(20)  NOT NULL,  -- IBGE name (Portuguese): Norte, Sudeste...
    dwh_batch_id      INT           NOT NULL,
    dwh_load_date     DATETIME2(0)  NOT NULL CONSTRAINT df_silver_ibge_municipality_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_ibge_municipality PRIMARY KEY (ibge_code)
);
CREATE INDEX ix_silver_ibge_municipality_key ON silver.ibge_municipality (uf, name_key);
GO

-- ----------------------------------------------------------------------------
-- TABLE 2: silver.city_map
-- ----------------------------------------------------------------------------
CREATE TABLE silver.city_map (
    city_raw        NVARCHAR(100) NOT NULL, 
    state_raw       CHAR(2)       NOT NULL,
    zip_code_prefix CHAR(5)       NOT NULL,
    ibge_code       INT           NULL,
    match_method    VARCHAR(20)   NOT NULL,
    n_rows          INT           NOT NULL,  
    dwh_batch_id    INT           NOT NULL,
    dwh_load_date   DATETIME2(0)  NOT NULL CONSTRAINT df_silver_city_map_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_city_map PRIMARY KEY (city_raw, state_raw, zip_code_prefix),
    CONSTRAINT fk_silver_city_map_ibge FOREIGN KEY (ibge_code)
        REFERENCES silver.ibge_municipality (ibge_code),
    CONSTRAINT ck_silver_city_map_method CHECK (match_method IN (
        'manual', 'exact', 'alias', 'state_fixed', 'admin_region', 'spelling', 'fuzzy',
        'zip_city', 'unmatched')),
    CONSTRAINT ck_silver_city_map_code CHECK (
        (match_method = 'unmatched' AND ibge_code IS NULL)
        OR (match_method <> 'unmatched' AND ibge_code IS NOT NULL))
);
GO

PRINT '============================================================';
PRINT 'DEPLOYMENT SUMMARY:';
PRINT '  Tables : silver.ibge_municipality, silver.city_map';
PRINT '  Next   : python -m uv run src/build_city_map.py';
PRINT '============================================================';
GO
