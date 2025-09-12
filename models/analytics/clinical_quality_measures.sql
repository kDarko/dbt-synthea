-- Clinical Quality Measures using FHIR Measure specification
{{ config(materialized = 'table') }}

WITH diabetes_patients AS (
  -- Identify diabetic patients using FHIR Condition resources
  SELECT DISTINCT 
    CAST(REGEXP_REPLACE(subject->>'$.reference', 'Patient/', '') AS INTEGER) as person_id
  FROM {{ ref('condition') }}
  WHERE 
    JSON_EXTRACT_SCALAR(code, '$.coding[0].code') IN ('73211009', '44054006', '46635009')
    AND JSON_EXTRACT_SCALAR(clinicalStatus, '$.coding[0].code') = 'active'
),

hba1c_tests AS (
  -- A1C tests from measurements (would need observation FHIR resource)
  SELECT 
    m.person_id,
    m.measurement_date,
    m.value_as_number as hba1c_value,
    ROW_NUMBER() OVER (PARTITION BY m.person_id ORDER BY m.measurement_date DESC) as rn
  FROM {{ ref('measurement') }} m
  INNER JOIN {{ ref('concept') }} c ON m.measurement_concept_id = c.concept_id
  WHERE c.concept_code IN ('4548-4', '17856-6', '4549-2') -- LOINC codes for HbA1c
    AND m.measurement_date >= CURRENT_DATE - INTERVAL '2 years'
),

quality_measure_calculation AS (
  SELECT
    'CMS122v11' as measure_id,
    'Diabetes: Hemoglobin A1c (HbA1c) Poor Control (> 9%)' as measure_name,
    'proportion' as scoring_method,
    
    -- Initial Population
    COUNT(DISTINCT dp.person_id) as initial_population,
    
    -- Denominator: Diabetic patients aged 18-75
    COUNT(DISTINCT CASE 
      WHEN p.year_of_birth <= EXTRACT(YEAR FROM CURRENT_DATE) - 18
        AND p.year_of_birth >= EXTRACT(YEAR FROM CURRENT_DATE) - 75
      THEN dp.person_id 
    END) as denominator,
    
    -- Numerator: Diabetic patients with most recent HbA1c > 9%
    COUNT(DISTINCT CASE 
      WHEN p.year_of_birth <= EXTRACT(YEAR FROM CURRENT_DATE) - 18
        AND p.year_of_birth >= EXTRACT(YEAR FROM CURRENT_DATE) - 75
        AND hba1c.hba1c_value > 9.0
      THEN dp.person_id 
    END) as numerator,
    
    -- Calculate performance rate
    ROUND(
      (COUNT(DISTINCT CASE 
        WHEN p.year_of_birth <= EXTRACT(YEAR FROM CURRENT_DATE) - 18
          AND p.year_of_birth >= EXTRACT(YEAR FROM CURRENT_DATE) - 75
          AND hba1c.hba1c_value > 9.0
        THEN dp.person_id 
      END) * 100.0 / 
      NULLIF(COUNT(DISTINCT CASE 
        WHEN p.year_of_birth <= EXTRACT(YEAR FROM CURRENT_DATE) - 18
          AND p.year_of_birth >= EXTRACT(YEAR FROM CURRENT_DATE) - 75
        THEN dp.person_id 
      END), 0)),
      2
    ) as performance_rate,
    
    CURRENT_DATE as measurement_period_end,
    CURRENT_DATE - INTERVAL '1 year' as measurement_period_start
    
  FROM diabetes_patients dp
  INNER JOIN {{ ref('person') }} p ON dp.person_id = p.person_id  
  LEFT JOIN hba1c_tests hba1c ON dp.person_id = hba1c.person_id AND hba1c.rn = 1
)

-- Generate FHIR MeasureReport structure
SELECT 
  'MeasureReport' as resourceType,
  measure_id as id,
  'individual' as type,
  'complete' as status,
  
  JSON_OBJECT(
    'reference', 'Measure/' || measure_id
  ) as measure,
  
  JSON_OBJECT(
    'start', measurement_period_start::VARCHAR,
    'end', measurement_period_end::VARCHAR  
  ) as period,
  
  JSON_ARRAY(
    JSON_OBJECT(
      'code', JSON_OBJECT(
        'coding', JSON_ARRAY(
          JSON_OBJECT(
            'system', 'http://terminology.hl7.org/CodeSystem/measure-population',
            'code', 'initial-population',
            'display', 'Initial Population'  
          )
        )
      ),
      'count', initial_population
    ),
    JSON_OBJECT(
      'code', JSON_OBJECT(
        'coding', JSON_ARRAY(
          JSON_OBJECT(
            'system', 'http://terminology.hl7.org/CodeSystem/measure-population',
            'code', 'denominator',
            'display', 'Denominator'
          )
        )
      ),
      'count', denominator  
    ),
    JSON_OBJECT(
      'code', JSON_OBJECT(
        'coding', JSON_ARRAY(
          JSON_OBJECT(
            'system', 'http://terminology.hl7.org/CodeSystem/measure-population', 
            'code', 'numerator',
            'display', 'Numerator'
          )
        )
      ),
      'count', numerator
    )
  ) as group_population,
  
  -- Additional metadata
  performance_rate,
  measure_name,
  scoring_method

FROM quality_measure_calculation