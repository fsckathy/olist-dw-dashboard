/*
===============================================================================
SCRIPT: Create Database and Schemas
===============================================================================
PURPOSE:
    Creates the OlistDw database and the medallion schemas:
        bronze - raw data, Olist CSV files
        silver - cleaned, typed and keyed data
        gold   - star schema for Power BI
        etl    - pipeline monitoring 
    Idempotent: objects are created only if missing.
USAGE:
    Run first. Then run 02_create_etl_monitoring_tables.sql.
===============================================================================
*/
USE master;
GO

-- ----------------------------------------------------------------------------
-- 1.0 Create Database (Idempotent)
-- ----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'OlistDW')
BEGIN
    CREATE DATABASE OlistDW;
    PRINT 'Database [OlistDW] created successfully.';
END
ELSE
    PRINT 'Database [OlistDW] already exists. Skipping creation.';
GO

USE OlistDW;
GO

ALTER DATABASE OlistDW SET RECOVERY SIMPLE;
GO

-- ----------------------------------------------------------------------------
-- 2.0 Create Schemas (Idempotent)
-- ----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bronze')
    EXEC ('CREATE SCHEMA bronze');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver')
    EXEC ('CREATE SCHEMA silver');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')
    EXEC ('CREATE SCHEMA gold');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'etl')
    EXEC ('CREATE SCHEMA etl');
GO

-- ----------------------------------------------------------------------------
-- 3.0 Deployment Summary
-- ----------------------------------------------------------------------------
PRINT '================================================';
PRINT 'DEPLOYMENT SUMMARY:';
PRINT '  Database   : OlistDW';
PRINT '  Schemas    : bronze, silver, gold, etl';
PRINT '  Recovery   : SIMPLE';
PRINT '  Status     : SUCCESS';
PRINT '================================================';
GO
