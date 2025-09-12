# dbt-synthea Macros Documentation

## Overview

The `macros/` folder contains 10 custom dbt macros that provide essential functionality for the dbt-synthea project. These macros handle database operations, data transformations, cross-database compatibility, and utility functions needed for the Synthea-to-OMOP ETL process.

## File Structure

```
macros/
├── .gitkeep                    # Git placeholder file
├── check_if_exists.sql         # Table existence validation
├── create_synthea_tables.sql   # Synthea table schema creation (see CODEBASE_DOCUMENTATION.md)
├── create_vocab_tables.sql     # OMOP vocabulary table schema creation
├── load_data_duckdb.sql        # DuckDB data loading utility
├── lowercase_columns.sql       # Column name standardization
├── macros.yml                  # Macro documentation metadata
├── regexp_like.sql            # Cross-database regex function
├── safe_hash.sql              # NULL-safe hashing utility
└── timestamptz_to_naive.sql   # Timezone conversion utility
```

---

## Macro Detailed Documentation

### 1. check_if_exists.sql

**Purpose**: Checks if a table exists in the specified database and schema.

**Function Signature**:
```sql
check_if_exists(database, schema, table) → boolean
```

**Parameters**:
- `database` (string): Database name
- `schema` (string): Schema name  
- `table` (string): Table name

**Returns**: Boolean indicating whether the table exists

**Implementation Details**:
```sql
{% macro check_if_exists(database, schema, table) %}
{%- set source_relation = adapter.get_relation(
      database=database,
      schema=schema,
      identifier=table) -%}

{% set table_exists=source_relation is not none  %}
{{ return(table_exists) }}
{% endmacro %}
```

**Usage Example**:
```sql
{% if not check_if_exists(target.database, target.schema, 'concept') %}
    CREATE TABLE {{target.schema}}.concept (...);
{% endif %}
```

**Use Cases**:
- Conditional table creation to avoid errors
- Schema validation before data operations
- Idempotent database operations

---

### 2. create_vocab_tables.sql

**Purpose**: Creates the complete set of OMOP vocabulary tables with proper schemas if they don't already exist.

**Function Signature**:
```sql
create_vocab_tables() → void
```

**Parameters**: None

**Tables Created**:
1. **concept** - Core OMOP concepts with metadata
2. **vocabulary** - Medical terminology systems  
3. **domain** - Clinical domains (Condition, Drug, etc.)
4. **concept_class** - Concept classifications
5. **concept_relationship** - Relationships between concepts
6. **relationship** - Relationship type definitions
7. **concept_synonym** - Alternative concept names
8. **concept_ancestor** - Concept hierarchies
9. **drug_strength** - Drug dosage information
10. **source_to_concept_map** - Source-to-standard mappings

**Key Features**:
- **Idempotent**: Uses `check_if_exists()` to avoid duplicate creation
- **OMOP Compliant**: Follows exact OMOP CDM v6.0 specifications
- **Data Types**: Proper column types and constraints
- **Transaction Safety**: All operations wrapped in a single transaction

**Schema Examples**:

```sql
-- Concept table structure
CREATE TABLE schema.concept (
    concept_id integer NOT NULL,
    concept_name varchar(255) NOT NULL,
    domain_id varchar(20) NOT NULL,
    vocabulary_id varchar(20) NOT NULL,
    concept_class_id varchar(20) NOT NULL,
    standard_concept varchar(1) NULL,
    concept_code varchar(50) NOT NULL,
    valid_start_date date NOT NULL,
    valid_end_date date NOT NULL,
    invalid_reason varchar(1) NULL
);

-- Drug strength table with numeric precision
CREATE TABLE schema.drug_strength (
    drug_concept_id integer NOT NULL,
    ingredient_concept_id integer NOT NULL,
    amount_value NUMERIC NULL,
    numerator_value NUMERIC NULL,
    denominator_value NUMERIC NULL,
    -- ... additional columns
);
```

**Usage Example**:
```bash
# Run as dbt operation
dbt run-operation create_vocab_tables
```

---

### 3. load_data_duckdb.sql

**Purpose**: Bulk loads CSV or Parquet files into DuckDB tables for either Synthea data or vocabulary data.

