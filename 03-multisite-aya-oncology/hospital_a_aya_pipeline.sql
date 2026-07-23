/****************************************************************************************
PROJECT:
    Multi-Site AYA Oncology Data Harmonization — Hospital A Pipeline

PURPOSE:
    Build a one-row-per-patient adolescent and young adult oncology dataset for
    Hospital A. This site primarily identifies the cohort through cancer registry,
    cancer problem, and problem-list workflows, including a separate path for
    deceased patients.

PORTFOLIO SAFETY:
    - Organization, schema, employee, and infrastructure names are generalized.
    - Site-specific numeric identifiers are replaced with synthetic identifiers.
    - Patient keys are de-identified placeholders.
    - The workflow and SQL techniques remain structurally faithful to the source build.

HOSPITAL A WORKFLOW HIGHLIGHTS:
    - Cohort begins with cancer registry and cancer-problem records.
    - Deceased patients require a separate registry membership workflow.
    - Diagnosis and end-of-treatment data come from cancer problems, problem lists,
      and treatment-summary notes.
    - Supportive-care referrals are consolidated from procedure orders.
    - Additional services are identified through notes, SmartData Elements,
      appointment procedures, and provider-specific workflows.
    - Final output applies the shared reporting window and age-at-diagnosis criteria.
****************************************************************************************/

-- Converted to PostgreSQL from SQL Server syntax.
-- Notes:
--   * SQL Server #temp tables were converted to PostgreSQL TEMP tables.
--   * SQL Server DATEADD/DATEDIFF/GETDATE were converted to PostgreSQL date math.
--   * SQL Server STUFF(... FOR XML PATH('')) aggregation was converted to string_agg().
--   * {{C_MIN_AGE}} placeholder was preserved.

--DECLARE @MIN_AGE AS INT = 13
 
DROP TABLE IF EXISTS deceased_pat_reg;
DROP TABLE IF EXISTS pop;
DROP TABLE IF EXISTS dx;
DROP TABLE IF EXISTS bmt;
DROP TABLE IF EXISTS prime_onc;
DROP TABLE IF EXISTS referrals_prep;
DROP TABLE IF EXISTS referrals;
DROP TABLE IF EXISTS fert_nav_result;
DROP TABLE IF EXISTS research;
DROP TABLE IF EXISTS research_start;
DROP TABLE IF EXISTS op_psych;
DROP TABLE IF EXISTS onc_consult;
DROP TABLE IF EXISTS psych_consult;
DROP TABLE IF EXISTS sw_note;
DROP TABLE IF EXISTS treat_overview;
DROP TABLE IF EXISTS chemo;
DROP TABLE IF EXISTS radiation;
DROP TABLE IF EXISTS treatment_plan;
DROP TABLE IF EXISTS op_visits;
DROP TABLE IF EXISTS sexual_health;
DROP TABLE IF EXISTS palliative_note;
 
 /* Site-specific workflow note removed for portfolio use. */
CREATE TEMP TABLE deceased_pat_reg AS
SELECT 
      PAT_ID
    , INTRO_TO_AYA_DT
    , CASE WHEN ONC_THER_CLIN_TRIALS_DISC_YN = '0' THEN 'N'
            WHEN ONC_THER_CLIN_TRIALS_DISC_YN = '1' THEN 'Y'
            ELSE NULL
            END AS ONC_THER_CLIN_TRIALS_DISC_YN
    , PRS_THR_OPT_INC_THR_CLN_TRL_DT
    , DIAGNOSIS_DT
    , PROBLEM_LIST_ID
    , ROW_NUMBER() OVER (PARTITION BY PAT_ID ORDER BY DIAGNOSIS_DT DESC) AS RANK 
