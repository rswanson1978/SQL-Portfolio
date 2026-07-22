/****************************************************************************************
PROJECT:
    Preoperative Clinical Data Integration Pipeline

DESCRIPTION:
    This PostgreSQL pipeline creates a longitudinal research dataset for patients
    evaluated during a preoperative consultation. It integrates multiple electronic
    health record domains, including:

        1. Preoperative encounters
        2. Encounter diagnoses
        3. Problem-list diagnoses
        4. Surgical cases
        5. Postoperative complications
        6. Delirium-related flowsheet assessments
        7. Consultation-related clinical notes

TECHNICAL SKILLS DEMONSTRATED:
    - PostgreSQL
    - Healthcare data modeling
    - ETL pipeline development
    - Temporal cohort construction
    - Multi-domain EHR integration
    - Clinical encounter matching
    - Date-range filtering
    - Reference-table joins
    - Structured and unstructured data integration

PORTFOLIO NOTES:
    - All organization, database, schema, table, project, and employee names
      have been generalized.
    - Patient identifiers are represented as de-identified patient_id values.
    - Internal department names, clinical identifiers, and flowsheet IDs have
      been replaced with generic examples.
    - No protected health information is included.
    - Individual output tables are retained because project requirements were
      received incrementally and each domain may need to be refreshed or
      modified independently.
****************************************************************************************/


/*======================================================================================
  STEP 1: IDENTIFY PREOPERATIVE ENCOUNTERS

  PURPOSE:
      Identify qualifying preoperative visits for patients in the study cohort.

  INCLUSION CRITERIA:
      - Patient appears in the study cohort.
      - Encounter occurred in the designated preoperative department.
      - Visit provider has the qualifying specialty.
      - Visit type is populated.
======================================================================================*/

DROP TABLE IF EXISTS analytics.preop_encounters;

CREATE TABLE analytics.preop_encounters AS

SELECT
    cohort.patient_id,
    encounter.encounter_id,
    encounter.encounter_type,
    encounter.source_encounter_type_code,
    encounter.source_encounter_type_name,
    encounter.age_at_visit_years,
    encounter.location_name,
    encounter.department_name,
    encounter.visit_type_name,
    encounter.visit_date,
    encounter.visit_provider_id,
    encounter.visit_provider_name,
    specialty.specialty_code

FROM analytics.study_cohort AS cohort

INNER JOIN clinical.encounters AS encounter
    ON cohort.patient_id = encounter.patient_id

INNER JOIN reference.provider_specialties AS specialty
    ON encounter.visit_provider_id = specialty.provider_id

WHERE encounter.department_name = 'PREOPERATIVE CLINIC'
  AND specialty.specialty_code = 'ANESTHESIOLOGY'
  AND encounter.visit_type_name IS NOT NULL
;


/*======================================================================================
  STEP 2: IDENTIFY ENCOUNTER DIAGNOSES

  PURPOSE:
      Retrieve diagnoses documented during the longitudinal period surrounding
      each qualifying preoperative visit.

  DATE WINDOW:
      Two years before through one year after the preoperative visit.

  NOTE:
      Diagnosis records are matched at the patient level because the goal is to
      capture diagnoses documented across multiple encounters within the defined
      clinical observation period.
======================================================================================*/

DROP TABLE IF EXISTS analytics.preop_diagnoses;

CREATE TABLE analytics.preop_diagnoses AS

SELECT
    preop.patient_id,
    preop.encounter_id AS preop_encounter_id,
    preop.visit_date AS preop_visit_date,
    diagnosis.encounter_id AS diagnosis_encounter_id,
    diagnosis.encounter_type,
    diagnosis.diagnosis_date,
    diagnosis.provider_id,
    diagnosis.provider_name,
    diagnosis.provider_title,
    diagnosis.diagnosis_name,
    diagnosis.diagnosis_code,
    diagnosis.diagnosis_type,
    diagnosis.diagnosis_source,
    diagnosis.diagnosis_origin,
    diagnosis.principal_diagnosis_flag,
    diagnosis.present_on_admission_flag,
    diagnosis.raw_principal_diagnosis_flag

