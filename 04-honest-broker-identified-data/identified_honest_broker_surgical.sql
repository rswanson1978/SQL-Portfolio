/****************************************************************************************
PROJECT:
    Identified Honest Broker Surgical Dataset

DESCRIPTION:
    This PostgreSQL pipeline creates a reusable case-level surgical dataset for
    governed, identified clinical research access.

    The build integrates:

        - Surgical case metadata
        - Admission and operating-room encounters
        - Procedures
        - Surgical staff
        - Anesthesia staff
        - Perioperative case times
        - Anesthesia events
        - ASA classification
        - Mallampati score
        - PONV risk score
        - Emergent case status
        - Cardiopulmonary bypass events

TECHNICAL SKILLS DEMONSTRATED:
    - PostgreSQL
    - Conditional aggregation with FILTER
    - ARRAY_AGG and STRING_AGG
    - SmartData Element normalization
    - Temporary-table preprocessing
    - Clinical event rollups
    - Multi-encounter reconciliation
    - Indexing and query optimization
    - Reusable research data modeling

PORTFOLIO NOTES:
    - All schemas, identifiers, institution names, and proprietary codes have
      been generalized.
    - No protected health information is included.
****************************************************************************************/


/*======================================================================================
  STEP 1: ROLL UP SURGICAL CASE TIMES

  PURPOSE:
      Convert repeated surgical tracking events into one case-level row.
======================================================================================*/

DROP TABLE IF EXISTS temp_case_time_rollup;

CREATE TEMP TABLE temp_case_time_rollup AS

SELECT
    case_time.surgical_log_id,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'In Room'
        ) AS in_room_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Out of Room'
        ) AS out_of_room_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Anesthesia Start'
        ) AS anesthesia_start_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Induction'
        ) AS induction_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Anesthesia Intubation'
        ) AS intubation_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Anesthesia Finish'
        ) AS anesthesia_finish_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Incision Open'
        ) AS incision_open_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Incision Closed'
        ) AS incision_close_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Procedure Start'
        ) AS procedure_start_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Procedure Finish'
        ) AS procedure_finish_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'In Recovery'
        ) AS pacu_arrival_datetime,

    MIN(case_time.tracking_datetime)
        FILTER (
            WHERE event_reference.event_name = 'Out of Recovery'
        ) AS pacu_departure_datetime

FROM source_ehr.surgical_case_times AS case_time

LEFT JOIN reference.surgical_tracking_events AS event_reference
    ON case_time.tracking_event_code =
       event_reference.tracking_event_code

GROUP BY
    case_time.surgical_log_id;

CREATE INDEX ON temp_case_time_rollup (surgical_log_id);

ANALYZE temp_case_time_rollup;


/*======================================================================================
  STEP 2: ROLL UP ANESTHESIA EVENTS
======================================================================================*/

DROP TABLE IF EXISTS temp_anesthesia_event_rollup;

CREATE TEMP TABLE temp_anesthesia_event_rollup AS

WITH anesthesia_events AS (

    SELECT
        patient_event.patient_id,
        patient_event.anesthesia_encounter_id,
        event.event_type,
        event.event_datetime

    FROM source_ehr.anesthesia_events AS event

    INNER JOIN source_ehr.anesthesia_event_patients AS patient_event
        ON event.event_id = patient_event.event_id

    WHERE event.event_type IN (
        'EXTUBATION',
        'EMERGENCE',
        'INDUCTION',
        'INTUBATION',
        'AORTIC_CLAMP_ON',
        'AORTIC_CLAMP_OFF',
        'BYPASS_START',
        'BYPASS_END'
    )
)