FROM (
    SELECT 
          rdi.NETWORKED_ID AS PAT_ID
        , MAX(CASE WHEN dat.ELEMENT_ID IN ('CHHS#3913','CHHS#3881') THEN CAST((DATE '1840-12-31' + (val.SMRTDTA_ELEM_VALUE)::numeric::int) AS DATE)
            ELSE NULL END) AS INTRO_TO_AYA_DT
        , MAX(CASE WHEN dat.ELEMENT_ID = 'CHHS#4360' THEN val.SMRTDTA_ELEM_VALUE  
            ELSE NULL END) AS ONC_THER_CLIN_TRIALS_DISC_YN
        , MAX(CASE WHEN dat.ELEMENT_ID IN ('CHHS#3860','CHHS#3896') THEN CAST((DATE '1840-12-31' + (val.SMRTDTA_ELEM_VALUE)::numeric::int) AS DATE)
            ELSE NULL END) AS PRS_THR_OPT_INC_THR_CLN_TRL_DT
        , COALESCE(pl.DIAG_START_DATE, pl.NOTED_DATE) AS DIAGNOSIS_DT
        , pl.PROBLEM_LIST_ID
    FROM reference_a.REGISTRY_CONFIG AS rc
    INNER JOIN source_a.REG_DATA_MEMBERSHP AS rdm ON rc.REGISTRY_ID::text = rdm.REGISTRY_ID
        AND rdm.REGISTRY_STATUS_C = '1'   --ACTIVE
    INNER JOIN source_a.REGISTRY_DATA_INFO AS rdi ON rdm.RECORD_ID = rdi.RECORD_ID 
    LEFT JOIN source_a.SMRTDTA_ELEM_DATA AS dat on rdi.NETWORKED_ID = dat.RECORD_ID_VARCHAR
        AND dat.CONTEXT_NAME = 'PATIENT'
        AND dat.ELEMENT_ID IN ('CHHS#3913','CHHS#3881','CHHS#4360','CHHS#3860','CHHS#3896')
    LEFT JOIN source_a.SMRTDTA_ELEM_VALUE AS val ON dat.HLV_ID = val.HLV_ID
    INNER JOIN source_a.PROBLEM_LIST AS pl ON rdi.NETWORKED_ID = pl.PAT_ID
    INNER JOIN reference_a.GROUPER_DX_RECORDS AS gp ON pl.DX_ID::text = gp.CMPL_DX_RECS_ID
    WHERE pl.PROBLEM_STATUS_C = '1'   --active
    AND gp.GROUPER_ID = 'A0001'    --EDG GROUPERS Hospital A ONCBCN CANCER DIAGNOSIS USED FOR STAGING
    AND rc.REGISTRY_ID = 'A0002'   --Cancer Population Registry-Deceased Patients
    GROUP BY 
          rdi.NETWORKED_ID
        , COALESCE(pl.DIAG_START_DATE, pl.NOTED_DATE) 
        , pl.PROBLEM_LIST_ID
    ) AS a;
 

 
DROP TABLE IF EXISTS pop;

CREATE TEMP TABLE pop AS
WITH max_race AS (
    SELECT
          pr.pat_id
        , pr.patient_race_c
        , ROW_NUMBER() OVER (
            PARTITION BY pr.pat_id
            ORDER BY pr.line DESC
          ) AS rn
    FROM source_a.patient_race pr
),

patient_race AS (
    SELECT
          mr.pat_id
        , zr.name AS primary_race
    FROM max_race mr
    LEFT JOIN reference_a.zc_patient_race zr
        ON mr.patient_race_c = zr.patient_race_c
    WHERE mr.rn = 1
),

payor AS (
    SELECT
          pac.pat_id
        , epm.payor_name
        , fc.financial_class_name
        , ROW_NUMBER() OVER (
            PARTITION BY pac.pat_id
            ORDER BY pac.line ASC
          ) AS payor_rank
    FROM source_a.pat_acct_cvg pac
    LEFT JOIN reference_a.clarity_epm epm
        ON pac.payor_id = epm.payor_id
    LEFT JOIN reference_a.clarity_fc fc
        ON epm.financial_class = fc.financial_class
    WHERE pac.account_type_c = 1
      AND pac.account_active_yn = 'Y'
      AND pac.serv_area_id = '10'
),

patient_base AS (
    SELECT 
          p.patient_display_name
        , p.site_a_patient_key AS site_a_patient_key
        , p.pat_id
        , p.birth_date
        , reg.age
        , sex.name AS sex
        , p.city
        , p.zip
        , pr.primary_race
        , eg.name AS ethnicity
        , ms.name AS marital_status
        , ser.prov_name AS pcp
        , p.cur_pcp_prov_id
        , p.adv_directive_yn
        , p.death_date    
    FROM source_a.dm_cancer_patient reg
    INNER JOIN source_a.patient p 
        ON reg.pat_id = p.pat_id
    LEFT JOIN patient_race pr
        ON p.pat_id = pr.pat_id
    LEFT JOIN reference_a.clarity_ser ser 
        ON p.cur_pcp_prov_id = ser.prov_id
    INNER JOIN reference_a.zc_sex sex 
        ON p.sex_c = sex.rcpt_mem_sex_c
    LEFT JOIN reference_a.zc_ethnic_group eg
        ON p.ethnic_group_c = eg.ethnic_group_c
    LEFT JOIN reference_a.zc_marital_status ms 
        ON p.marital_status_c = ms.marital_status_c

    UNION ALL

    SELECT 
          p.patient_display_name
        , p.site_a_patient_key AS site_a_patient_key
        , p.pat_id
        , p.birth_date
        , FLOOR(((CURRENT_DATE)::date - (p.birth_date)::date) / 365.25)::text AS age
        , sex.name AS sex
        , p.city
        , p.zip
        , pr.primary_race
        , eg.name AS ethnicity
        , ms.name AS marital_status
        , ser.prov_name AS pcp
        , p.cur_pcp_prov_id
        , p.adv_directive_yn
        , p.death_date
    FROM deceased_pat_reg reg
    INNER JOIN source_a.patient p 
        ON reg.pat_id = p.pat_id
    LEFT JOIN patient_race pr
        ON p.pat_id = pr.pat_id
    LEFT JOIN reference_a.clarity_ser ser 
        ON p.cur_pcp_prov_id = ser.prov_id
    INNER JOIN reference_a.zc_sex sex 
        ON p.sex_c = sex.rcpt_mem_sex_c
    LEFT JOIN reference_a.zc_ethnic_group eg
        ON p.ethnic_group_c = eg.ethnic_group_c
    LEFT JOIN reference_a.zc_marital_status ms 
        ON p.marital_status_c = ms.marital_status_c
),