FROM analytics.preop_encounters AS preop

INNER JOIN clinical.diagnoses AS diagnosis
    ON preop.patient_id = diagnosis.patient_id

WHERE diagnosis.diagnosis_date
      BETWEEN preop.visit_date - INTERVAL '2 years'
          AND preop.visit_date + INTERVAL '1 year'
;


/*======================================================================================
  STEP 3: IDENTIFY PROBLEM-LIST DIAGNOSES

  PURPOSE:
      Retrieve active and historical problem-list entries documented during the
      longitudinal period surrounding each preoperative visit.

  DATE WINDOW:
      Two years before through one year after the preoperative visit.
======================================================================================*/

DROP TABLE IF EXISTS analytics.preop_problem_list;

CREATE TABLE analytics.preop_problem_list AS

SELECT
    preop.patient_id,
    preop.encounter_id AS preop_encounter_id,
    preop.visit_date AS preop_visit_date,
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

FROM analytics.preop_encounters AS preop

INNER JOIN clinical.problem_list AS problem
    ON preop.patient_id = problem.patient_id

WHERE problem.entry_date
      BETWEEN preop.visit_date - INTERVAL '2 years'
          AND preop.visit_date + INTERVAL '1 year'
;


/*======================================================================================
  STEP 4: IDENTIFY SURGICAL CASES

  PURPOSE:
      Retrieve surgical and anesthesia case information occurring during the
      longitudinal period surrounding each qualifying preoperative visit.

  DATE WINDOW:
      Two years before through one year after the preoperative visit.
======================================================================================*/

DROP TABLE IF EXISTS analytics.preop_surgical_cases;

CREATE TABLE analytics.preop_surgical_cases AS

SELECT
    preop.patient_id,
    preop.encounter_id AS preop_encounter_id,
    preop.visit_date AS preop_visit_date,
    surgery.encounter_id AS surgical_encounter_id,
    surgery.surgery_encounter_id,
    surgery.case_id,
    surgery.log_id,
    surgery.scheduled_start_time,
    surgery.historical_scheduled_datetime,
    surgery.postoperative_destination_code,
    surgery.postoperative_destination,
    surgery.service_code,
    surgery.surgical_service,
    surgery.case_class_code,
    surgery.case_class,
    surgery.location_id,
    surgery.location_name,
    surgery.room_id,
    surgery.room_name,
    surgery.asa_rating_code,
    surgery.asa_rating,
    surgery.log_type,
    surgery.status_code,
    surgery.operating_room_status,
    surgery.procedure_ids,
    surgery.procedure_names,
    surgery.procedure_display_names,
    surgery.emergent_case_flag,
    surgery.anesthesia_types,
    surgery.mallampati_score,
    surgery.ponv_score,
    surgery.in_room_datetime,
    surgery.out_of_room_datetime,
    surgery.anesthesia_start_datetime,
    surgery.induction_datetime,
    surgery.intubation_datetime,
    surgery.emergence_datetime,
    surgery.extubation_datetime,
    surgery.anesthesia_finish_datetime,
    surgery.incision_open_datetime,
    surgery.incision_close_datetime,
    surgery.procedure_start_datetime,
    surgery.procedure_finish_datetime,
    surgery.pacu_arrival_datetime,
    surgery.pacu_departure_datetime,
    surgery.aortic_clamp_on_datetime,
    surgery.aortic_clamp_off_datetime,
    surgery.cardiopulmonary_bypass_start_datetime,
    surgery.cardiopulmonary_bypass_end_datetime,
    surgery.all_surgeon_roles,
    surgery.primary_surgeons,
    surgery.surgery_residents,
    surgery.surgery_fellows,
    surgery.all_surgeons,
    surgery.all_surgeon_provider_ids,
    surgery.all_anesthesia_staff_roles,
    surgery.anesthesiologists,
    surgery.anesthesia_residents,
    surgery.crnas,
    surgery.all_anesthesia_staff,
    surgery.all_anesthesia_provider_ids