SELECT
    patient_id,
    anesthesia_encounter_id,

    MIN(event_datetime)
        FILTER (WHERE event_type = 'EXTUBATION')
        AS extubation_datetime,

    MIN(event_datetime)
        FILTER (WHERE event_type = 'EMERGENCE')
        AS emergence_datetime,

    MIN(event_datetime)
        FILTER (WHERE event_type = 'INDUCTION')
        AS induction_datetime,

    MIN(event_datetime)
        FILTER (WHERE event_type = 'INTUBATION')
        AS intubation_datetime,

    MIN(event_datetime)
        FILTER (WHERE event_type = 'AORTIC_CLAMP_ON')
        AS aortic_clamp_on_datetime,

    MIN(event_datetime)
        FILTER (WHERE event_type = 'AORTIC_CLAMP_OFF')
        AS aortic_clamp_off_datetime,

    MIN(event_datetime)
        FILTER (WHERE event_type = 'BYPASS_START')
        AS bypass_start_datetime,

    MIN(event_datetime)
        FILTER (WHERE event_type = 'BYPASS_END')
        AS bypass_end_datetime

FROM anesthesia_events

GROUP BY
    patient_id,
    anesthesia_encounter_id;

CREATE INDEX ON temp_anesthesia_event_rollup (anesthesia_encounter_id);

ANALYZE temp_anesthesia_event_rollup;


/*======================================================================================
  STEP 3: NORMALIZE PREOPERATIVE ASSESSMENTS
======================================================================================*/

DROP TABLE IF EXISTS temp_preoperative_assessments;

CREATE TEMP TABLE temp_preoperative_assessments AS

WITH assessment_values AS (

    SELECT
        element.record_id::text AS anesthesia_record_id,
        element.element_name,
        value.element_value

    FROM source_ehr.smartdata_elements AS element

    INNER JOIN source_ehr.smartdata_values AS value
        ON element.value_link_id = value.value_link_id

    WHERE element.element_name IN (
        'MALLAMPATI_SCORE',
        'ASA_CLASSIFICATION',
        'EMERGENT_CASE',
        'ANESTHESIA_TYPE',
        'PONV_SCORE'
    )
)

SELECT
    anesthesia_record_id,

    MAX(
        CASE
            WHEN element_name = 'MALLAMPATI_SCORE'
            THEN CASE
                WHEN element_value ~ '^IV'  THEN 'IV'
                WHEN element_value ~ '^III' THEN 'III'
                WHEN element_value ~ '^II'  THEN 'II'
                WHEN element_value ~ '^I'   THEN 'I'
                ELSE element_value
            END
        END
    ) AS mallampati_score,

    MAX(
        CASE
            WHEN element_name = 'ASA_CLASSIFICATION'
            THEN element_value
        END
    ) AS asa_classification_code,

    MAX(
        CASE
            WHEN element_name = 'EMERGENT_CASE'
             AND element_value = '1'
            THEN 'Emergent'
        END
    ) AS emergent_case_flag,

    MAX(
        CASE
            WHEN element_name = 'ANESTHESIA_TYPE'
            THEN element_value
        END
    ) AS documented_anesthesia_type,

    MAX(
        CASE
            WHEN element_name = 'PONV_SCORE'
            THEN element_value
        END
    ) AS ponv_score

FROM assessment_values

GROUP BY
    anesthesia_record_id;

CREATE INDEX ON temp_preoperative_assessments (anesthesia_record_id);

ANALYZE temp_preoperative_assessments;


/*======================================================================================
  STEP 4: AGGREGATE PROCEDURES

  PURPOSE:
      Preserve all procedures associated with a surgical log while maintaining
      their source ordering.
======================================================================================*/

DROP TABLE IF EXISTS temp_procedure_rollup;

CREATE TEMP TABLE temp_procedure_rollup AS

SELECT
    procedure.surgical_log_id,

    ARRAY_AGG(
        procedure.procedure_id
        ORDER BY procedure.procedure_id
    ) AS procedure_ids,

    ARRAY_AGG(
        procedure_reference.procedure_name
        ORDER BY procedure.procedure_id
    ) AS procedure_names,

    ARRAY_AGG(
        procedure.procedure_display_name
        ORDER BY procedure.procedure_id, procedure.line_number
    ) AS procedure_display_names,

    ARRAY_AGG(
        anesthesia_reference.anesthesia_type_name
        ORDER BY procedure.procedure_id
    ) FILTER (
        WHERE anesthesia_reference.anesthesia_type_name IS NOT NULL
    ) AS anesthesia_types