**Function Signature**:
```sql
load_data_duckdb(file_dict, vocab_tables) → void
```

**Parameters**:
- `file_dict` (dict): Dictionary mapping table names to file paths
- `vocab_tables` (boolean): True for vocabulary data, False for Synthea data

**Key Features**:
- **Multi-format Support**: Handles both CSV and Parquet files
- **Auto-detection**: Determines file format from first file extension
- **Schema Management**: Creates target schemas automatically
- **Data Type Handling**: Applies appropriate transformations post-load

**File Format Handling**:

1. **Parquet Files** (recommended for performance):
   - Creates views using DuckDB's `read_parquet()` function
   - Zero-copy operations for better performance
   - Preserves original data types

2. **CSV Files**:
   - Creates tables using DuckDB's `read_csv()` function  
   - Handles quoted fields with empty quote parameter
   - Applies post-load transformations

**Schema Targeting**:
```sql
{% if vocab_tables %}
    {% set target_schema = target.schema %}          -- e.g., 'dbt_synthea_dev'
{% else %}
    {% set target_schema = target.schema ~ '_synthea' %}  -- e.g., 'dbt_synthea_dev_synthea'
{% endif %}
```

**Post-Load Transformations**:

1. **Vocabulary Tables** (date formatting):
```sql
-- Converts YYYYMMDD strings to proper DATE types
ALTER TABLE schema.concept 
ALTER valid_start_date TYPE DATE 
USING strptime(CAST(valid_start_date AS VARCHAR), '%Y%m%d');
```

2. **Synthea Tables** (code field standardization):
```sql
-- Ensures CODE columns are VARCHAR type
ALTER TABLE schema.medications ALTER CODE TYPE VARCHAR;
```

**Usage Example**:
```bash
# Get file dictionary from Python script
file_dict=$(python3 scripts/python/get_filepaths.py /path/to/synthea/files)

# Load Synthea data
dbt run-operation load_data_duckdb --args "{file_dict: $file_dict, vocab_tables: false}"

# Load vocabulary data
file_dict=$(python3 scripts/python/get_filepaths.py /path/to/vocab/files)
dbt run-operation load_data_duckdb --args "{file_dict: $file_dict, vocab_tables: true}"
```

---

### 4. lowercase_columns.sql

**Purpose**: Standardizes column names to lowercase while handling SQL reserved keywords safely.

**Function Signature**:
```sql
lowercase_columns(column_names) → string
```

**Parameters**:
- `column_names` (list): List of column names to process

**Returns**: Comma-separated SELECT clause with aliased columns

**SQL Keywords Handled**:
```sql
["start", "stop", "type", "system", "date", "first", "last", "value", "name"]
```

**Logic**:
1. **Regular Columns**: `"COLUMN_NAME" AS column_name`
2. **SQL Keywords**: `"COLUMN_NAME" AS "column_name"` (quoted for safety)

**Implementation**:
```sql
{% for column_name in column_names %} 
    {% set lowercase_column = column_name | lower %}
    {% if column_name | lower in sql_keywords %}
        "{{ column_name }}" AS "{{ lowercase_column }}"  -- Quoted keyword
    {% else %}
        "{{ column_name }}" AS {{ lowercase_column }}     -- Unquoted regular column
    {% endif %}
    {% if not loop.last %},{% endif %}  -- Comma separation
{% endfor %}
```

**Usage Example**:
```sql
-- Input: ['PATIENT_ID', 'START', 'STOP', 'DESCRIPTION']
-- Output: 
SELECT 
    "PATIENT_ID" AS patient_id,
    "START" AS "start",
    "STOP" AS "stop", 
    "DESCRIPTION" AS description
FROM source_table
```

**Use Cases**:
- Staging model column standardization
- Handling source systems with inconsistent naming
- SQL injection prevention through proper quoting

---

### 5. regexp_like.sql

**Purpose**: Provides cross-database regex functionality using dbt's dispatch pattern.

**Function Signature**:
```sql
regexp_like(subject, pattern) → boolean
```

**Parameters**:
- `subject` (string): Text to search in
- `pattern` (string): Regular expression pattern