primary_care_loc AS (
    SELECT
          pt.pat_id
        , h.loc_name
        , 'Internal' AS loc_type
    FROM patient_base pt
    LEFT JOIN source_a.d_prov_primary_hierarchy h
        ON pt.cur_pcp_prov_id = h.prov_id
    WHERE h.loc_name NOT IN ('*Unspecified Location', '')
),

max_line_addr AS (
    SELECT
          sd.*
        , ROW_NUMBER() OVER (
            PARTITION BY sd.prov_id 
            ORDER BY sd.line DESC
          ) AS rn
    FROM reference_a.clarity_ser_addr sd
),

outside_primary_care_loc AS (
    SELECT
          pt.pat_id
        , sd.ext_practice_name
        , 'External' AS loc_type
    FROM patient_base pt
    JOIN max_line_addr sd
        ON pt.cur_pcp_prov_id = sd.prov_id
    WHERE sd.rn = 1
),

location AS (
    SELECT DISTINCT
          pt.*
        , py.payor_name
        , py.financial_class_name
        , COALESCE(pc.loc_name, o.ext_practice_name) AS pcp_location
        , CASE
            WHEN COALESCE(NULLIF(pc.loc_name, ''), NULLIF(o.ext_practice_name, '')) IS NULL 
                THEN 'Unknown'
            ELSE COALESCE(NULLIF(pc.loc_type, ''), NULLIF(o.loc_type, ''), 'Unknown')
          END AS pcp_location_type
    FROM patient_base pt
    LEFT JOIN payor py
        ON pt.pat_id = py.pat_id
       AND py.payor_rank = 1
    LEFT JOIN primary_care_loc pc
        ON pt.pat_id = pc.pat_id
    LEFT JOIN outside_primary_care_loc o
        ON pt.pat_id = o.pat_id
)

SELECT
      patient_display_name
    , site_a_patient_key
    , pat_id
    , birth_date
    , age
    , sex
    , city
    , zip
    , primary_race
    , ethnicity
    , marital_status
    , CASE
        WHEN cur_pcp_prov_id IN (
            'A0003','A0004','A0005','A0006','A0007','A0008','A0009','A0010',
            'A0011','A0012','A0013','A0014','A0015','A0016','A0017','A0018',
            'A0019','A0020','A0021','A0022','A0023','A0024','A0025',
            'A0026','A0027'
        ) THEN NULL
        ELSE pcp
      END AS pcp
    , cur_pcp_prov_id
    , adv_directive_yn
    , death_date
    , payor_name
    , financial_class_name
    , CASE
        WHEN cur_pcp_prov_id IN (
            'A0003','A0004','A0005','A0006','A0007','A0008','A0009','A0028',
            'A0029','A0030','A0031','A0032','A0010','A0011','A0012','A0013',
            'A0014','A0015','A0016','A0017','A0018','A0019','A0020',
            'A0021','A0022','A0023','A0024','A0025','A0026','A0027'
        ) THEN NULL
        ELSE pcp_location
      END AS pcp_location
    , CASE
        WHEN cur_pcp_prov_id IN (
            'A0003','A0004','A0005','A0006','A0007','A0008','A0009','A0010',
            'A0011','A0012','A0013','A0014','A0015','A0016','A0017','A0018',
            'A0019','A0020','A0021','A0022','A0023','A0024','A0025',
            'A0026','A0027'
        ) THEN 'Unknown'
        WHEN pcp_location IS NULL THEN 'Unknown'
        WHEN cur_pcp_prov_id IN ('A0028','A0029','A0030','A0031','A0032') THEN 'External'
        WHEN pcp_location LIKE 'HOSPITAL B HEALTH SYSTEM%' THEN 'Internal'
        WHEN pcp_location LIKE 'ACADEMIC MEDICAL CENTER' THEN 'Internal'
        ELSE pcp_location_type
      END AS pcp_location_type
FROM location;
 
 
/* Site-specific workflow note removed for portfolio use. */
    SELECT
          pop.pat_id
        , cpl.problem_list_id::text AS problem_list_id
        , cpl.diagnosis_dt
        , (((cpl.diagnosis_dt)::date - (pop.birth_date)::date) / 365.25)::numeric AS patient_age_at_diagnosis
        , edg.dx_id
        , edg.dx_name
        , COALESCE(icd10.code,icd9.code) as dx_code
        , nei.end_of_treat_date
        , hno_link.tx_sum_hno_id
        , ROW_NUMBER() OVER (
            PARTITION BY pop.pat_id
            ORDER BY cpl.diagnosis_dt DESC, nei.end_of_treat_date DESC
          ) AS dx_rank
    FROM pop AS pop
    INNER JOIN deceased_pat_reg AS cpl
        ON pop.pat_id = cpl.pat_id
    INNER JOIN source_a.problem_list AS pl
        ON cpl.problem_list_id::text = pl.problem_list_id::text
    INNER JOIN reference_a.clarity_edg AS edg
        ON pl.dx_id = edg.dx_id
    LEFT JOIN reference_a.edg_current_ICD10 icd10
        ON edg.dx_id=icd10.dx_id
    LEFT JOIN reference_a.edg_current_ICD9 icd9
        ON edg.dx_id=icd9.dx_id
    LEFT JOIN source_a.problem_treat_summ_hno_id AS hno_link
        ON pl.problem_list_id = hno_link.problem_list_id
    LEFT JOIN notes_a.note_enc_info AS nei
        ON hno_link.tx_sum_hno_id = nei.note_id
        AND nei.most_recent_cnct_yn = 'Y'
    WHERE (((cpl.diagnosis_dt)::date - (pop.birth_date)::date) / 365.25)::numeric < 40

) AS a
GROUP BY pat_id;
/* Site-specific workflow note removed for portfolio use. */
SELECT
      pop.PAT_ID
    , stag.SIGN_DATETIME
    , emp.NAME AS SIGN_USER_NAME
    , ROW_NUMBER() OVER (PARTITION BY pop.PAT_ID ORDER BY stag.SIGN_DATETIME DESC) AS RANK