FROM source_ehr.surgical_log_procedures AS procedure

INNER JOIN reference.surgical_procedures AS procedure_reference
    ON procedure.procedure_id =
       procedure_reference.procedure_id

LEFT JOIN reference.anesthesia_types AS anesthesia_reference
    ON procedure.anesthesia_type_code =
       anesthesia_reference.anesthesia_type_code

GROUP BY
    procedure.surgical_log_id;

CREATE INDEX ON temp_procedure_rollup (surgical_log_id);

ANALYZE temp_procedure_rollup;


/*======================================================================================
  STEP 5: AGGREGATE SURGEON STAFFING
======================================================================================*/

DROP TABLE IF EXISTS temp_surgeon_rollup;

CREATE TEMP TABLE temp_surgeon_rollup AS

SELECT
    surgical_staff.surgical_log_id,

    ARRAY_AGG(
        provider.provider_name
        ORDER BY surgical_staff.line_number
    ) FILTER (
        WHERE role.role_name = 'Primary'
    ) AS primary_surgeons,

    ARRAY_AGG(
        provider.provider_name
        ORDER BY surgical_staff.line_number
    ) FILTER (
        WHERE role.role_name ILIKE '%Resident%'
    ) AS surgical_residents,

    ARRAY_AGG(
        provider.provider_name
        ORDER BY surgical_staff.line_number
    ) FILTER (
        WHERE role.role_name = 'Fellow'
    ) AS surgical_fellows,

    ARRAY_AGG(
        provider.provider_name
        ORDER BY role.role_name, surgical_staff.line_number
    ) AS all_surgeons,

    ARRAY_AGG(
        provider.provider_id
        ORDER BY role.role_name, surgical_staff.line_number
    ) AS all_surgeon_provider_ids,

    ARRAY_AGG(
        role.role_name
        ORDER BY role.role_name, surgical_staff.line_number
    ) AS all_surgeon_roles,

    STRING_AGG(
        provider.provider_name,
        '; '
        ORDER BY surgical_staff.line_number
    ) FILTER (
        WHERE role.role_name = 'Primary'
    ) AS primary_surgeons_display

FROM source_ehr.surgical_case_staff AS surgical_staff

LEFT JOIN reference.surgical_staff_roles AS role
    ON surgical_staff.role_code = role.role_code

LEFT JOIN reference.providers AS provider
    ON surgical_staff.provider_id = provider.provider_id

GROUP BY
    surgical_staff.surgical_log_id;

CREATE INDEX ON temp_surgeon_rollup (surgical_log_id);

ANALYZE temp_surgeon_rollup;


/*======================================================================================
  STEP 6: AGGREGATE ANESTHESIA STAFFING
======================================================================================*/

DROP TABLE IF EXISTS temp_anesthesia_staff_rollup;

CREATE TEMP TABLE temp_anesthesia_staff_rollup AS

SELECT
    anesthesia_staff.surgical_case_id,

    ARRAY_AGG(
        provider.provider_name
        ORDER BY anesthesia_staff.line_number
    ) FILTER (
        WHERE role.role_name = 'Anesthesiologist'
          AND provider.provider_id IS NOT NULL
    ) AS anesthesiologists,

    ARRAY_AGG(
        provider.provider_name
        ORDER BY anesthesia_staff.line_number
    ) FILTER (
        WHERE role.role_name ILIKE '%Resident%'
          AND provider.provider_id IS NOT NULL
    ) AS anesthesia_residents,

    ARRAY_AGG(
        provider.provider_name
        ORDER BY anesthesia_staff.line_number
    ) FILTER (
        WHERE role.role_name = 'CRNA'
          AND provider.provider_id IS NOT NULL
    ) AS crnas,

    ARRAY_AGG(
        provider.provider_name
        ORDER BY role.role_name, anesthesia_staff.line_number
    ) AS all_anesthesia_staff,

    ARRAY_AGG(
        provider.provider_id
        ORDER BY role.role_name, anesthesia_staff.line_number
    ) AS all_anesthesia_provider_ids,

    ARRAY_AGG(
        role.role_name
        ORDER BY role.role_name, anesthesia_staff.line_number
    ) AS all_anesthesia_staff_roles,

    STRING_AGG(
        provider.provider_name,
        '; '
        ORDER BY anesthesia_staff.line_number
    ) FILTER (
        WHERE role.role_name = 'Anesthesiologist'
    ) AS anesthesiologists_display