**Returns**: Boolean indicating if pattern matches

**Database Implementations**:

1. **Default** (PostgreSQL, DuckDB, etc.):
```sql
{{ subject }} ~ '{{ pattern }}'
```

2. **Snowflake**:
```sql
regexp_like({{ subject }}, '{{ pattern }}')
```

**Usage Example**:
```sql
SELECT *
FROM patients 
WHERE {{ regexp_like('patient_id', '^P[0-9]{8}$') }}
-- Matches patient IDs like 'P12345678'
```

**Dispatch Pattern Benefits**:
- **Database Agnostic**: Same macro works across platforms
- **Maintainable**: Single interface, platform-specific implementations
- **Extensible**: Easy to add new database support

---

### 6. safe_hash.sql

**Purpose**: Generates consistent MD5 hashes from multiple columns while handling NULL values gracefully.

**Function Signature**:
```sql
safe_hash(columns) → string
```

**Parameters**:
- `columns` (list): List of column names to hash together

**Returns**: MD5 hash string

**Documented in macros.yml**:
```yaml
macros:
  - name: safe_hash
    description: This macro allows concatenation and hashing of fields that may contain `NULL` elements. For example, fields in an address.
    arguments:
      - name: columns
        type: list[str]
        description: A list of column names
```

**Implementation Details**:
```sql
{%- macro safe_hash(columns) -%}
{% set coalesced_columns = [] %}
{%- for column in columns -%}
  {% do coalesced_columns.append("COALESCE(" ~ column.lower() ~ ", '')") %}
{%- endfor -%}
  MD5(
    {{ dbt.concat(coalesced_columns) }}
  )
{%- endmacro -%}
```

**Key Features**:
- **NULL Safety**: Uses COALESCE to convert NULLs to empty strings
- **Deterministic**: Same inputs always produce same hash
- **Cross-database**: Uses dbt.concat() for database compatibility

**Usage Example**:
```sql
-- Address hashing in int__location.sql
SELECT 
    {{ safe_hash(['address', 'city', 'state', 'zip']) }} AS location_hash
FROM patients

-- Expands to:
-- MD5(CONCAT(COALESCE(address, ''), COALESCE(city, ''), COALESCE(state, ''), COALESCE(zip, '')))
```

**Use Cases**:
- **Location Deduplication**: Creating unique address identifiers
- **Change Detection**: Identifying when composite keys change
- **Data Integrity**: Consistent hashing across pipeline runs

---

### 7. timestamptz_to_naive.sql

**Purpose**: Converts timezone-aware timestamps to naive timestamps in a specified timezone.

**Function Signature**:
```sql
timestamptz_to_naive(column, target_tz=None) → timestamp
```

**Parameters**:
- `column` (timestamp with timezone): Source timestamp column
- `target_tz` (string, optional): Target timezone (defaults to UTC)

**Returns**: Naive timestamp in target timezone

**Database Implementations**:

1. **Default** (PostgreSQL, DuckDB, Redshift):
```sql
{{ column }} AT TIME ZONE '{{ target_tz }}'
```

2. **Snowflake**:
```sql
CONVERT_TIMEZONE('{{ target_tz }}', {{ column }})::timestamp
```

**Timezone Handling**:
```sql
{%- set target_tz = var("dbt_date:time_zone", "UTC") if target_tz is none else target_tz -%}
```
- Uses dbt variable `dbt_date:time_zone` if available
- Falls back to UTC if no timezone specified
- Allows per-call timezone override

**Usage Example**:
```sql
SELECT 
    encounter_start,
    {{ timestamptz_to_naive('encounter_start', 'America/New_York') }} AS encounter_start_et
FROM encounters
```

**Use Cases**:
- **Timezone Normalization**: Converting all timestamps to a standard timezone
- **Reporting**: Displaying times in user's local timezone  
- **Data Consistency**: Removing timezone information for downstream systems

---

### 8. macros.yml

**Purpose**: Provides metadata and documentation for macros in the project.

**Structure**:
```yaml
macros:
  - name: safe_hash
    description: This macro allows concatenation and hashing of fields that may contain `NULL` elements. For example, fields in an address.
    arguments:
      - name: columns
        type: list[str]
        description: A list of column names
```