FROM pop AS pop
INNER JOIN deceased_pat_reg AS cpl ON pop.PAT_ID = cpl.PAT_ID
INNER JOIN source_a.V_CANCER_STAGING AS stag ON cpl.PROBLEM_LIST_ID = stag.PROBLEM_LIST_ID
    AND stag.MOST_RECENT_CONTACT_YN = 'Y'
INNER JOIN reference_a.CLARITY_EMP AS emp ON stag.SIGN_USER_ID = emp.USER_ID;


 
CREATE TEMP TABLE referrals_prep AS
SELECT pop.PAT_ID
     , CASE WHEN PROC_ID IN ('A0033','A0034') THEN 'Fertility Navigator'
        WHEN PROC_ID = 'A0035' THEN 'OT'
        WHEN PROC_ID IN ('A0036','A0037') THEN 'Palliative'
        WHEN PROC_ID IN ('A0038','A0039','A0040','A0041') THEN 'Hospice'
        WHEN PROC_ID = 'A0042' THEN 'Reproductive Med'
        WHEN PROC_ID IN ('A0043','A0044') THEN 'Child Life'
        WHEN PROC_ID IN ('A0045','A0046','A0047') THEN 'PT'
        WHEN PROC_ID IN ('A0048','A0049') THEN 'Nutrition'
        END AS ORDER_CAT
    , op.ORDERING_DATE
    , CASE WHEN PROC_ID = 'A0036' THEN 'IP Consult'
        WHEN PROC_ID = 'A0037' THEN 'OP Referral'
        END AS PALLIATIVE_CARE_TYPE
    , ROW_NUMBER() OVER (PARTITION BY pop.PAT_ID, CASE WHEN PROC_ID IN ('A0033','A0034') THEN 'Fertility Navigator'
                                                    WHEN PROC_ID = 'A0035' THEN 'OT'
                                                    WHEN PROC_ID IN ('A0036','A0037') THEN 'Palliative'
                                                    WHEN PROC_ID IN ('A0038','A0039','A0040','A0041') THEN 'Hospice'
                                                    WHEN PROC_ID = 'A0042' THEN 'Reproductive Med'
                                                    WHEN PROC_ID IN ('A0043','A0044') THEN 'Child Life'
                                                    WHEN PROC_ID IN ('A0045','A0046','A0047') THEN 'PT'
                                                    WHEN PROC_ID IN ('A0048','A0049') THEN 'Nutrition'
                                                    END 
                ORDER BY op.ORDERING_DATE) AS RANK
FROM pop AS pop
INNER JOIN dx AS dx ON pop.PAT_ID = dx.PAT_ID
INNER JOIN source_a.ORDER_PROC AS op ON pop.PAT_ID = op.PAT_ID
WHERE PROC_ID IN ('A0033'   --HOSP CONSULT TO AYA PROGRAM FERTILITY NAVIGATOR
                , 'A0034'   --AMB REFERRAL TO AYA PROGRAM FERTILITY NAVIGATOR
                , 'A0035'     --AMB REFERRAL TO OCCUPATIONAL THERAPY-EVAL AND TREAT
                /* Site-specific workflow note removed for portfolio use. */
                , 'A0036'     --HOSP CONSULT TO PALLIATIVE CARE
                , 'A0037'   --AMB REFERRAL TO PALLIATIVE
                , 'A0038'     --IP CONSULT TO HOSPICE
                , 'A0039'     --AMB REFERRAL TO HOSPICE
                , 'A0040'  --DISCHARGE HOSPICE SERVICES HOME HEALTH
                , 'A0041'  --DISCHARGE HOSPICE CARE
                , 'A0042'  --AMB REFERRAL TO REPRODUCTIVE MEDICINE 
                , 'A0043'   --HOSP CONSULT TO CHILD LIFE 
                , 'A0044'   --AMB REFERRAL TO CHILD LIFE
                , 'A0045'   --PHYSICAL THERAPY CONSULT
                , 'A0046' --AMB REFERRAL TO PHYSICAL THERAPY-EVAL AND TREAT
                , 'A0047'  --AMB REFERRAL TO IHP PHYSICAL THERAPY-EVAL AND TREAT
                , 'A0048' --HOSP CONSULT TO CLINICAL NUTRITION
                , 'A0049'  --AMB REFERRAL TO NUTRITION SERVICES (AYA PROGRAM CENTER)
 
                )
    AND (op.ORDER_STATUS_C <> '4'   --canceled
        OR op.REASON_FOR_CANC_C = '14') --Patient Discharge
    AND op.ORDERING_DATE >= (dx.MAX_DIAGNOSIS_DATE + (-7 * INTERVAL '1 day'));    -- Site-specific workflow note removed for portfolio use.


 
