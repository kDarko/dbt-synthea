{% macro fhir_codeable_concept(concept_id_col, concept_code_col, concept_name_col, vocabulary_id_col, source_value_col=None) %}
{#
  Generates a FHIR CodeableConcept JSON structure from OMOP concept fields
  
  Args:
    concept_id_col: Column containing OMOP concept_id
    concept_code_col: Column containing concept_code 
    concept_name_col: Column containing concept_name
    vocabulary_id_col: Column containing vocabulary_id
    source_value_col: Optional source value for text field
#}

JSON_OBJECT(
  'coding', JSON_ARRAY(
    JSON_OBJECT(
      'system', CASE {{ vocabulary_id_col }}
        WHEN 'SNOMED' THEN 'http://snomed.info/sct'
        WHEN 'ICD10CM' THEN 'http://hl7.org/fhir/sid/icd-10-cm' 
        WHEN 'ICD9CM' THEN 'http://hl7.org/fhir/sid/icd-9-cm'
        WHEN 'RxNorm' THEN 'http://www.nlm.nih.gov/research/umls/rxnorm'
        WHEN 'LOINC' THEN 'http://loinc.org'
        WHEN 'CPT4' THEN 'http://www.ama-assn.org/go/cpt'
        WHEN 'UCUM' THEN 'http://unitsofmeasure.org'
        ELSE 'http://terminology.hl7.org/CodeSystem/omop-vocabulary'
      END,
      'code', {{ concept_code_col }},
      'display', {{ concept_name_col }}
    )
  )
  {% if source_value_col %}
  , 'text', {{ source_value_col }}
  {% endif %}
)

{% endmacro %}