FROM source_ehr.anesthesia_case_staff AS anesthesia_staff

LEFT JOIN reference.anesthesia_staff_roles AS role
    ON anesthesia_staff.staff_role_code =
       role.staff_role_code

LEFT JOIN reference.providers AS provider
    ON anesthesia_staff.provider_id =
       provider.provider_id

GROUP BY
    anesthesia_staff.surgical_case_id;

CREATE INDEX ON temp_anesthesia_staff_rollup (surgical_case_id);

ANALYZE temp_anesthesia_staff_rollup;


/*======================================================================================
  STEP 7: BUILD THE IDENTIFIED SURGICAL DATASET
======================================================================================*/

DROP TABLE IF EXISTS research_access.identified_surgical_cases;

CREATE TABLE research_access.identified_surgical_cases AS

SELECT
    crosswalk.research_patient_number,
    crosswalk.medical_record_number AS patient_identifier,

    encounter_crosswalk.main_encounter_number,
    encounter_crosswalk.surgical_encounter_number,

    surgical_case.surgical_case_id,
    surgical_case.surgical_log_id,
    surgical_case.scheduled_start_datetime,
    schedule_history.original_scheduled_datetime,

    surgical_case.postoperative_destination_code,
    destination.postoperative_destination_name,

    surgical_case.service_code,
    service.surgical_service_name,

    surgical_case.case_class_code,
    case_class.case_class_name,

    surgical_case.location_id,
    location.location_name,

    surgical_case.operating_room_id,
    operating_room.operating_room_name,

    COALESCE(
        surgical_case.asa_classification_code,
        assessment.asa_classification_code
    ) AS asa_classification_code,

    asa_reference.asa_classification_name,

    CASE
        WHEN surgical_case.log_type_code = '0'
            THEN 'Surgical Log'
        WHEN surgical_case.log_type_code = '1'
            THEN 'Procedure Log'
        ELSE NULL
    END AS surgical_log_type,

    surgical_case.status_code,
    status_reference.status_name AS operating_room_status,

    procedure_rollup.procedure_ids,
    procedure_rollup.procedure_names,
    procedure_rollup.procedure_display_names,

    COALESCE(
        assessment.emergent_case_flag,
        surgical_case.emergent_case_flag
    ) AS emergent_case_flag,

    COALESCE(
        assessment.documented_anesthesia_type,
        procedure_rollup.anesthesia_types::text
    ) AS anesthesia_types,

    assessment.mallampati_score,
    assessment.ponv_score,

    case_time.in_room_datetime,
    case_time.out_of_room_datetime,
    case_time.anesthesia_start_datetime,

    COALESCE(
        case_time.induction_datetime,
        anesthesia_event.induction_datetime
    ) AS induction_datetime,

    COALESCE(
        case_time.intubation_datetime,
        anesthesia_event.intubation_datetime
    ) AS intubation_datetime,

    anesthesia_event.emergence_datetime,
    anesthesia_event.extubation_datetime,
    case_time.anesthesia_finish_datetime,
    case_time.incision_open_datetime,
    case_time.incision_close_datetime,
    case_time.procedure_start_datetime,
    case_time.procedure_finish_datetime,
    case_time.pacu_arrival_datetime,
    case_time.pacu_departure_datetime,

    anesthesia_event.aortic_clamp_on_datetime,
    anesthesia_event.aortic_clamp_off_datetime,
    anesthesia_event.bypass_start_datetime,
    anesthesia_event.bypass_end_datetime,

    surgeon_rollup.primary_surgeons,
    surgeon_rollup.surgical_residents,
    surgeon_rollup.surgical_fellows,
    surgeon_rollup.all_surgeons,
    surgeon_rollup.all_surgeon_provider_ids,
    surgeon_rollup.all_surgeon_roles,
    surgeon_rollup.primary_surgeons_display,

    anesthesia_staff.anesthesiologists,
    anesthesia_staff.anesthesia_residents,
    anesthesia_staff.crnas,
    anesthesia_staff.all_anesthesia_staff,
    anesthesia_staff.all_anesthesia_provider_ids,
    anesthesia_staff.all_anesthesia_staff_roles,
    anesthesia_staff.anesthesiologists_display