CREATE TEMP TABLE referrals AS
SELECT 
      PAT_ID
    , MIN(CASE WHEN ORDER_CAT = 'Fertility Navigator' THEN ORDERING_DATE ELSE NULL END) AS FIRST_FERTILITY_NAVIGATOR_REFERRAL_DT
    , MIN(CASE WHEN ORDER_CAT = 'OT' THEN ORDERING_DATE ELSE NULL END) AS FIRST_OT_REFERRAL_DT
    , MIN(CASE WHEN ORDER_CAT = 'Palliative' THEN ORDERING_DATE ELSE NULL END) AS FIRST_PALLIATIVE_CARE_REFERRAL_DT
    , MIN(CASE WHEN ORDER_CAT = 'Palliative' THEN PALLIATIVE_CARE_TYPE ELSE NULL END) AS FIRST_PALLIATIVE_CARE_REFERRAL_TYPE
    , MIN(CASE WHEN ORDER_CAT = 'Hospice' THEN ORDERING_DATE ELSE NULL END) AS FIRST_HOSPICE_REFERRAL_DT
    , MIN(CASE WHEN ORDER_CAT = 'Reproductive Med' THEN ORDERING_DATE ELSE NULL END) AS FIRST_REPRODUCTIVE_MED_REFERRAL_DT
    , MIN(CASE WHEN ORDER_CAT = 'Child Life' THEN ORDERING_DATE ELSE NULL END) AS FIRST_CHILD_LIFE_REFERRAL_DT
    , MIN(CASE WHEN ORDER_CAT = 'PT' THEN ORDERING_DATE ELSE NULL END) AS FIRST_PT_REFERRAL_DT
    , MIN(CASE WHEN ORDER_CAT = 'Nutrition' THEN ORDERING_DATE ELSE NULL END) AS FIRST_NUTRITION_REFERRAL_DT
FROM referrals_prep
WHERE RANK = 1
GROUP BY 
      PAT_ID;
 
 
/* Site-specific workflow note removed for portfolio use. */
--SELECT DISTINCT 
--      pop.PAT_ID
--INTO TEMP chemo
--FROM pop AS pop
--INNER JOIN PAT_LIFEDOSE AS ld ON pop.PAT_ID = ld.PAT_ID
--WHERE CALC_DOSE_AMT > 0

CREATE TEMP TABLE chemo AS
SELECT 
          pop.PAT_ID
        , MIN(om.ORDERING_DATE) AS FIRST_CHEMO_ORDER_DT
FROM pop AS pop
INNER JOIN source_a.ORDER_MED AS om ON pop.PAT_ID = om.PAT_ID
INNER JOIN reference_a.CLARITY_MEDICATION AS cm ON om.MEDICATION_ID = cm.MEDICATION_ID
INNER JOIN reference_a.ZC_PHARM_CLASS AS pc ON cm.PHARM_CLASS_C = pc.PHARM_CLASS_C
LEFT JOIN source_a.ORDER_MEDMIXINFO AS mm ON om.ORDER_MED_ID = mm.ORDER_MED_ID
LEFT JOIN reference_a.CLARITY_MEDICATION AS mm_cm ON mm.MEDICATION_ID = mm_cm.MEDICATION_ID
LEFT JOIN reference_a.ZC_PHARM_CLASS AS mm_pc ON mm_cm.PHARM_CLASS_C = mm_pc.PHARM_CLASS_C
INNER JOIN source_a.MAR_ADMIN_INFO AS mar ON om.ORDER_MED_ID = mar.ORDER_MED_ID
       AND mar.mar_action_c = '1' --given
WHERE pc.NAME LIKE '%ANTINEOPLASTIC%'
OR mm_pc.NAME LIKE '%ANTINEOPLASTIC%'
GROUP BY pop.PAT_ID;


 
/* Site-specific workflow note removed for portfolio use. */
CREATE TEMP TABLE palliative_note AS
SELECT pop.PAT_ID
     , COUNT(*) AS COUNT_PALLIATIVE_CARE_NOTE
FROM pop AS pop
INNER JOIN notes_a.HNO_INFO AS hno ON pop.PAT_ID = hno.PAT_ID
INNER JOIN notes_a.NOTE_ENC_INFO AS nei ON hno.NOTE_ID = nei.NOTE_ID    
    AND nei.MOST_RECENT_CNCT_YN = 'Y'