FROM analytics.preop_encounters AS preop

INNER JOIN clinical.surgical_cases AS surgery
    ON preop.patient_id = surgery.patient_id

WHERE surgery.scheduled_start_time
      BETWEEN preop.visit_date - INTERVAL '2 years'
          AND preop.visit_date + INTERVAL '1 year'
;


/*======================================================================================
  STEP 5: IDENTIFY POSTOPERATIVE COMPLICATIONS

  PURPOSE:
      Retrieve postoperative complication and quality-tracking elements associated
      with the qualifying surgical cases.

  LINKAGE:
      Surgical cases are linked to complication records using the surgical log ID.

  REFERENCE TABLES:
      Reference tables translate stored category codes into readable descriptions.
======================================================================================*/

DROP TABLE IF EXISTS analytics.preop_postoperative_complications;

CREATE TABLE analytics.preop_postoperative_complications AS

SELECT
    surgery.patient_id,
    surgery.preop_encounter_id,
    surgery.preop_visit_date,
    surgery.log_id,
    complication.quality_element_code,
    quality_reference.quality_element_name,
    complication.priority_code,
    priority_reference.priority_name,
    complication.timing_code,
    timing_reference.timing_name,
    status_reference.status_name,
    complication.procedure_id,
    procedure_reference.procedure_name,
    complication.element_comment,
    complication.element_identified_date,
    complication.element_identified_time

FROM analytics.preop_surgical_cases AS surgery

INNER JOIN clinical.complication_tracking AS complication
    ON surgery.log_id = complication.log_id

LEFT JOIN reference.complication_priority AS priority_reference
    ON complication.priority_code = priority_reference.priority_code

LEFT JOIN reference.complication_timing AS timing_reference
    ON complication.timing_code = timing_reference.timing_code

LEFT JOIN reference.quality_elements AS quality_reference
    ON complication.quality_element_code =
       quality_reference.quality_element_code

LEFT JOIN reference.complication_status AS status_reference
    ON complication.status_code = status_reference.status_code

LEFT JOIN reference.procedures AS procedure_reference
    ON complication.procedure_id = procedure_reference.procedure_id
;


/*======================================================================================
  STEP 6: IDENTIFY DELIRIUM-RELATED FLOWSHEET OBSERVATIONS

  PURPOSE:
      Retrieve selected structured nursing assessments, including representative
      delirium-screening measures such as CAM and NuDESC.

  DATE WINDOW:
      Two years before through one year after the preoperative visit.

  PORTFOLIO NOTE:
      The measurement identifiers below are synthetic examples. Internal production
      flowsheet identifiers were intentionally excluded from the public repository.
======================================================================================*/

DROP TABLE IF EXISTS analytics.preop_delirium_assessments;

CREATE TABLE analytics.preop_delirium_assessments AS

WITH selected_flowsheet_measures AS (

    SELECT
        measure_id,
        assessment_group

    FROM (
        VALUES
            ('CAM_OVERALL_RESULT',       'CAM'),
            ('CAM_ACUTE_ONSET',          'CAM'),
            ('CAM_INATTENTION',          'CAM'),
            ('CAM_DISORGANIZED_THINKING','CAM'),
            ('CAM_ALTERED_CONSCIOUSNESS','CAM'),
            ('NUDESC_TOTAL_SCORE',       'NuDESC'),
            ('NUDESC_DISORIENTATION',    'NuDESC'),
            ('NUDESC_INAPPROPRIATE_BEHAVIOR', 'NuDESC'),
            ('NUDESC_INAPPROPRIATE_COMMUNICATION', 'NuDESC'),
            ('NUDESC_ILLUSIONS',         'NuDESC'),
            ('NUDESC_PSYCHOMOTOR_RETARDATION', 'NuDESC')
    ) AS measure_list (
        measure_id,
        assessment_group
    )
)