FROM source_ehr.surgical_cases AS surgical_case

INNER JOIN research_build.patient_crosswalk AS crosswalk
    ON surgical_case.patient_id = crosswalk.patient_id

INNER JOIN research_build.encounter_crosswalk AS encounter_crosswalk
    ON surgical_case.surgical_encounter_id =
       encounter_crosswalk.source_surgical_encounter_id

LEFT JOIN temp_case_time_rollup AS case_time
    ON surgical_case.surgical_log_id =
       case_time.surgical_log_id

LEFT JOIN temp_anesthesia_event_rollup AS anesthesia_event
    ON surgical_case.anesthesia_encounter_id =
       anesthesia_event.anesthesia_encounter_id

LEFT JOIN temp_preoperative_assessments AS assessment
    ON surgical_case.anesthesia_record_id =
       assessment.anesthesia_record_id

LEFT JOIN temp_procedure_rollup AS procedure_rollup
    ON surgical_case.surgical_log_id =
       procedure_rollup.surgical_log_id

LEFT JOIN temp_surgeon_rollup AS surgeon_rollup
    ON surgical_case.surgical_log_id =
       surgeon_rollup.surgical_log_id

LEFT JOIN temp_anesthesia_staff_rollup AS anesthesia_staff
    ON surgical_case.surgical_case_id =
       anesthesia_staff.surgical_case_id

LEFT JOIN source_ehr.surgical_schedule_history AS schedule_history
    ON surgical_case.surgical_case_id =
       schedule_history.surgical_case_id
   AND schedule_history.sequence_number = 1

LEFT JOIN reference.postoperative_destinations AS destination
    ON surgical_case.postoperative_destination_code =
       destination.postoperative_destination_code

LEFT JOIN reference.surgical_services AS service
    ON surgical_case.service_code =
       service.service_code

LEFT JOIN reference.surgical_case_classes AS case_class
    ON surgical_case.case_class_code =
       case_class.case_class_code

LEFT JOIN reference.locations AS location
    ON surgical_case.location_id =
       location.location_id

LEFT JOIN reference.operating_rooms AS operating_room
    ON surgical_case.operating_room_id =
       operating_room.operating_room_id

LEFT JOIN reference.asa_classifications AS asa_reference
    ON COALESCE(
        surgical_case.asa_classification_code,
        assessment.asa_classification_code
    ) = asa_reference.asa_classification_code

LEFT JOIN reference.surgical_status AS status_reference
    ON surgical_case.status_code =
       status_reference.status_code

WHERE surgical_case.status_code IS DISTINCT FROM 'VOIDED';


CREATE INDEX
    ON research_access.identified_surgical_cases (research_patient_number);

CREATE INDEX
    ON research_access.identified_surgical_cases (surgical_log_id);

CREATE INDEX
    ON research_access.identified_surgical_cases (surgical_encounter_number);

ANALYZE research_access.identified_surgical_cases;