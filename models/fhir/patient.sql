-- FHIR R4 Patient resource generation from OMOP Person
{{ config(
    materialized = 'table',
    indexes=[
      {'columns': ['id'], 'unique': true},
      {'columns': ['identifier_value']}
    ]
) }}

WITH patient_base AS (
  SELECT 
    p.person_id,
    p.gender_concept_id,
    p.year_of_birth,
    p.month_of_birth,
    p.day_of_birth,
    p.race_concept_id,
    p.ethnicity_concept_id,
    p.person_source_value,
    p.gender_source_value,
    p.race_source_value,
    p.ethnicity_source_value,
    l.address_1,
    l.city,
    l.state,
    l.zip,
    l.county
  FROM {{ ref('person') }} p
  LEFT JOIN {{ ref('location') }} l ON p.location_id = l.location_id
)

SELECT
  -- FHIR Resource metadata
  'Patient' AS resourceType,
  CAST(person_id AS VARCHAR) AS id,
  
  -- FHIR Patient.identifier
  JSON_ARRAY(
    JSON_OBJECT(
      'use', 'usual',
      'system', 'urn:synthea:patient',
      'value', person_source_value
    )
  ) AS identifier,
  
  -- FHIR Patient.active  
  true AS active,
  
  -- FHIR Patient.gender (mapped from OMOP concepts)
  CASE 
    WHEN gender_concept_id = 8507 THEN 'male'
    WHEN gender_concept_id = 8532 THEN 'female' 
    ELSE 'unknown'
  END AS gender,
  
  -- FHIR Patient.birthDate
  CASE 
    WHEN year_of_birth IS NOT NULL THEN
      CAST(year_of_birth AS VARCHAR) || 
      COALESCE('-' || LPAD(CAST(month_of_birth AS VARCHAR), 2, '0'), '') ||
      COALESCE('-' || LPAD(CAST(day_of_birth AS VARCHAR), 2, '0'), '')
    ELSE NULL
  END AS birthDate,
  
  -- FHIR Patient.address
  CASE 
    WHEN address_1 IS NOT NULL THEN
      JSON_ARRAY(
        JSON_OBJECT(
          'use', 'home',
          'line', JSON_ARRAY(address_1),
          'city', city,
          'state', state,
          'postalCode', zip,
          'district', county,
          'country', 'US'
        )
      )
    ELSE NULL
  END AS address,
  
  -- FHIR Patient.extension for race and ethnicity (US Core extensions)
  JSON_ARRAY(
    -- Race extension
    JSON_OBJECT(
      'url', 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-race',
      'extension', JSON_ARRAY(
        JSON_OBJECT(
          'url', 'ombCategory',
          'valueCoding', JSON_OBJECT(
            'system', 'urn:oid:2.16.840.1.113883.6.238',
            'code', CASE 
              WHEN race_concept_id = 8527 THEN '2106-3'  -- White
              WHEN race_concept_id = 8516 THEN '2054-5'  -- Black
              WHEN race_concept_id = 8515 THEN '2028-9'  -- Asian
              ELSE 'UNK'
            END,
            'display', race_source_value
          )
        ),
        JSON_OBJECT(
          'url', 'text',
          'valueString', race_source_value
        )
      )
    ),
    -- Ethnicity extension  
    JSON_OBJECT(
      'url', 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity',
      'extension', JSON_ARRAY(
        JSON_OBJECT(
          'url', 'ombCategory', 
          'valueCoding', JSON_OBJECT(
            'system', 'urn:oid:2.16.840.1.113883.6.238',
            'code', CASE
              WHEN ethnicity_concept_id = 38003563 THEN '2135-2'  -- Hispanic
              WHEN ethnicity_concept_id = 38003564 THEN '2186-5'  -- Non-Hispanic
              ELSE 'UNK'
            END,
            'display', ethnicity_source_value
          )
        ),
        JSON_OBJECT(
          'url', 'text',
          'valueString', ethnicity_source_value
        )
      )
    )
  ) AS extension
  
FROM patient_base