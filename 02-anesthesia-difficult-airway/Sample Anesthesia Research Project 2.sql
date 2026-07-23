/****************************************************************************************
PROJECT:
    TIVA Cohort and Difficult-Airway Evaluation Pipeline

DESCRIPTION:
    This PostgreSQL pipeline identifies surgical cases consistent with total
    intravenous anesthesia (TIVA) and builds supporting datasets for evaluating
    airway management and difficult-airway risk factors.

    The TIVA cohort includes cases that:

        1. Have documented propofol administration.
        2. Do not have documented volatile anesthetic administration.

    The pipeline integrates:

        - Surgical and anesthesia encounters
        - Airway-device documentation
        - Patient demographics
        - Problem-list diagnoses
        - Medication administration records
        - Perioperative vital signs
        - Propofol administration and dose totals
        - BMI, height, and weight data

TECHNICAL SKILLS DEMONSTRATED:
    - PostgreSQL
    - Common table expressions
    - Clinical cohort construction
    - EXISTS and NOT EXISTS logic
    - Multi-encounter reconciliation
    - Medication administration analysis
    - Flowsheet data extraction
    - Airway-device documentation
    - Conditional aggregation
    - Temporal clinical-data matching
    - Data-quality validation

PORTFOLIO NOTES:
    - All database, schema, table, project, institution, and employee names
      have been generalized.
    - Patient identifiers are represented by de-identified patient_id values.
    - Proprietary medication, flowsheet, and airway measurement identifiers
      have been replaced with generic portfolio values.
    - No protected health information is included.
    - Source tables shown here represent generalized EHR data structures.
****************************************************************************************/