INNER JOIN reference_a.CLARITY_EMP AS emp ON hno.CURRENT_AUTHOR_ID = emp.USER_ID
LEFT JOIN reference_a.CLARITY_SER_SPEC AS spec ON emp.PROV_ID = spec.PROV_ID
    AND spec.LINE = 1
WHERE (nei.AUTHOR_SERVICE_C = 'A0050' --Palliative Care
    OR spec.SPECIALTY_C = 'A0051')    --Palliative Care  
GROUP BY pop.PAT_ID;

DROP TABLE IF EXISTS analytics_a.cw_cancer_reporting;
CREATE TABLE analytics_a.cw_cancer_reporting AS

With base as ( 
SELECT 
      pop.PAT_NAME
    --, pop.site_a_patient_key
    , pop.PAT_ID
    , pop.BIRTH_DATE
    , pop.AGE
    , pop.SEX
    , pop.CITY
    , split_part(pop.zip, '-', 1) AS zip
    , pop.PRIMARY_RACE
    , pop.ETHNICITY
    , pop.MARITAL_STATUS
    , dx.DIAGNOSIS_DATE
    , dx.MAX_DIAGNOSIS_DATE
    , tp.TREAT_PLAN_START_DATE AS MOST_RECENT_TREAT_PLAN_START_DATE
        , tp_first.TREAT_PLAN_START_DATE AS FIRST_TREAT_PLAN_START_DATE
    , CAST(CAST(patient_age_at_diagnosis AS numeric) AS integer) AS patient_age_at_diagnosis
    , dx.dx_1_code
    , dx.dx_1_name
    , dx.dx_2_code
    , dx.dx_2_name
    , dx.dx_3_code
    , dx.dx_3_name
    , CASE WHEN bmt.PAT_ID IS NOT NULL THEN 'Y' ELSE 'N' END AS BMT_YN
    , po.SIGN_USER_NAME AS PRIMARY_ONCOLOGIST
    , pop.PCP  
    , pop.PCP_LOCATION
    , pop.pcp_location_type
    , CASE WHEN x_reg.DATE_INT_TO_AYA_PROGRAM_DT = '1840-12-31 00:00:00.000' THEN NULL ELSE COALESCE(x_reg.DATE_INT_TO_AYA_PROGRAM_DT, deceased.INTRO_TO_AYA_DT) END AS INTRO_AYA_DT
    , CASE WHEN x_reg.DATE_INT_TO_AYA_PROGRAM_DT = '1840-12-31 00:00:00.000' THEN NULL ELSE (COALESCE(x_reg.DATE_INT_TO_AYA_PROGRAM_DT, deceased.INTRO_TO_AYA_DT)::date - MAX_DIAGNOSIS_DATE::date) END AS DAYS_DX_TO_INTRO_AYA
    , COALESCE(x_reg.ONC_THER_CLIN_TRIALS_DISC_YN,deceased.ONC_THER_CLIN_TRIALS_DISC_YN) AS THERAPEUTIC_TRIALS_DISCUSSED_YN
    , COALESCE(x_reg.PRS_THR_OPT_INC_THR_CLN_TRL_DT, deceased.PRS_THR_OPT_INC_THR_CLN_TRL_DT) AS THERAPY_OPTIONS_PRESENTED_DT
    , (COALESCE(x_reg.PRS_THR_OPT_INC_THR_CLN_TRL_DT, deceased.PRS_THR_OPT_INC_THR_CLN_TRL_DT)::date - MAX_DIAGNOSIS_DATE::date) AS DAYS_DX_TO_THERAPY_OPTIONS_PRESENTED_DT
    , (
        SELECT string_agg(rsh.RESEARCH_STUDY_NAME, ';' ORDER BY rsh.RESEARCH_STUDY_NAME)
        FROM research AS rsh
        WHERE rsh.PAT_ID = pop.PAT_ID
          AND rsh.STUDY_TYPE = 'Therapeutic'
      ) AS ENROLLED_CLINICAL_TRIALS
    , (
        SELECT COUNT(*)
        FROM research AS rsh
        WHERE rsh.pat_id = pop.pat_id
        AND rsh.study_type = 'Therapeutic'
        ) AS enrolled_clinical_trials_count
    , therapeutic_research.STUDY_START_DT AS THERAPEUTIC_STUDY_START_DATE
    , ((therapeutic_research.STUDY_START_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_TO_THERAPEUTIC_CLINICAL_TRIAL_ENROLL
    , (
        SELECT string_agg(rsh.RESEARCH_STUDY_NAME, ';' ORDER BY rsh.RESEARCH_STUDY_NAME)
        FROM research AS rsh
        WHERE rsh.PAT_ID = pop.PAT_ID
          AND rsh.STUDY_TYPE = 'Non-Therapeutic'
      ) AS ENROLLED_CLINICAL_TRIALS_NON_THERAPEUTIC
    , (
        SELECT COUNT(*)
        FROM research AS rsh
        WHERE rsh.pat_id = pop.pat_id
        AND rsh.study_type = 'Non-Therapeutic'
        ) AS enrolled_clinical_trials_non_therapeutic_count
    , nontherapeutic_research.STUDY_START_DT AS NONTHERAPEUTIC_STUDY_START_DATE
    , ((nontherapeutic_research.STUDY_START_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_TO_NONTHERAPEUTIC_CLINICAL_TRIAL_ENROLL
    , (
        SELECT string_agg(rsh.RESEARCH_STUDY_NAME, ';' ORDER BY rsh.RESEARCH_STUDY_NAME)
        FROM research AS rsh
        WHERE rsh.PAT_ID = pop.PAT_ID
          AND rsh.STUDY_TYPE IS NULL
      ) AS ENROLLED_CLINICAL_TRIALS_OTHER
    , (
        SELECT COUNT(*)
        FROM research AS rsh
        WHERE rsh.pat_id = pop.pat_id
        AND rsh.study_type IS NULL
        ) AS enrolled_clinical_trials_other_count
    , other_research.STUDY_START_DT AS OTHER_CLINICAL_TRAILS_START_DATE
    , ((other_research.STUDY_START_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_TO_OTHER_CLINICAL_TRIAL_ENROLL
    , tr_ov.TREATMENT_OVERVIEW_DT AS TREATMENT_OVERVIEW_DT
    , ((tr_ov.TREATMENT_OVERVIEW_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_TREATMENT_OVERVIEW
    , ref.FIRST_FERTILITY_NAVIGATOR_REFERRAL_DT AS FERTILITY_REFERRAL_DATE
    , ((ref.FIRST_FERTILITY_NAVIGATOR_REFERRAL_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_FERTILITY_NAVIGATOR_REFERRAL
    , fert_nav_res.ELEMENT_VALUE AS SuccessfulYN
    , (
        SELECT string_agg(res.ELEMENT_VALUE, ';' ORDER BY res.ELEMENT_VALUE)
        FROM fert_nav_result AS res
        WHERE res.PAT_ID = pop.PAT_ID
          AND res.ELEMENT = 'Method'
      ) AS FERTILITY_PRESERVATION_METHOD
    , ref.FIRST_REPRODUCTIVE_MED_REFERRAL_DT AS REPRODUCTIVE_MED_REFERRAL_DATE
    , ((ref.FIRST_REPRODUCTIVE_MED_REFERRAL_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_REPRODUCTIVE_MED_REFERRAL
    , sw.SOCIAL_WORK_DT AS SOCIAL_WORK_REFERRAL_DATE
    , ((sw.SOCIAL_WORK_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_SOCIAL_WORK_NOTE
    , psych_consult.NOTE_DT AS PSYCHOLOGY_REFERRAL_DATE
    , ((psych_consult.NOTE_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_PSYCH_NOTE
    , psych_consult.PSYCH_CONSULT_LOCATION AS FIRST_PSYCH_NOTE_LOC
    , psych_consult.NOTE_AUTHOR AS FIRST_PSYCH_NOTE_AUTHOR
    , ref.FIRST_CHILD_LIFE_REFERRAL_DT AS CHILD_LIFE_REFERRAL_DATE
    , ((ref.FIRST_CHILD_LIFE_REFERRAL_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_CHILD_LIFE_REFERRAL
    , ref.FIRST_PT_REFERRAL_DT AS PT_REFERRAL_DT
    , ((ref.FIRST_PT_REFERRAL_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_PT_REFERRAL
    , ref.FIRST_OT_REFERRAL_DT
    , ((ref.FIRST_OT_REFERRAL_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_OT_REFERRAL
    , ref.FIRST_PALLIATIVE_CARE_REFERRAL_DT AS PALLIATIVE_REFERRAL_DATE
    , ref.FIRST_PALLIATIVE_CARE_REFERRAL_TYPE
    , ((ref.FIRST_PALLIATIVE_CARE_REFERRAL_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_PALLIATIVE_CARE_REFERRAL
    , ((DEATH_DATE)::date - (ref.FIRST_PALLIATIVE_CARE_REFERRAL_DT)::date) AS DAYS_PALLIATIVE_CARE_REFERRAL_TO_DEATH
    , palliative.COUNT_PALLIATIVE_CARE_NOTE
    , ref.FIRST_HOSPICE_REFERRAL_DT AS HOSPICE_REFERRAL_DATE
    , ((ref.FIRST_HOSPICE_REFERRAL_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_HOSPICE_REFERRAL
    , ref.FIRST_NUTRITION_REFERRAL_DT AS NUTRITION_REFERRAL_DATE
    , ((ref.FIRST_NUTRITION_REFERRAL_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_NUTRITION_REFERRAL
    , op_visit.FIRST_AYA PROGRAM_PREDISPOSITION_VISIT_DT as genetics_referral_date
    , ((op_visit.FIRST_AYA PROGRAM_PREDISPOSITION_VISIT_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_AYA PROGRAM_PREDISPOSITION_VISIT
    , op_visit.FIRST_AYA PROGRAM_FULL_NEXT_STEPS_VISIT_DT
    , op_visit.LAST_BRIDGE_1_VISIT_DT
    , op_visit.LAST_BRIDGE_2_VISIT_DT
        , sh.FIRST_SEXUAL_HEALTH_VISIT_DT AS SEXUAL_HEALTH_REFERRAL_DATE
        , ((sh.FIRST_SEXUAL_HEALTH_VISIT_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_FIRST_SEXUAL_HEALTH_VISIT
        , sh.FIRST_SEXUAL_HEALTH_APPT_STATUS
    , CASE WHEN chemo.PAT_ID IS NULL THEN 'N' ELSE 'Y' END AS TREATMENT_IV_CHEMO_YN
        , chemo.FIRST_CHEMO_ORDER_DT as chemo_start_date
        , ((chemo.FIRST_CHEMO_ORDER_DT)::date - (MAX_DIAGNOSIS_DATE)::date) AS DAYS_DX_TO_FIRST_CHEMO_ORDER
    , CASE WHEN radiation.PAT_ID IS NULL THEN 'N' ELSE 'Y' END AS TREATMENT_RADIATION_YN
    , radiation.event_start_dttm AS radiation_start_date
    --, CASE WHEN dx.END_OF_TREAT_DATE > bmt.END_OF_TREAT_DATE OR bmt.END_OF_TREAT_DATE IS NULL THEN dx.END_OF_TREAT_DATE --choose the max of oncology or BMT end of treatment date
        --ELSE bmt.END_OF_TREAT_DATE
        --END AS END_OF_TREAT_DATE
    , tp.TREAT_PLAN_DISC_DATE
    , pop.DEATH_DATE
    , pop.PAYOR_NAME
    , pop.FINANCIAL_CLASS_NAME
    , pop.ADV_DIRECTIVE_YN
FROM pop AS pop
LEFT JOIN dx AS dx ON pop.PAT_ID = dx.PAT_ID
LEFT JOIN bmt AS bmt ON pop.PAT_ID = bmt.PAT_ID
LEFT JOIN prime_onc AS po ON pop.PAT_ID = po.PAT_ID
    AND po.RANK = 1 --pulls most recently signed staging form
LEFT JOIN referrals AS ref ON pop.PAT_ID = ref.PAT_ID
LEFT JOIN fert_nav_result AS fert_nav_res ON pop.PAT_ID = fert_nav_res.PAT_ID
    AND ELEMENT = 'Successful YN'
LEFT JOIN onc_consult AS onc_consult ON pop.PAT_ID = onc_consult.PAT_ID
    AND onc_consult.RANK = 1
LEFT JOIN psych_consult AS psych_consult ON pop.PAT_ID = psych_consult.PAT_ID
    AND psych_consult.RANK = 1
LEFT JOIN op_visits AS op_visit ON pop.PAT_ID = op_visit.PAT_ID
LEFT JOIN sw_note AS sw ON pop.PAT_ID = sw.PAT_ID
LEFT JOIN treat_overview AS tr_ov ON pop.PAT_ID = tr_ov.PAT_ID
LEFT JOIN source_a.X_DM_CANCER_PATIENT AS x_reg ON pop.PAT_ID = x_reg.X_PAT_ID   --CUSTOM REGISTRY FIELDS
LEFT JOIN deceased_pat_reg AS deceased ON pop.PAT_ID = deceased.PAT_ID -- Site-specific workflow note removed for portfolio use.
    AND deceased.rank = 1
LEFT JOIN chemo AS chemo ON pop.PAT_ID = chemo.PAT_ID
LEFT JOIN radiation AS radiation ON pop.PAT_ID = radiation.PAT_ID 
        AND radiation.rad_rank = 1
LEFT JOIN treatment_plan AS tp ON pop.PAT_ID = tp.PAT_ID
    AND tp.RANK_LAST = 1 --MOST RECENT
LEFT JOIN treatment_plan AS tp_first ON pop.PAT_ID = tp_first.PAT_ID    -- Site-specific workflow note removed for portfolio use.
        AND tp_first.RANK_FIRST = 1     --FIRST
LEFT JOIN research_start AS therapeutic_research ON pop.PAT_ID = therapeutic_research.PAT_ID   
    AND therapeutic_research.STUDY_TYPE = 'Therapeutic'
LEFT JOIN research_start AS nontherapeutic_research ON pop.PAT_ID = nontherapeutic_research.PAT_ID 
    AND nontherapeutic_research.STUDY_TYPE = 'Non-Therapeutic'
LEFT JOIN research_start AS other_research ON pop.PAT_ID = other_research.PAT_ID   
    AND other_research.STUDY_TYPE IS NULL
LEFT JOIN palliative_note AS palliative ON pop.PAT_ID = palliative.PAT_ID
LEFT JOIN sexual_health AS sh ON pop.PAT_ID = sh.PAT_ID
        AND sh.RANK = 1 --FIRST
WHERE dx.PATIENT_AGE_AT_DIAGNOSIS < '40'
AND (op_visit.ONCOLOGY_VISIT = 1    --HAS SEEN ONCOLOGY EITHER OP VISIT OR CONSULT NOTE
    OR onc_consult.PAT_ID IS NOT NULL))
    
    Select b.*,
           svp.site_a_patient_key
    
    From base b
    Join identity_a.patient_crosswalk svp
        ON svp.pat_id = b.pat_id
    WHere b.patient_age_at_diagnosis::numeric between 15 and 40 AND
          b.diagnosis_date>= DATE '2015-01-01';