SELECT
    preop.patient_id,
    preop.encounter_id AS preop_encounter_id,
    preop.visit_date AS preop_visit_date,
    observation.encounter_id AS observation_encounter_id,
    observation.inpatient_data_id,
    observation.display_name,
    observation.flowsheet_document_id,
    observation.measure_id,
    measure.assessment_group,
    observation.recorded_datetime,
    observation.entry_datetime,
    observation.measurement_value,
    observation.measurement_comment

FROM analytics.preop_encounters AS preop

INNER JOIN clinical.flowsheet_observations AS observation
    ON preop.patient_id = observation.patient_id

INNER JOIN selected_flowsheet_measures AS measure
    ON observation.measure_id = measure.measure_id

WHERE observation.recorded_datetime
      BETWEEN preop.visit_date - INTERVAL '2 years'
          AND preop.visit_date + INTERVAL '1 year'
;


/*======================================================================================
  STEP 7: IDENTIFY CONSULTATION-RELATED CLINICAL NOTES

  PURPOSE:
      Retrieve clinical notes documented around the consultation date.

  DATE WINDOW:
      Seven days before through seven days after the consultation.

  OUTPUT:
      - Consultation date
      - Note metadata
      - Original note text
      - Cleaned or normalized note text

  PORTFOLIO NOTE:
      Clinical note text should contain only synthetic or de-identified content in
      any public demonstration dataset.
======================================================================================*/

DROP TABLE IF EXISTS analytics.consultation_notes;

CREATE TABLE analytics.consultation_notes AS

SELECT
    cohort.consultation_date,
    metadata.note_id,
    metadata.note_encounter_id,
    metadata.patient_id,
    metadata.note_type,
    metadata.note_status,
    metadata.note_date,
    metadata.note_author_id,
    metadata.note_author_role,
    original_text.combined_note_text AS original_note_text,
    cleaned_text.combined_note_text AS cleaned_note_text

FROM clinical.note_metadata AS metadata

LEFT JOIN clinical.note_text_original AS original_text
    ON original_text.note_id = metadata.note_id

LEFT JOIN analytics.note_text_cleaned AS cleaned_text
    ON cleaned_text.note_id = metadata.note_id

INNER JOIN analytics.consultation_cohort AS cohort
    ON cohort.patient_id = metadata.patient_id
   AND metadata.note_date
       BETWEEN cohort.consultation_date::date - INTERVAL '7 days'
           AND cohort.consultation_date::date + INTERVAL '7 days'
;


/*======================================================================================
  OPTIONAL QUALITY-ASSURANCE SUMMARY

  PURPOSE:
      Provide record counts after the pipeline completes. These counts can be used
      to identify unexpected changes in cohort or source-table volume.
======================================================================================*/

SELECT
    'Preoperative encounters' AS dataset,
    COUNT(*) AS record_count
FROM analytics.preop_encounters

UNION ALL

SELECT
    'Encounter diagnoses' AS dataset,
    COUNT(*) AS record_count
FROM analytics.preop_diagnoses

UNION ALL

SELECT
    'Problem-list diagnoses' AS dataset,
    COUNT(*) AS record_count
FROM analytics.preop_problem_list

UNION ALL

SELECT
    'Surgical cases' AS dataset,
    COUNT(*) AS record_count
FROM analytics.preop_surgical_cases

UNION ALL

SELECT
    'Postoperative complications' AS dataset,
    COUNT(*) AS record_count
FROM analytics.preop_postoperative_complications

UNION ALL

SELECT
    'Delirium assessments' AS dataset,
    COUNT(*) AS record_count
FROM analytics.preop_delirium_assessments

UNION ALL

SELECT
    'Consultation notes' AS dataset,
    COUNT(*) AS record_count
FROM analytics.consultation_notes

ORDER BY dataset
;


/****************************************************************************************
END OF PIPELINE
****************************************************************************************/