/*======================================================================================
  STEP 1: CREATE THE TIVA COHORT

  PURPOSE:
      Identify surgical cases with propofol administration and no documented
      volatile anesthetic use.

  METHOD:
      1. Link each surgical case to its anesthesia encounters.
      2. identify cases with volatile anesthetic documentation.
      3. Identify cases with propofol administration.
      4. Retain propofol cases that do not appear in the volatile-anesthetic set.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_cohort;

CREATE TABLE analytics.tiva_cohort AS

WITH anesthesia_encounters AS (

    SELECT
        cohort.patient_id,
        cohort.admission_encounter_id,
        cohort.surgery_encounter_id,
        cohort.case_id,
        cohort.log_id,
        cohort.scheduled_start_time,
        cohort.anesthesia_types,
        surgical_map.primary_anesthesia_encounter_id,
        surgical_map.secondary_anesthesia_encounter_id,
        encounter.inpatient_data_id

    FROM analytics.surgical_candidate_cohort AS cohort

    INNER JOIN clinical.surgical_encounter_map AS surgical_map
        ON surgical_map.surgery_encounter_id::text =
           cohort.surgery_encounter_id::text

    INNER JOIN clinical.encounters AS encounter
        ON encounter.encounter_id IN (
            surgical_map.primary_anesthesia_encounter_id,
            surgical_map.secondary_anesthesia_encounter_id
        )
),

volatile_anesthetic_cases AS (

    SELECT DISTINCT
        anesthesia.log_id

    FROM anesthesia_encounters AS anesthesia

    INNER JOIN clinical.flowsheet_records AS record
        ON anesthesia.inpatient_data_id = record.inpatient_data_id

    INNER JOIN clinical.flowsheet_measurements AS measurement
        ON record.flowsheet_document_id = measurement.flowsheet_document_id

    WHERE measurement.measure_id IN (
        'VOLATILE_AGENT_CONCENTRATION_1',
        'VOLATILE_AGENT_CONCENTRATION_2',
        'VOLATILE_AGENT_CONCENTRATION_3',
        'VOLATILE_AGENT_CONCENTRATION_4',
        'VOLATILE_AGENT_CONCENTRATION_5',
        'VOLATILE_AGENT_CONCENTRATION_6'
    )
      AND NULLIF(measurement.measure_value, '')::numeric > 0
),

propofol_cases AS (

    SELECT DISTINCT
        anesthesia.log_id

    FROM anesthesia_encounters AS anesthesia

    INNER JOIN clinical.medication_administration AS medication
        ON anesthesia.primary_anesthesia_encounter_id =
           medication.encounter_id

    WHERE medication.medication_name ILIKE '%PROPOFOL%'
      AND NULLIF(medication.administered_dose, '')::numeric > 0
)

SELECT DISTINCT
    anesthesia.patient_id,
    anesthesia.admission_encounter_id,
    anesthesia.surgery_encounter_id,
    anesthesia.case_id,
    anesthesia.log_id,
    anesthesia.scheduled_start_time,
    anesthesia.anesthesia_types,
    anesthesia.primary_anesthesia_encounter_id,
    anesthesia.secondary_anesthesia_encounter_id,
    anesthesia.inpatient_data_id

FROM anesthesia_encounters AS anesthesia

WHERE EXISTS (
    SELECT 1
    FROM propofol_cases AS propofol
    WHERE propofol.log_id = anesthesia.log_id
)

AND NOT EXISTS (
    SELECT 1
    FROM volatile_anesthetic_cases AS volatile_agent
    WHERE volatile_agent.log_id = anesthesia.log_id
);


/*======================================================================================
  STEP 2: CREATE THE FINAL CASE-LEVEL COHORT

  PURPOSE:
      Retain one distinct case-level record for each qualifying TIVA case.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_final_cohort;

CREATE TABLE analytics.tiva_final_cohort AS

SELECT DISTINCT
    patient_id,
    admission_encounter_id,
    surgery_encounter_id,
    case_id,
    log_id,
    scheduled_start_time,
    anesthesia_types,
    primary_anesthesia_encounter_id,
    secondary_anesthesia_encounter_id,
    inpatient_data_id

FROM analytics.tiva_cohort;


/*======================================================================================
  STEP 3: RETRIEVE AIRWAY-DEVICE DOCUMENTATION

  PURPOSE:
      Retrieve airway-device placement, removal, description, and documented
      properties for each qualifying TIVA case.

  DIFFICULT-AIRWAY APPLICATION:
      These records can support evaluation of airway-device selection, placement
      timing, removal timing, and documented airway characteristics.

  PORTFOLIO NOTE:
      Production airway flowsheet identifiers have been replaced with generic
      measure names.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_airway_devices;

CREATE TABLE analytics.tiva_airway_devices AS

WITH airway_measures AS (

    SELECT measure_id

    FROM (
        VALUES
            ('ENDOTRACHEAL_TUBE'),
            ('SUPRAGLOTTIC_AIRWAY'),
            ('ORAL_AIRWAY'),
            ('NASAL_AIRWAY')
    ) AS airway_lookup (measure_id)
)

SELECT DISTINCT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.case_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    airway.measure_id,
    airway.placement_datetime,
    airway.removal_datetime,
    airway.device_description,
    airway.device_properties

FROM analytics.tiva_final_cohort AS cohort

INNER JOIN clinical.airway_device_documentation AS airway
    ON airway.encounter_id =
       cohort.primary_anesthesia_encounter_id

INNER JOIN airway_measures AS selected_measure
    ON airway.measure_id = selected_measure.measure_id;


/*======================================================================================
  STEP 4: RETRIEVE PATIENT DEMOGRAPHICS

  PURPOSE:
      Create a case-linked demographic dataset for risk adjustment and cohort
      characterization.

  PRIVACY NOTE:
      Direct identifiers such as patient name, street address, full ZIP code,
      and identifiable provider names should not be included in a public
      portfolio dataset.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_demographics;

CREATE TABLE analytics.tiva_demographics AS

SELECT DISTINCT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    demographics.sex,
    demographics.gender_identity,
    demographics.birth_year,
    demographics.vital_status,
    demographics.marital_status,
    demographics.employment_status,
    demographics.race,
    demographics.ethnicity,
    demographics.preferred_language,
    demographics.interpreter_needed_flag,
    demographics.state,
    demographics.zip3,
    demographics.pediatric_gestational_age,
    demographics.veteran_status,
    demographics.advance_directive_flag,
    demographics.transplant_patient_flag,
    demographics.area_deprivation_index,
    demographics.rural_urban_commuting_area_code

FROM analytics.tiva_cohort AS cohort

INNER JOIN clinical.patient_demographics AS demographics
    ON cohort.patient_id = demographics.patient_id;


/*======================================================================================
  STEP 5: RETRIEVE PROBLEM-LIST DIAGNOSES

  PURPOSE:
      Retrieve chronic and historical conditions associated with the qualifying
      encounter.

  DIFFICULT-AIRWAY APPLICATION:
      Potential risk factors may include obesity, obstructive sleep apnea,
      cervical-spine disease, craniofacial abnormalities, prior difficult
      intubation, and other relevant conditions.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_problem_list;

CREATE TABLE analytics.tiva_problem_list AS

SELECT DISTINCT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    problem.problem_list_encounter_id,
    problem.diagnosis_id,
    problem.diagnosis_description,
    problem.diagnosis_code,
    problem.diagnosis_code_type,
    problem.diagnosis_code_description,
    problem.filter_date,
    problem.noted_date,
    problem.resolved_date,
    problem.entry_date,
    problem.chronic_condition_flag,
    problem.principal_problem_flag,
    problem.hospital_problem_flag

FROM analytics.tiva_cohort AS cohort

INNER JOIN clinical.problem_list AS problem
    ON cohort.admission_encounter_id::text =
       problem.problem_list_encounter_id::text;


/*======================================================================================
  STEP 6: COMBINE MEDICATIONS FROM ALL RELEVANT ENCOUNTERS

  PURPOSE:
      Retrieve medication administrations documented under the admission,
      surgery, and anesthesia encounters.

  METHOD:
      Convert the multiple encounter identifiers into one standardized encounter
      field before joining to medication-administration records.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_medication_administrations;

CREATE TABLE analytics.tiva_medication_administrations AS

WITH cohort_encounters AS (

    SELECT DISTINCT
        patient_id,
        admission_encounter_id,
        surgery_encounter_id,
        log_id,
        scheduled_start_time,
        admission_encounter_id::numeric AS medication_join_encounter_id,
        'Admission encounter' AS medication_encounter_type

    FROM analytics.tiva_cohort

    WHERE admission_encounter_id IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        patient_id,
        admission_encounter_id,
        surgery_encounter_id,
        log_id,
        scheduled_start_time,
        surgery_encounter_id::numeric AS medication_join_encounter_id,
        'Surgical encounter' AS medication_encounter_type

    FROM analytics.tiva_cohort

    WHERE surgery_encounter_id IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        patient_id,
        admission_encounter_id,
        surgery_encounter_id,
        log_id,
        scheduled_start_time,
        primary_anesthesia_encounter_id::numeric AS medication_join_encounter_id,
        'Primary anesthesia encounter' AS medication_encounter_type

    FROM analytics.tiva_cohort

    WHERE primary_anesthesia_encounter_id IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        patient_id,
        admission_encounter_id,
        surgery_encounter_id,
        log_id,
        scheduled_start_time,
        secondary_anesthesia_encounter_id::numeric AS medication_join_encounter_id,
        'Secondary anesthesia encounter' AS medication_encounter_type

    FROM analytics.tiva_cohort

    WHERE secondary_anesthesia_encounter_id IS NOT NULL
)

SELECT DISTINCT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    cohort.medication_encounter_type,
    medication.medication_order_id,
    medication.order_date,
    medication.medication_id,
    medication.medication_name,
    medication.instance_number,
    medication.administration_datetime,
    medication.administration_action,
    medication.administered_dose,
    medication.dose_unit,
    medication.route,
    medication.pharmaceutical_class,
    medication.pharmaceutical_subclass,
    medication.ingredient_rxcui,
    medication.ingredient_rxcui_name,
    medication.specific_rxcui,
    medication.specific_rxcui_type,
    medication.generic_product_identifier,
    medication.order_class,
    medication.ordering_mode,
    medication.order_status,
    medication.frequency,
    medication.ordered_dose,
    medication.ordered_dose_unit,
    medication.quantity,
    medication.part_of_mixture_flag,
    medication.mixture_ingredient_type,
    medication.parent_medication_id,
    medication.parent_medication_name,
    medication.authorizing_provider_type

FROM cohort_encounters AS cohort

INNER JOIN clinical.medication_administration AS medication
    ON medication.encounter_id =
       cohort.medication_join_encounter_id;


/*======================================================================================
  STEP 7: RETRIEVE PERIOPERATIVE VITAL SIGNS

  PURPOSE:
      Retrieve selected physiologic measurements associated with the anesthesia
      record.

  PORTFOLIO NOTE:
      Proprietary flowsheet identifiers have been replaced by generic names.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_vital_signs;

CREATE TABLE analytics.tiva_vital_signs AS

WITH selected_vital_measures AS (

    SELECT measure_id

    FROM (
        VALUES
            ('HEART_RATE'),
            ('RESPIRATORY_RATE'),
            ('OXYGEN_SATURATION'),
            ('SYSTOLIC_BLOOD_PRESSURE'),
            ('DIASTOLIC_BLOOD_PRESSURE'),
            ('MEAN_ARTERIAL_PRESSURE'),
            ('TEMPERATURE')
    ) AS vital_lookup (measure_id)
)

SELECT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,

    CASE
        WHEN encounter.encounter_id::text =
             cohort.admission_encounter_id::text
            THEN 'Admission encounter'

        WHEN encounter.encounter_id::text =
             cohort.surgery_encounter_id::text
            THEN 'Surgical encounter'

        WHEN encounter.encounter_id::text =
             cohort.primary_anesthesia_encounter_id::text
            THEN 'Primary anesthesia encounter'

        WHEN encounter.encounter_id::text =
             cohort.secondary_anesthesia_encounter_id::text
            THEN 'Secondary anesthesia encounter'
    END AS source_encounter_type,

    measurement.measure_value,
    measurement.recorded_datetime,
    measurement.measure_id,
    measure_reference.measure_name

FROM analytics.tiva_cohort AS cohort

INNER JOIN clinical.flowsheet_records AS record
    ON record.inpatient_data_id = cohort.inpatient_data_id

INNER JOIN clinical.encounters AS encounter
    ON encounter.inpatient_data_id = record.inpatient_data_id

INNER JOIN clinical.flowsheet_measurements AS measurement
    ON measurement.flowsheet_document_id =
       record.flowsheet_document_id

INNER JOIN selected_vital_measures AS selected_measure
    ON measurement.measure_id = selected_measure.measure_id

LEFT JOIN reference.flowsheet_measures AS measure_reference
    ON measurement.measure_id = measure_reference.measure_id;


/*======================================================================================
  STEP 8: RETRIEVE PROPOFOL ADMINISTRATIONS

  PURPOSE:
      Create a focused medication dataset containing propofol administration
      records for each TIVA case.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_propofol_administrations;

CREATE TABLE analytics.tiva_propofol_administrations AS

SELECT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    cohort.primary_anesthesia_encounter_id,
    medication.medication_name,
    medication.medication_id,
    medication.administration_datetime,
    medication.administration_action,
    NULLIF(medication.administered_dose, '')::numeric AS administered_dose,
    medication.dose_unit,
    medication.route

FROM analytics.tiva_cohort AS cohort

INNER JOIN clinical.medication_administration AS medication
    ON cohort.primary_anesthesia_encounter_id =
       medication.encounter_id

WHERE medication.medication_name ILIKE '%PROPOFOL%'
  AND NULLIF(medication.administered_dose, '')::numeric > 0;


/*======================================================================================
  STEP 9: CALCULATE PROPOFOL TOTALS BY FORMULATION

  PURPOSE:
      Aggregate administered propofol doses by medication formulation.

  PORTFOLIO NOTE:
      Production medication identifiers have been replaced with generic
      formulation identifiers.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_propofol_dose_summary;

CREATE TABLE analytics.tiva_propofol_dose_summary AS

SELECT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    cohort.primary_anesthesia_encounter_id,

    SUM(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_500MG_50ML'
                THEN NULLIF(medication.administered_dose, '')::numeric
            ELSE 0
        END
    ) AS propofol_500mg_50ml_total_dose,

    MAX(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_500MG_50ML'
                THEN medication.dose_unit
        END
    ) AS propofol_500mg_50ml_dose_unit,

    SUM(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_200MG_20ML'
                THEN NULLIF(medication.administered_dose, '')::numeric
            ELSE 0
        END
    ) AS propofol_200mg_20ml_total_dose,

    MAX(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_200MG_20ML'
                THEN medication.dose_unit
        END
    ) AS propofol_200mg_20ml_dose_unit,

    SUM(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_INFUSION_BOLUS'
                THEN NULLIF(medication.administered_dose, '')::numeric
            ELSE 0
        END
    ) AS propofol_infusion_bolus_total_dose,

    MAX(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_INFUSION_BOLUS'
                THEN medication.dose_unit
        END
    ) AS propofol_infusion_bolus_dose_unit,

    SUM(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_1000MG_100ML'
                THEN NULLIF(medication.administered_dose, '')::numeric
            ELSE 0
        END
    ) AS propofol_1000mg_100ml_total_dose,

    MAX(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_1000MG_100ML'
                THEN medication.dose_unit
        END
    ) AS propofol_1000mg_100ml_dose_unit,

    SUM(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_10MG_ML'
                THEN NULLIF(medication.administered_dose, '')::numeric
            ELSE 0
        END
    ) AS propofol_10mg_ml_total_dose,

    MAX(
        CASE
            WHEN medication.medication_id = 'PROPOFOL_10MG_ML'
                THEN medication.dose_unit
        END
    ) AS propofol_10mg_ml_dose_unit

FROM analytics.tiva_cohort AS cohort

INNER JOIN clinical.medication_administration AS medication
    ON cohort.primary_anesthesia_encounter_id =
       medication.encounter_id

WHERE medication.medication_name ILIKE '%PROPOFOL%'
  AND NULLIF(medication.administered_dose, '')::numeric > 0

GROUP BY
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    cohort.primary_anesthesia_encounter_id;


/*======================================================================================
  STEP 10: RETRIEVE BMI, HEIGHT, WEIGHT, AND RELATED MEASUREMENTS

  PURPOSE:
      Retrieve structured body measurements and preoperative screening variables
      that may contribute to airway-risk evaluation.

  DIFFICULT-AIRWAY APPLICATION:
      BMI, weight, height, and STOP-BANG scores may be useful predictors or
      covariates in an airway-risk model.

  IMPORTANT:
      The source query supplied for this section ended immediately after the
      WHERE keyword. The remaining production inclusion criteria were therefore
      unavailable. The portfolio version below uses a clearly stated and
      defensible perioperative time window rather than pretending to reproduce
      missing logic.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_body_measurements;

CREATE TABLE analytics.tiva_body_measurements AS

SELECT DISTINCT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    vital.encounter_id AS measurement_encounter_id,
    vital.measurement_date,
    vital.height,
    vital.weight,
    vital.bmi,
    vital.diastolic_blood_pressure,
    vital.systolic_blood_pressure,
    vital.pulse,
    vital.temperature,
    vital.respiratory_rate,
    vital.stop_bang_score

FROM analytics.tiva_cohort AS cohort

INNER JOIN clinical.patient_vitals AS vital
    ON cohort.patient_id = vital.patient_id

WHERE vital.measurement_date
      BETWEEN cohort.scheduled_start_time::timestamp - INTERVAL '48 hours'
          AND cohort.scheduled_start_time::timestamp;


/*======================================================================================
  STEP 11: SUPPLEMENT MISSING BMI OR WEIGHT FROM FLOWSHEETS

  PURPOSE:
      Retrieve recent height, weight, and BMI measurements for patients whose
      structured vital-sign record does not contain a BMI.

  CORRECTION:
      Parentheses are used so the measure and date restrictions apply to every
      patient with missing BMI data.
======================================================================================*/

