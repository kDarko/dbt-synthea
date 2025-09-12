-- Population Health Analytics leveraging FHIR and OMOP data
{{ config(
    materialized = 'table',
    indexes=[
      {'columns': ['metric_category', 'measurement_period']},
      {'columns': ['geographic_region']}
    ]
) }}

WITH patient_demographics AS (
  SELECT 
    p.id as patient_id,
    EXTRACT(YEAR FROM CURRENT_DATE) - p.year_of_birth as current_age,
    p.gender,
    JSON_EXTRACT_SCALAR(p.address[0], '$.state') as state,
    JSON_EXTRACT_SCALAR(p.address[0], '$.district') as county,
    -- Extract race from US Core extension
    JSON_EXTRACT_SCALAR(
      p.extension[0], 
      '$.extension[0].valueCoding.display'
    ) as race,
    -- Extract ethnicity from US Core extension  
    JSON_EXTRACT_SCALAR(
      p.extension[1],
      '$.extension[0].valueCoding.display'
    ) as ethnicity
  FROM {{ ref('patient') }} p
),

condition_prevalence AS (
  SELECT
    JSON_EXTRACT_SCALAR(c.code, '$.coding[0].display') as condition_name,
    JSON_EXTRACT_SCALAR(c.code, '$.coding[0].code') as condition_code,
    COUNT(DISTINCT c.subject_patient_id) as patient_count,
    pd.state,
    pd.county,
    CASE 
      WHEN pd.current_age < 18 THEN 'Pediatric'
      WHEN pd.current_age BETWEEN 18 AND 64 THEN 'Adult'
      ELSE 'Senior'
    END as age_group,
    pd.gender,
    pd.race,
    pd.ethnicity
  FROM {{ ref('condition') }} c
  INNER JOIN patient_demographics pd ON 
    CAST(JSON_EXTRACT_SCALAR(c.subject, '$.reference') AS INT) = pd.patient_id
  WHERE c.clinicalStatus_code = 'active'
  GROUP BY 1,2,3,4,5,6,7,8,9
),

chronic_disease_burden AS (
  SELECT 
    pd.state,
    pd.county,
    pd.age_group,
    pd.gender,
    COUNT(DISTINCT pd.patient_id) as total_patients,
    COUNT(DISTINCT CASE 
      WHEN cp.condition_code IN (
        '73211009',  -- Diabetes mellitus
        '38341003',  -- Hypertension
        '53741008',  -- Coronary artery disease
        '195967001', -- Asthma
        '13645005'   -- COPD
      ) THEN pd.patient_id 
    END) as chronic_disease_patients,
    
    -- Calculate chronic disease prevalence rate
    ROUND(
      (COUNT(DISTINCT CASE 
        WHEN cp.condition_code IN (
          '73211009', '38341003', '53741008', '195967001', '13645005'
        ) THEN pd.patient_id 
      END) * 100.0 / COUNT(DISTINCT pd.patient_id)), 
      2
    ) as chronic_disease_rate
    
  FROM patient_demographics pd
  LEFT JOIN condition_prevalence cp ON pd.patient_id = cp.patient_id
  GROUP BY 1,2,3,4
)

-- Final aggregated metrics
SELECT
  'Population Health' as metric_category,
  CURRENT_DATE as measurement_period,
  state as geographic_region,
  county as sub_region,
  age_group,
  gender,
  
  -- Core population metrics
  total_patients,
  chronic_disease_patients, 
  chronic_disease_rate,
  
  -- Health equity metrics
  CASE 
    WHEN chronic_disease_rate > 
      (SELECT AVG(chronic_disease_rate) FROM chronic_disease_burden) 
    THEN 'Above Average Risk'
    ELSE 'Average/Below Risk'
  END as risk_category,
  
  -- Quality measures alignment with FHIR Quality Measures
  JSON_OBJECT(
    'measure_id', 'CMS-FHIR-001',
    'measure_name', 'Chronic Disease Prevalence',  
    'numerator', chronic_disease_patients,
    'denominator', total_patients,
    'rate', chronic_disease_rate,
    'reporting_period', CURRENT_DATE
  ) as quality_measure

FROM chronic_disease_burden
WHERE total_patients >= 10  -- Statistical significance threshold