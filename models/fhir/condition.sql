-- FHIR R4 Condition resource from OMOP condition_occurrence
{{ config(materialized = 'table') }}

WITH condition_with_concepts AS (
  SELECT 
    co.*,
    c.concept_code,
    c.concept_name,
    c.vocabulary_id
  FROM {{ ref('condition_occurrence') }} co
  INNER JOIN {{ ref('concept') }} c ON co.condition_concept_id = c.concept_id
)

SELECT
  -- FHIR Resource metadata
  'Condition' AS resourceType,
  CAST(condition_occurrence_id AS VARCHAR) AS id,
  
  -- FHIR Condition.clinicalStatus
  JSON_OBJECT(
    'coding', JSON_ARRAY(
      JSON_OBJECT(
        'system', 'http://terminology.hl7.org/CodeSystem/condition-clinical',
        'code', CASE 
          WHEN condition_end_date IS NULL THEN 'active'
          ELSE 'resolved'
        END,
        'display', CASE 
          WHEN condition_end_date IS NULL THEN 'Active'
          ELSE 'Resolved'
        END
      )
    )
  ) AS clinicalStatus,
  
  -- FHIR Condition.verificationStatus
  JSON_OBJECT(
    'coding', JSON_ARRAY(
      JSON_OBJECT(
        'system', 'http://terminology.hl7.org/CodeSystem/condition-ver-status',
        'code', 'confirmed',
        'display', 'Confirmed'
      )
    )
  ) AS verificationStatus,
  
  -- FHIR Condition.code using FHIR macro
  {{ fhir_codeable_concept(
      'condition_concept_id',
      'concept_code', 
      'concept_name',
      'vocabulary_id',
      'condition_source_value'
  ) }} AS code,
  
  -- FHIR Condition.subject (reference to Patient)
  JSON_OBJECT(
    'reference', 'Patient/' || CAST(person_id AS VARCHAR)
  ) AS subject,
  
  -- FHIR Condition.encounter (reference to Encounter if available)
  CASE 
    WHEN visit_occurrence_id IS NOT NULL THEN
      JSON_OBJECT(
        'reference', 'Encounter/' || CAST(visit_occurrence_id AS VARCHAR)
      )
    ELSE NULL
  END AS encounter,
  
  -- FHIR Condition.onsetDateTime
  condition_start_date AS onsetDateTime,
  
  -- FHIR Condition.abatementDateTime  
  condition_end_date AS abatementDateTime,
  
  -- FHIR Condition.recordedDate
  condition_start_date AS recordedDate
  
FROM condition_with_concepts