DROP TABLE IF EXISTS analytics.tiva_missing_body_measurements;

CREATE TABLE analytics.tiva_missing_body_measurements AS

WITH patients_with_body_measurements AS (

    SELECT DISTINCT
        patient_id,
        bmi

    FROM analytics.tiva_body_measurements
),

selected_body_measures AS (

    SELECT measure_id

    FROM (
        VALUES
            ('BODY_MASS_INDEX'),
            ('ADMISSION_WEIGHT'),
            ('CURRENT_WEIGHT'),
            ('DOSING_WEIGHT'),
            ('IDEAL_BODY_WEIGHT'),
            ('HEIGHT'),
            ('ESTIMATED_HEIGHT'),
            ('ESTIMATED_WEIGHT')
    ) AS body_measure_lookup (measure_id)
)

SELECT DISTINCT
    cohort.patient_id,
    cohort.admission_encounter_id,
    cohort.surgery_encounter_id,
    cohort.log_id,
    cohort.scheduled_start_time,
    measurement.measure_value,
    measurement.recorded_datetime,
    measurement.measure_id,
    measure_reference.measure_name

FROM analytics.tiva_cohort AS cohort

LEFT JOIN patients_with_body_measurements AS body_measure
    ON body_measure.patient_id = cohort.patient_id