**Benefits**:
- **Documentation**: Describes macro purpose and parameters
- **Type Safety**: Specifies expected parameter types
- **IDE Support**: Enables autocomplete and validation in dbt tools
- **Generated Docs**: Appears in dbt-generated documentation

---

### 9. .gitkeep

**Purpose**: Git placeholder file to ensure the macros directory is tracked in version control even when empty.

**Details**:
- Empty file used by Git to track otherwise empty directories
- No functional impact on dbt operations
- Standard practice for maintaining directory structure

---

## Cross-Database Compatibility

Several macros use dbt's **dispatch pattern** for cross-database compatibility:

### Dispatch Pattern Example:
```sql
-- Main macro uses dispatch to call database-specific implementation
{% macro regexp_like(subject, pattern) %}
    {{ return(adapter.dispatch("regexp_like")(subject, pattern)) }}
{% endmacro %}

-- Default implementation (PostgreSQL, DuckDB, etc.)
{% macro default__regexp_like(subject, pattern) %}
    {{ subject }} ~ '{{ pattern }}'
{% endmacro %}

-- Snowflake-specific implementation
{% macro snowflake__regexp_like(subject, pattern) %}
    regexp_like({{ subject }}, '{{ pattern }}')
{% endmacro %}
```

### Database Support Matrix:

| Macro | PostgreSQL | DuckDB | Snowflake | Notes |
|-------|------------|--------|-----------|-------|
| `check_if_exists` | ✅ | ✅ | ✅ | Uses dbt adapter interface |
| `create_vocab_tables` | ✅ | ✅ | ⚠️ | SQL DDL may need adjustment |
| `load_data_duckdb` | ❌ | ✅ | ❌ | DuckDB-specific functions |
| `lowercase_columns` | ✅ | ✅ | ✅ | Pure string manipulation |
| `regexp_like` | ✅ | ✅ | ✅ | Dispatch pattern |
| `safe_hash` | ✅ | ✅ | ✅ | Uses dbt.concat() |
| `timestamptz_to_naive` | ✅ | ✅ | ✅ | Dispatch pattern |

## Usage Patterns

### 1. Operations Macros
```bash
# Run as dbt operations (not in models)
dbt run-operation create_vocab_tables
dbt run-operation create_synthea_tables
dbt run-operation load_data_duckdb --args "{file_dict: $dict, vocab_tables: true}"
```

### 2. Model Macros
```sql
-- Used within model SELECT statements
SELECT {{ safe_hash(['addr', 'city']) }} AS addr_hash
FROM {{ ref('source_table') }}
WHERE {{ regexp_like('id', '^[A-Z]{2}[0-9]{6}$') }}
```

### 3. Conditional Logic
```sql
{% if check_if_exists(target.database, target.schema, 'existing_table') %}
    -- Table exists logic
{% else %}
    -- Table doesn't exist logic  
{% endif %}
```

## Performance Considerations

1. **load_data_duckdb**:
   - Parquet files are significantly faster than CSV
   - Consider converting large CSV files to Parquet
   - Views (Parquet) vs Tables (CSV) have different memory implications

2. **safe_hash**:
   - MD5 computation can be expensive on large datasets
   - Consider materialization strategy for tables using this macro
   - Hash collisions are theoretically possible but extremely rare

3. **timestamptz_to_naive**:
   - Timezone conversions can be computationally expensive
   - Consider performing once in staging layer rather than repeatedly

## Error Handling

1. **File Path Validation**: `load_data_duckdb` assumes valid file paths
2. **Table Dependencies**: Vocabulary table creation assumes proper dependencies
3. **Data Type Compatibility**: Column transformations may fail with incompatible data

## Maintenance Notes

1. **OMOP Version Updates**: `create_vocab_tables` may need updates for new OMOP versions
2. **Database Support**: New database adapters may require additional dispatch implementations
3. **SQL Keywords**: `lowercase_columns` keyword list may need updates for new SQL standards

---

*This documentation covers all macros in the dbt-synthea project as of the current version. For implementation details and usage examples, refer to the actual macro files and project models.*
