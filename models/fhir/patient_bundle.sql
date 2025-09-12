-- FHIR Bundle for complete patient record (Patient + associated resources)
{{ config(materialized = 'table') }}

WITH patient_resources AS (
  -- Patient resource
  SELECT 
    p.id as patient_id,
    'Patient' as resource_type,
    TO_JSON(p.*) as resource_json,
    1 as resource_order
  FROM {{ ref('patient') }} p
  
  UNION ALL
  
  -- Condition resources for the patient
  SELECT 
    CAST(JSON_EXTRACT_SCALAR(c.subject, '$.reference') AS VARCHAR) as patient_id,
    'Condition' as resource_type, 
    TO_JSON(c.*) as resource_json,
    2 as resource_order
  FROM {{ ref('condition') }} c
  
  UNION ALL
  
  -- Observation resources (if implemented)
  SELECT
    CAST(JSON_EXTRACT_SCALAR(o.subject, '$.reference') AS VARCHAR) as patient_id,
    'Observation' as resource_type,
    TO_JSON(o.*) as resource_json,
    3 as resource_order  
  FROM {{ ref('observation') }} o
  WHERE EXISTS (SELECT 1 FROM {{ ref('patient') }} p WHERE p.id = 
    CAST(JSON_EXTRACT_SCALAR(o.subject, '$.reference') AS VARCHAR))
),

bundle_entries AS (
  SELECT 
    patient_id,
    JSON_OBJECT(
      'fullUrl', 'urn:uuid:' || resource_type || '-' || 
        CAST(ROW_NUMBER() OVER (PARTITION BY patient_id, resource_type ORDER BY resource_order) AS VARCHAR),
      'resource', resource_json
    ) as entry
  FROM patient_resources
)

SELECT
  'Bundle' AS resourceType,
  CAST(patient_id AS VARCHAR) AS id,
  'collection' AS type,
  JSON_OBJECT(
    'total', (SELECT COUNT(*) FROM bundle_entries be WHERE be.patient_id = b.patient_id),
    'lastUpdated', CURRENT_TIMESTAMP
  ) AS meta,
  JSON_ARRAYAGG(b.entry) AS entry

FROM bundle_entries b
GROUP BY patient_id