INNER JOIN clinical.flowsheet_records AS record
    ON record.patient_id = cohort.patient_id

INNER JOIN clinical.flowsheet_measurements AS measurement
    ON measurement.flowsheet_document_id =
       record.flowsheet_document_id

INNER JOIN selected_body_measures AS selected_measure
    ON measurement.measure_id = selected_measure.measure_id

LEFT JOIN reference.flowsheet_measures AS measure_reference
    ON measurement.measure_id = measure_reference.measure_id

WHERE (
        body_measure.patient_id IS NULL
        OR body_measure.bmi IS NULL
      )

  AND measurement.recorded_datetime
      BETWEEN cohort.scheduled_start_time::timestamp - INTERVAL '48 hours'
          AND cohort.scheduled_start_time::timestamp

ORDER BY
    cohort.patient_id,
    measure_reference.measure_name,
    measurement.recorded_datetime;


/*======================================================================================
  STEP 12: PIPELINE QUALITY-ASSURANCE SUMMARY

  PURPOSE:
      Return table-level counts that can be compared across refreshes to identify
      unexpected changes in source volume or cohort logic.
======================================================================================*/

SELECT
    'TIVA cohort' AS dataset,
    COUNT(*) AS record_count,
    COUNT(DISTINCT log_id) AS distinct_case_count
FROM analytics.tiva_cohort

UNION ALL

SELECT
    'Airway-device documentation',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_airway_devices

UNION ALL

SELECT
    'Patient demographics',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_demographics

UNION ALL

SELECT
    'Problem-list diagnoses',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_problem_list

UNION ALL

SELECT
    'Medication administrations',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_medication_administrations

UNION ALL

SELECT
    'Vital signs',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_vital_signs

UNION ALL

SELECT
    'Propofol administrations',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_propofol_administrations

UNION ALL

SELECT
    'Propofol dose summaries',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_propofol_dose_summary

UNION ALL

SELECT
    'Body measurements',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_body_measurements

UNION ALL

SELECT
    'Supplemental body measurements',
    COUNT(*),
    COUNT(DISTINCT log_id)
FROM analytics.tiva_missing_body_measurements

ORDER BY dataset;


/****************************************************************************************
END OF PIPELINE
****************************************************************************************/