/****************************************************************************************
PROJECT:
    Multi-Site AYA Oncology Data Harmonization — Hospital B Pipeline

PURPOSE:
    Build a one-row-per-patient adolescent and young adult oncology dataset for
    Hospital B. This site primarily identifies the cohort through oncology
    departments and encounters, then supplements diagnosis information with
    registry/NAACCR data and encounter-based diagnosis workflows.

PORTFOLIO SAFETY:
    - Organization, schema, role, employee, and infrastructure names are generalized.
    - Site-specific numeric identifiers are replaced with synthetic identifiers.
    - Patient keys are de-identified placeholders.
    - The workflow and SQL techniques remain structurally faithful to the source build.

HOSPITAL B WORKFLOW HIGHLIGHTS:
    - Cohort begins with oncology department groupers and qualifying encounters.
    - Diagnosis dates prioritize registry data when valid, with encounter diagnoses
      used as a fallback.
    - Oral and IV chemotherapy are derived separately and combined.
    - Radiation dates are parsed from multiple text formats in order-result data.
    - Supportive-care services are identified through several distinct workflows:
      referrals, orders, provider encounters, SmartData Elements, and note text.
    - Final output is limited to patients diagnosed from age 15 through 49.
****************************************************************************************/

/*
Updated Hospital B AYA build based on comparison with AYA Sample and Hospital A New AYA Build.
Key updates:
- Keeps Hospital B PCP logic and NAACCR/coalesced diagnosis-code logic.
- Keeps all available encounter/data history; no rolling 49-month or 12-month restriction added.
- Uses age at diagnosis as the final cohort driver: 15 through 49 years old.
- Standardized the PAT_ENC_DX join to source_b.
- Fixed duplicate NAACCR join line.
- Adds one-row-per-patient treatment plan summary with count, coalesced names, and first plan order date.
*/

--Cancer Departments
-- Production role-setting command removed for portfolio use.

Drop table if exists analytics_b.cancer_departments;
Create table analytics_b.cancer_departments as

select distinct z.* 
from (
select distinct GROUPER_RECORDS_VARCHAR_ID as department_id
from source_b.GROUPER_COMPILED_REC_LIST
where base_grouper_id in ('B0001','B0002') -- Department grouper to identify all CC patients
and GROUPER_RECORDS_VARCHAR_ID not in ('B0003','B0004')  --Exclude Hospital B UROLOGY and FWC NEUROLOGY
UNION
select distinct department_id::text
from reference_b.clarity_dep 
where department_id in ('B0005','B0006','B0007','B0008','B0009','B0010','B0011','B0012','B0013','B0014')
) z
; 

--Encounters in Cancer Departments 
Drop table if exists analytics_b.cancer_encounters;
Create table analytics_b.cancer_encounters as

select distinct a.*
from source_b.pat_enc a
Join analytics_b.cancer_departments b on b.department_id =a.DEPARTMENT_ID::text
;

Drop table if exists analytics_b.cancer_patient_demographic;
Create table analytics_b.cancer_patient_demographic as

With distinct_patient as
(Select distinct pat_id
From analytics_b.cancer_encounters),

patient as
(SELECT p.patient_display_name,
       svp.site_b_patient_key,
       svp.pat_id,
       p.birth_date,
       sex.name AS sex,
       p.city,
       p.zip,
       zcp.name AS primary_race,
       eg.name AS ethnicity,
       ser.prov_name AS pcp,
       p.cur_pcp_prov_id,
       --primary_scheduling_dept.location_name AS pcp_primary_location,
       --epm.payor_name,
       --fc.financial_class_name,
       p.adv_directive_yn,
       pd.death_date

FROM distinct_patient dp
JOIN source_b.dm_cancer_patient reg ON dp.pat_id=reg.pat_id
JOIN source_b.patient AS p ON reg.pat_id = p.pat_id
JOIN identity_b.patient_crosswalk svp ON svp.pat_id = p.pat_id
LEFT JOIN mortality_b.patient_death pd On reg.pat_id=pd.pat_id
LEFT JOIN reference_b.clarity_ser AS ser ON p.cur_pcp_prov_id = ser.prov_id
JOIN reference_b.zc_sex AS sex ON p.sex_c = sex.rcpt_mem_sex_c
LEFT JOIN reference_b.zc_ethnic_group AS eg ON p.ethnic_group_c = eg.ethnic_group_c
LEFT JOIN source_b.patient_race pr ON p.pat_id = pr.pat_id
LEFT JOIN reference_b.zc_patient_race zcp ON pr.patient_race_c = zcp.patient_race_c
Where pr.line='1'),

payor as (

Select pt.*,
       cvg.payor_id,
       ROW_NUMBER()OVER (PARTITION BY cvg.pat_id ORDER BY cvg.line ASC) AS rank,
       epm.payor_name,
       fc.financial_class_name

FROM patient pt
LEFT JOIN source_b.pat_acct_cvg cvg ON pt.pat_id=cvg.pat_id
LEFT JOIN reference_b.clarity_epm epm ON cvg.payor_id = epm.payor_id
LEFT JOIN reference_b.clarity_fc fc ON epm.financial_class = fc.financial_class

WHERE cvg.account_type_c = '1' AND cvg.account_active_yn = 'Y'),

primary_care_loc as (

Select pt.*,
       h.loc_name,
       'Internal' as loc_type
       
FROM patient pt
LEFT JOIN reference_b.d_prov_primary_hierarchy h On pt.cur_pcp_prov_id=prov_id

WHERE h.loc_name NOT IN ('*Unspecified Location', '')),

max_line_addr as (

SELECT sd.*,
       ROW_NUMBER() OVER (PARTITION BY sd.prov_id ORDER BY sd.line DESC) AS rn
       
FROM reference_b.clarity_ser_addr sd
),

outside_primary_care_loc as (

SELECT pt.*,
       sd.ext_practice_name,
       'External' as loc_type
       
FROM patient pt 
JOIN max_line_addr sd ON pt.cur_pcp_prov_id = sd.prov_id

WHERE  sd.rn = 1)

SELECT DISTINCT pt.*,
       py.payor_name,
       py.financial_class_name,
       COALESCE(NULLIF(pc.loc_name, ''), NULLIF(o.ext_practice_name, '')) AS pcp_location,
       CASE 
           WHEN COALESCE(NULLIF(pc.loc_name, ''), NULLIF(o.ext_practice_name, '')) IS NULL 
               THEN 'Unknown'
           ELSE COALESCE(NULLIF(pc.loc_type, ''), NULLIF(o.loc_type, ''), 'Unknown')
       END AS pcp_location_type
       
FROM patient pt
LEFT JOIN payor py ON pt.pat_id = py.pat_id AND py.rank = 1
LEFT JOIN primary_care_loc pc ON pt.pat_id = pc.pat_id
LEFT JOIN outside_primary_care_loc o ON pt.pat_id = o.pat_id;

Drop table if exists analytics_b.cancer_dx;
Create table analytics_b.cancer_dx as

WITH dx_inclusion AS (
    SELECT 
        base_grouper_id AS group_id,
        line,
        grouper_records_numeric_id AS cmpl_dx_recs_id,
        edg.dx_id,
        edg.dx_name,
        edg.diagnosis_code,
        edg.current_icd10_list
    FROM 
        source_b.grouper_compiled_rec_list gc
    JOIN 
        reference_b.clarity_edg edg 
    ON 
        gc.grouper_records_numeric_id = edg.dx_id
    WHERE 
        base_grouper_id = 'B0015' 
        AND compiled_context = 'EDG'
),

ranked_appts AS (
    SELECT 
        pe.pat_id,
        pe.contact_date,
        pe.pat_enc_csn_id,
        dx.dx_id,
        dxi.dx_id as ref_dx_id_inclusion,
        dx.line,
        /*Case when edg.current_icd10_list is null then edg.current_icd9_list
        else edg.current_icd10_list end as current_icd10_list,*/
        icd10.code as icd10_code,
        icd9.code as icd9_code,
        edg.dx_name,
        ROW_NUMBER() OVER (
            PARTITION BY pe.pat_id
            ORDER BY pe.contact_date ASC, dx.line ASC
        ) AS row_rank
        
FROM  analytics_b.cancer_encounters pe
JOIN source_b.PAT_ENC_DX dx on dx.PAT_ENC_CSN_ID = pe.PAT_ENC_CSN_ID 
JOIN dx_inclusion dxi ON dx.dx_id = dxi.dx_id
left join reference_b.CLARITY_PRC prc on prc.PRC_ID = pe.APPT_PRC_ID
left join reference_b.CLARITY_EDG edg on edg.DX_ID = dx.DX_ID 
left join reference_b.edg_current_icd10 icd10 on edg.dx_id=icd10.dx_id
left join reference_b.edg_current_icd9 icd9 on edg.dx_id=icd9.dx_id

WHERE 
        pe.APPT_STATUS_C IN (2, 6) -- 2 - Completed;  6 - Arrived
        AND prc.prc_name IN (
            'CC GERIATRIC NEW', 'CC HOSPITAL FOLLOW UP NEW', 'CC LONG ESTABLISHED', 
            'CC MS CA EST', 'CC MS CA LONG ESTABLISHED', 'CC MS CA NEW', 'CC NEW', 
            'EST STEM CELL', 'ESTABLISHED', 'HOSPITAL FOLLOW UP NEW', 
            'LONG ESTABLISHED', 'NEW', 'POST OP', 'TRANSPLANT EST PATIENT', 
            'WEEKLY REVIEW', 'WOUND ESTABLISHED', 'BENIGN HEMATOLOGY ESTABLISHED', 
            'BENIGN HEMATOLOGY LONG', 'BENIGN HEMATOLOGY NEW', 
            'CC GERIATRIC LONG ESTABLISHED', 'HOSPITAL FOLLOW UP ESTABLISHED', 
            'MYCHART URO ESTABLISHED PT', 'MYCHART VIRTUAL VISIT', 
            'TRANSPLANT NEW PATIENT', 'VIRTUAL CHECK-IN (TELEPHONE)', 
            'VIRTUAL VISIT'
        )),
ranked_appts_2 as        
(SELECT pat_id,
        contact_date,
        pat_enc_csn_id,
        dx_id,
        ref_dx_id_inclusion,
        line,
        Coalesce(icd10_code,icd9_code) as code,
        dx_name,
        row_rank

FROM ranked_appts),
top_dx as (           
select 
                ap.pat_id,
                ap.contact_date,
                --MAX(case when ap.row_rank = 1 then ap.dx_id end) as Dx_ID1,
                MAX(case when ap.row_rank = 1 then ap.code end) as ICD10_Dx1,
                --MAX(case when ap.row_rank = 1 then ap.DX_NAME end) as Patient_Diagnosis1,
                --MAX(case when ap.row_rank = 2 then ap.dx_id end) as Dx_ID2,
                MAX(case when ap.row_rank = 2 then ap.code end) as ICD10_Dx2,
                --MAX(case when ap.row_rank = 2 then ap.DX_NAME end) as Patient_Diagnosis2,
                --MAX(case when ap.row_rank = 3 then ap.dx_id end) as Dx_ID3,
                MAX(case when ap.row_rank = 3 then ap.code end) as ICD10_Dx3
                --MAX(case when ap.row_rank = 3 then ap.DX_NAME end) as Patient_Diagnosis3
                
from ranked_appts_2 ap

Group by ap.pat_id,ap.contact_date)

SELECT 
    td.pat_id,
    MIN(td.contact_date)::date AS earliest_diagnosis_date,
    --td.dx_id1,
    td.icd10_dx1,
    --td.patient_diagnosis1,
    --td.dx_id2,
    td.icd10_dx2,
    --td.patient_diagnosis2,
    --td.dx_id3,
    td.icd10_dx3
    --td.patient_diagnosis3
    
FROM top_dx td

WHERE td.icd10_dx1 IS NOT NULL
GROUP BY td.pat_id, td.icd10_dx1,td.icd10_dx2,td.icd10_dx3;

CREATE INDEX IF NOT EXISTS idx_icd10_code_cleaned ON reference_b.edg_current_icd10 ((REPLACE(code, '.', '')));
CREATE INDEX IF NOT EXISTS idx_icd9_code_cleaned ON reference_b.edg_current_icd9 ((REPLACE(code, '.', '')));
CREATE INDEX IF NOT EXISTS idx_edg_dx_id ON reference_b.clarity_edg(dx_id);
CREATE INDEX IF NOT EXISTS idx_edg_record_type ON reference_b.clarity_edg(record_type_c);
--CREATE INDEX IF NOT EXISTS idx_naaccr_site_b_patient_key ON registry_b.fh_hb_naaccr_id(site_b_patient_key);

DROP TABLE IF EXISTS analytics_b.cancer_naaccr_dx_date;
CREATE TABLE analytics_b.cancer_naaccr_dx_date AS
WITH naaccr AS (
    SELECT 
        analytics_b.site_b_patient_key,
        analytics_b.pat_id,
        naa.date_of_diagnosis_n390,
        CASE 
            WHEN naa.date_of_diagnosis_n390 ~ '^\d{8}$' THEN TO_CHAR(TO_DATE(naa.date_of_diagnosis_n390, 'YYYYMMDD'), 'YYYY-MM-DD')
            WHEN naa.date_of_diagnosis_n390 ~ '^\d{6}$' THEN TO_CHAR(TO_DATE(naa.date_of_diagnosis_n390 || 'B0016', 'YYYYMMDD'), 'YYYY-MM-DD')
            ELSE NULL 
        END AS formatted_date_of_diagnosis_n390,
        naa.primary_site_n400,
        naa.secondary_diagnosis1_n3780,
        naa.secondary_diagnosis2_n3782
        
    FROM analytics_b.cancer_patient_demographic aya
    LEFT JOIN registry_b.fh_hb_naaccr_id naa 
        ON analytics_b.site_b_patient_key = naa.site_b_patient_key
),
-- Deduplicated, indexed code lookup for ICD-10
icd10_codes AS (
    SELECT DISTINCT
        REPLACE(icd10.code, '.', '') AS cleaned_column,
        edg.dx_name,
        icd10.code
    FROM reference_b.edg_current_icd10 icd10
    JOIN reference_b.clarity_edg edg 
        ON icd10.dx_id = edg.dx_id
    WHERE edg.record_type_c = '2'
),
-- Deduplicated, indexed code lookup for ICD-9
icd9_codes AS (
    SELECT DISTINCT
        REPLACE(icd9.code, '.', '') AS cleaned_column,
        edg.dx_name,
        icd9.code
    FROM reference_b.edg_current_icd9 icd9
    JOIN reference_b.clarity_edg edg 
        ON icd9.dx_id = edg.dx_id
    WHERE edg.record_type_c = '2'
)

SELECT 
    naa.*,
   
    COALESCE(i10_primary.code, i9_primary.code) AS primary_dx_code_10,
    COALESCE(i10_sec1.code, i9_sec1.code) AS secondary1_dx_code_10,
    COALESCE(i10_sec2.code, i9_sec2.code) AS secondary2_dx_code_10


FROM naaccr naa

-- ICD-10 joins
LEFT JOIN icd10_codes i10_primary ON naa.primary_site_n400 = i10_primary.cleaned_column
LEFT JOIN icd10_codes i10_sec1    ON naa.secondary_diagnosis1_n3780 = i10_sec1.cleaned_column
LEFT JOIN icd10_codes i10_sec2    ON naa.secondary_diagnosis2_n3782 = i10_sec2.cleaned_column

-- ICD-9 joins
LEFT JOIN icd9_codes i9_primary   ON naa.primary_site_n400 = i9_primary.cleaned_column
LEFT JOIN icd9_codes i9_sec1      ON naa.secondary_diagnosis1_n3780 = i9_sec1.cleaned_column
LEFT JOIN icd9_codes i9_sec2      ON naa.secondary_diagnosis2_n3782 = i9_sec2.cleaned_column

Where naa.primary_site_n400 is not null;

DROP TABLE IF EXISTS analytics_b.cancer_prime_onc;
CREATE TABLE analytics_b.cancer_prime_onc AS

SELECT pop.pat_id,
       stag.sign_datetime,
       emp.name AS primary_oncologist,
       ROW_NUMBER()OVER (PARTITION BY pop.pat_id ORDER BY stag.sign_datetime DESC) AS rank

FROM analytics_b.cancer_patient_demographic AS pop
JOIN source_b.dm_cancer_problem AS cpl ON pop.pat_id = cpl.pat_id
JOIN source_b.v_cancer_staging AS stag ON cpl.problem_list_id = stag.problem_list_id AND stag.most_recent_contact_yn = 'Y'
JOIN reference_b.clarity_emp AS emp ON stag.sign_user_id = emp.user_id;

DROP TABLE IF EXISTS analytics_b.cancer_research_reporting;
CREATE TABLE analytics_b.cancer_research_reporting AS

SELECT pop.pat_id, 
       rsh.research_study_name, 
       rsh.study_type_c, 
       enroll.enroll_end_dt

FROM analytics_b.cancer_patient_demographic AS pop
JOIN source_b.enroll_info AS enroll ON pop.pat_id = enroll.pat_id
JOIN source_b.rsh_research_info AS rsh ON enroll.research_study_id = rsh.research_id::TEXT;
--LEFT JOIN reference_b.zc_study_type AS st ON rsh.study_type_c = st.study_type_c::TEXT;

/* Treatment plan summary: keep one row per patient, count distinct plans,
   and coalesce plan names so the final table does not need Treatment Name 1/2/3 columns. */
DROP TABLE IF EXISTS analytics_b.cancer_treatment_plan_summary;
CREATE TABLE analytics_b.cancer_treatment_plan_summary AS

SELECT
    pop.pat_id,
    COUNT(DISTINCT tpl.treatment_plan_id) AS treatment_plan_count,
    STRING_AGG(DISTINCT COALESCE(NULLIF(tpl.plan_name, ''), tpl.treatment_plan_id::text), '; ')
        AS treatment_plan_names,
    MIN(tpl.plan_created_datetime)::date AS first_treatment_plan_order_date
FROM analytics_b.cancer_patient_demographic AS pop
JOIN source_b.v_onc_treatment_plan_orders AS tpl
    ON pop.pat_id = tpl.pat_id
WHERE tpl.plan_record_type_c = '1'
GROUP BY pop.pat_id;

--Oral Chemos               
Drop table if exists analytics_b.cancer_oral_chemo_startdate;
Create table analytics_b.cancer_oral_chemo_startdate as

With oral_chemo as
(Select om.pat_id
     , om.ORDERING_DATE 
     , cm.Name as medication_name
     , zr.name as route
     , ROW_NUMBER()over(partition by p.pat_id order by ordering_date ASC) as row
     
From analytics_b.cancer_patient_demographic p
Join source_b.order_med om on p.PAT_ID = om.PAT_ID 
Left join reference_b.CLARITY_MEDICATION cm on om.MEDICATION_ID = cm.MEDICATION_ID
Left join reference_b.GROUPER_MED_RECS gmr on cm.MEDICATION_ID = gmr.EXP_MEDS_LIST_ID
Left Join reference_b.zc_admin_route zr on om.med_route_c=zr.med_route_c
                                 
where gmr.GROUPER_ID = 'B0017'-- 400164 - ERX GENERAL OCM INITIATING CANCER THERAPIES
                                 --and order_med.pat_id = 'Z1182929'
and ORDER_STATUS_C <> '4' --canceled
and om.MED_ROUTE_C = '15') --oral

Select *

From oral_chemo

Where row='1';

--------IV Chemos
Drop table if exists analytics_b.cancer_iv_chemo_startdate;
Create table analytics_b.cancer_iv_chemo_startdate as

With iv_chemo as
(Select      p.pat_id
            ,mai.TAKEN_TIME
            ,cm.Name as medication_name
            ,'IV' as Type
            ,ROW_NUMBER()over(partition by p.pat_id order by taken_time) as row

from analytics_b.cancer_patient_demographic p
join source_b.V_ONC_TREATMENT_PLAN_ORDERS tpl on p.pat_id = tpl.PAT_ID 
join source_b.MAR_ADMIN_INFO mai on tpl.order_id = mai.ORDER_MED_ID
Join source_b.order_med om on mai.order_med_id = om.order_med_id
Left join reference_b.CLARITY_MEDICATION cm on om.MEDICATION_ID = cm.MEDICATION_ID

where PLAN_RECord_TYPe_C = '1'--treatment plan
and ORDER_CATEGORY_NAME = 'Chemotherapy'
and (MAR_ACTION_C in ('1','6')--given, new bag
or MAR_ACTION_C is null))

Select pat_id,
       taken_time as start_date,
       medication_name,
       type as route,
       row
       
From iv_chemo

Where row='1'; 

Drop table if exists analytics_b.cancer_chemo_combine_startdate;
Create table analytics_b.cancer_chemo_combine_startdate as

With chemo as (
Select *
From analytics_b.cancer_iv_chemo_startdate

Union all

Select *
From analytics_b.cancer_oral_chemo_startdate)

Select pat_id,
       start_date,
       medication_name,
       route,
       row_number()over(partition by pat_id order by start_date asc) as row
       
From chemo
;


Drop table if exists analytics_b.cancer_rad_startdate;
Create table analytics_b.cancer_rad_startdate as

With convert_start_date as
(select distinct      
        p.pat_id
        ,(CASE
    -- Handle MMDDYYYY (Allow 7 or 8 digits)
    WHEN ordr.ord_value ~ '^[0-9]{7,8}$' THEN
        TO_DATE(LPAD(ordr.ord_value, 8, '0'), 'MMDDYYYY')
 
    -- Handle YYYY-MM-DD
    WHEN ordr.ord_value ~ '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$' THEN
        ordr.ord_value::DATE -- 2015-07-23
 
    -- Handle MM/DD/YYYY (with 2-digit year handling)
    WHEN ordr.ord_value ~ '^[0-9]{1,2}(\/)[0-9]{1,2}\/([0-9]{2})$' THEN
        TO_DATE(ordr.ord_value, 'MM/DD/YY') -- 04/18/23
 
    -- Handle MM-DD-YYYY (with 2-digit year handling)
    WHEN ordr.ord_value ~ '^[0-9]{1,2}(-)[0-9]{1,2}-([0-9]{2})$' THEN
        TO_DATE(ordr.ord_value, 'MM-DD-YY') -- 04-18-23
 
    -- Handle DD-MM-YYYY
    WHEN ordr.ord_value ~ '^[0-9]{1,2}-[0-9]{1,2}-[0-9]{2,4}$' THEN
        TO_DATE(ordr.ord_value, 'DD-MM-YYYY') -- 23-07-2015
        
    -- Handle MM/DD/YYYY (with 4-digit year handling)
    WHEN ordr.ord_value ~ '^[0-9]{1,2}(\/)[0-9]{1,2}\/([0-9]{2,4})$' THEN
        TO_DATE(ordr.ord_value, 'MM/DD/YYYY') -- 04/18/23
 
    ELSE NULL -- Handle unexpected formats
END)::date AS converted_date
        ,ordr.ord_value
        
from analytics_b.cancer_patient_demographic p
join source_b.order_proc op on p.PAT_ID = op.pat_id
join source_b.order_results ordr on ordr.ORDER_PROC_ID = op.ORDER_PROC_ID

where COMPONENT_ID='B0018' -- RADONC MSQ TREATMENT START

order by p.pat_id)

Select pat_id,
       converted_date,
       ord_value,
       ROW_NUMBER()OVER (PARTITION BY pat_id ORDER BY converted_date ASC) AS row
       
From convert_start_date
;   

Drop table if exists analytics_b.cancer_rad_enddate;
Create table analytics_b.cancer_rad_enddate as

With convert_end_date as
(select distinct      
        p.pat_id
        ,(CASE
    -- Handle MMDDYYYY (Allow 7 or 8 digits)
    WHEN ordr.ord_value ~ '^[0-9]{7,8}$' THEN
        TO_DATE(LPAD(ordr.ord_value, 8, '0'), 'MMDDYYYY')
 
    -- Handle YYYY-MM-DD
    WHEN ordr.ord_value ~ '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$' THEN
        ordr.ord_value::DATE -- 2015-07-23
 
    -- Handle MM/DD/YYYY (with 2-digit year handling)
    WHEN ordr.ord_value ~ '^[0-9]{1,2}(\/)[0-9]{1,2}\/([0-9]{2})$' THEN
        TO_DATE(ordr.ord_value, 'MM/DD/YY') -- 04/18/23
 
    -- Handle MM-DD-YYYY (with 2-digit year handling)
    WHEN ordr.ord_value ~ '^[0-9]{1,2}(-)[0-9]{1,2}-([0-9]{2})$' THEN
        TO_DATE(ordr.ord_value, 'MM-DD-YY') -- 04-18-23
 
    -- Handle DD-MM-YYYY
    WHEN ordr.ord_value ~ '^[0-9]{1,2}-[0-9]{1,2}-[0-9]{2,4}$' THEN
        TO_DATE(ordr.ord_value, 'DD-MM-YYYY') -- 23-07-2015
        
    -- Handle MM/DD/YYYY (with 4-digit year handling)
    WHEN ordr.ord_value ~ '^[0-9]{1,2}(\/)[0-9]{1,2}\/([0-9]{2,4})$' THEN
        TO_DATE(ordr.ord_value, 'MM/DD/YYYY') -- 04/18/23
 
    ELSE NULL -- Handle unexpected formats
END)::date AS converted_date
        ,ordr.ord_value
                                
from analytics_b.cancer_patient_demographic p
join source_b.order_proc op on p.PAT_ID = op.pat_id
join source_b.order_results ordr on ordr.ORDER_PROC_ID = op.ORDER_PROC_ID

where COMPONENT_ID='B0019' -- RADONC MSQ TREATMENT END DATE

order by p.pat_id)

Select pat_id,
       converted_date,
       ord_value,
       ROW_NUMBER()OVER (PARTITION BY pat_id ORDER BY converted_date DESC) AS row
       
From convert_end_date; 

DROP TABLE IF EXISTS analytics_b.cancer_sw_referral_startdate;
CREATE TABLE analytics_b.cancer_sw_referral_startdate AS   

select pop.PAT_ID,
       MAX(CASE WHEN ORD_QUEST_ID = 'B0020' THEN 'Y' ELSE 'N' END) as Social_Work_Referral,
       ordering_date,
       ORD_QUEST_RESP as SW_Referral_Response,
       ORD_QUEST_CMT as SW_Referral_Comment,
       ROW_NUMBER()OVER (PARTITION BY pop.pat_id ORDER BY ordering_date ASC) AS rank

from analytics_b.cancer_patient_demographic pop
join source_b.ORDER_PROC ord on ord.PAT_ID = pop.PAT_ID 
join source_b.ORD_SPEC_QUEST q on q.ORDER_ID = ord.ORDER_PROC_ID
join reference_b.CL_QQUEST qq on qq.QUEST_ID = q.ORD_QUEST_ID

where ORD_QUEST_ID in   ('B0020') --Social Work Referral
GROUP BY        pop.PAT_ID, ordering_date, ORD_QUEST_resp, ord_quest_cmt;

DROP TABLE IF EXISTS analytics_b.cancer_psych_referral_startdate;
CREATE TABLE analytics_b.cancer_psych_referral_startdate AS

select    pop.pat_id,
          pop.site_b_patient_key,
          ref.referral_id,
          ref.entry_date as entry_date,
          eap.PROC_NAME,
          ref.SCHED_STATUS_C,
          --stat.Name as Referral_Status,
          ROW_NUMBER() over (partition by pop.pat_id order by ref.entry_date asc) as rank
                                        
from analytics_b.cancer_patient_demographic pop
join source_b.REFERRAL ref on ref.PAT_ID = pop.PAT_ID --and ref.ENTRY_DATE between p.Visit_Date and dateadd(mm,3,p.Visit_Date)
join source_b.REFERRAL_PX px on px.REFERRAL_ID = ref.REFERRAL_ID 
join reference_b.CLARITY_EAP eap on eap.PROC_ID = px.PX_ID and px.PX_ID = 'B0021'
--left join reference_b.ZC_SCHED_STATUS stat on stat.SCHED_STATUS_C = ref.SCHED_STATUS_C 
;

DROP TABLE IF EXISTS analytics_b.cancer_reprod_referral_startdate;
CREATE TABLE analytics_b.cancer_reprod_referral_startdate AS

select distinct                pop.pat_id,
                               pop.site_b_patient_key,
                               ref.referral_id,
                               ref.entry_date,
                               ref.PROV_SPEC_C,
                               ref.SCHED_STATUS_C,
                               --stat.NAME as Schedule_Status,
                               --spec.Name as Specialty_Name,
                               dep.Department_Name,
                               ROW_NUMBER() over (partition by pop.pat_id order by ref.entry_date asc) as rank

from analytics_b.cancer_patient_demographic pop
join source_b.referral ref on ref.pat_id = pop.pat_id --and ref.entry_date >= p.visit_date
--join Clarity.ORG_FILTER.ZC_RFL_PROV_SPEC spec on spec.PROV_SPEC_C  = ref.PROV_SPEC_C
left join reference_b.clarity_dep dep on dep.department_id = ref.REFD_TO_DEPT_ID
--left join reference_b.ZC_SCHED_STATUS stat on stat.SCHED_STATUS_C = ref.SCHED_STATUS_C
                                        
where ref.PROV_SPEC_C = 'B0022'

Group by pop.pat_id,pop.site_b_patient_key,ref.referral_id,ref.entry_date,ref.prov_spec_c,ref.sched_status_C,dep.department_name;

DROP TABLE IF EXISTS analytics_b.cancer_genetics_referral_startdate;
CREATE TABLE analytics_b.cancer_genetics_referral_startdate AS

select distinct                pop.pat_id,
                               pop.site_b_patient_key,
                               ref.referral_id,
                               ref.entry_date,
                               ref.PROV_SPEC_C,
                               ref.SCHED_STATUS_C,
                               --stat.NAME as Schedule_Status,
                               --spec.Name as Specialty_Name,
                               dep.Department_Name,
                               ROW_NUMBER() over (partition by pop.pat_id order by ref.entry_date asc) as rank

from analytics_b.cancer_patient_demographic pop
join source_b.referral ref on ref.pat_id = pop.pat_id --and ref.entry_date >= p.visit_date
--join Clarity.ORG_FILTER.ZC_RFL_PROV_SPEC spec on spec.PROV_SPEC_C  = ref.PROV_SPEC_C
left join reference_b.clarity_dep dep on dep.department_id = ref.REFD_TO_DEPT_ID
--left join reference_b.ZC_SCHED_STATUS stat on stat.SCHED_STATUS_C = ref.SCHED_STATUS_C
                                        
where ref.PROV_SPEC_C = 'B0023'

Group by pop.pat_id,pop.site_b_patient_key,ref.referral_id,ref.entry_date,ref.prov_spec_c,ref.sched_status_C,dep.department_name;

CREATE INDEX IF NOT EXISTS referral_idx ON source_b.referral_mv (pat_id, referral_id);
CREATE INDEX IF NOT EXISTS referralpx_idx ON source_b.referral_px_mv (px_id, referral_id);
CREATE INDEX IF NOT EXISTS demographic_idx ON analytics_b.cancer_patient_demographic (pat_id);
ANALYZE source_b.referral (pat_id,referral_id); 
ANALYZE source_b.referral_px (px_id,referral_id); 
ANALYZE analytics_b.cancer_patient_demographic (pat_id);

DROP TABLE IF EXISTS analytics_b.cancer_nutrition_referral_startdate;
CREATE TABLE analytics_b.cancer_nutrition_referral_startdate AS

select    pop.pat_id,
          pop.site_b_patient_key,
          ref.referral_id,
          ref.entry_date as entry_date,
          eap.PROC_NAME,
          ref.SCHED_STATUS_C,
          --stat.Name as Referral_Status,
          ROW_NUMBER() over (partition by pop.pat_id order by ref.entry_date asc) as rank
                                        
from analytics_b.cancer_patient_demographic pop
join source_b.REFERRAL ref on ref.PAT_ID = pop.PAT_ID --and ref.ENTRY_DATE between p.Visit_Date and dateadd(mm,3,p.Visit_Date)
join source_b.REFERRAL_PX px on px.REFERRAL_ID = ref.REFERRAL_ID 
join reference_b.CLARITY_EAP eap on eap.PROC_ID = px.PX_ID 
Where px.PX_ID in ('B0024','B0025')
--left join reference_b.ZC_SCHED_STATUS stat on stat.SCHED_STATUS_C = ref.SCHED_STATUS_C 
;

DROP TABLE IF EXISTS analytics_b.cancer_childlife_startdate;
CREATE TABLE analytics_b.cancer_childlife_startdate AS

select    pop.pat_id,
          pop.site_b_patient_key,
          pe.CONTACT_DATE as Child_Life_Contact_Date,
          ROW_NUMBER() over (partition by pop.pat_id order by pe.contact_date asc) as rank

from analytics_b.cancer_patient_demographic pop
join source_b.PAT_ENC pe On pop.pat_id=pe.pat_id
join reference_b.CLARITY_SER ser on ser.PROV_ID = pe.VISIT_PROV_ID

where ser.PROV_TYPE = 'Child Life Specialist';

-- Site-specific workflow note removed for portfolio use.
Drop table if exists analytics_b.cancer_fertility_SDE;
Create table analytics_b.cancer_fertility_SDE as

Select sde.element_id,sde.cur_value_datetime,sde.pat_link_id,sev.smrtdta_elem_value
From analytics_b.cancer_patient_demographic p
Join source_b.SMRTDTA_ELEM_DATA sde On p.pat_id=sde.pat_link_id
Join source_b. smrtdta_elem_value sev On sde.hlv_id=sev.hlv_id
Where sde.Element_ID in ('EPIC#32168','EPIC#31000234874','EPIC#31000234867','EPIC#31000204148');

-- Site-specific workflow note removed for portfolio use.
Drop table if exists analytics_b.cancer_fertility_STXT_note;
Create table analytics_b.cancer_fertility_STXT_note as

Select ns.smarttexts_id,
       p.pat_id,
       hno.date_of_servic_dttm,
       hno.update_date,
       nc.contact_date_real,
       nc.note_text_ts,
       nc.note_text_comb
       
From source_b.NOTE_SMARTTEXT_IDS ns 
Join notes_b.hno_info hno On ns.note_id=hno.note_id
Join analytics_b.cancer_patient_demographic p On hno.pat_id=p.pat_id
Join notes_b.hno_note_text_comb nc On ns.note_id=nc.note_id
Where ns.SMARTTEXTS_ID in ('B0026', 'B0027', --chemo education note
                                    'B0028'); --rad onc tx note
-- Production role-setting command removed for portfolio use.
DROP TABLE IF EXISTS analytics_b.cancer_fertility_combine;
CREATE TABLE analytics_b.cancer_fertility_combine AS   

With smtxt_note as 
(Select pat_id,
        date_of_servic_dttm

From analytics_b.cancer_fertility_stxt_note

Where note_text_comb ILIKE 
'%Referral for assistance with fertility concerns desired by patient:%yes%'),

sde as
(Select pat_link_id,
       cur_value_datetime
       
From analytics_b.cancer_fertility_sde
Where smrtdta_elem_value not like '%deferred%' and
      smrtdta_elem_value not like '%declined%' and
      smrtdta_elem_value not like '%not clinically indicated%'), 
   
distinct_join as
(Select *
From smtxt_note

union all

Select *
From sde)

Select Distinct j.pat_id,
                j.date_of_servic_dttm as fertility_referral_date,
                ROW_NUMBER() over (partition by pop.pat_id order by j.date_of_servic_dttm asc) as rank

From analytics_b.cancer_patient_demographic pop
Join distinct_join j On pop.pat_id=j.pat_id; 

DROP TABLE IF EXISTS analytics_b.cancer_palliative_care;
CREATE TABLE analytics_b.cancer_palliative_care AS   

With palliative_order as
(Select op.order_proc_id,
       pop.pat_id,
       op.pat_enc_csn_id,
       op.ordering_date
       
From analytics_b.cancer_patient_demographic pop
Join source_b.order_proc op On pop.pat_id=op.pat_id

Where proc_id='B0029'),

palliative_quest as 
(Select po.*,
       qq.quest_name,
       os.*

From palliative_order po
Join source_b.ord_spec_quest os On po.order_proc_id=os.order_id
Left join reference_b.cl_qquest qq On qq.quest_id=os.ord_quest_id
Where os.ord_quest_id in ('B0030','B0031','B0032','B0033','B0034'))

Select distinct pat_id,
                ordering_date,
                ROW_NUMBER() over (partition by pat_id order by ordering_date asc) as rank
                
From palliative_quest
Where ord_quest_resp is not null;

DROP TABLE IF EXISTS analytics_b.cancer_combine_wo_dx_name;
CREATE TABLE analytics_b.cancer_combine_wo_dx_name AS

WITH encounter_counts AS (
    SELECT DISTINCT
        pat_id,
        COUNT(DISTINCT pat_enc_csn_id) AS number_of_visits
    FROM 
        analytics_b.cancer_encounters
    GROUP BY 
        pat_id
)

SELECT DISTINCT
       e.pat_id,
       d.patient_display_name,
       ec.number_of_visits,
       d.site_b_patient_key,
       d.birth_date,
       d.sex,
       d.primary_race,
       d.ethnicity,
       d.city,
       d.zip,
       d.death_date,
       d.pcp,
       d.pcp_location,
       d.pcp_location_type,
       d.financial_class_name,
       CASE WHEN dd.formatted_date_of_diagnosis_n390 IS NOT NULL AND dd.primary_dx_code_10 IS NOT NULL 
        THEN dd.formatted_date_of_diagnosis_n390
        ELSE dx.earliest_diagnosis_date::text END AS diagnosis_date,
       (
           EXTRACT(DAY FROM (
               CASE WHEN dd.formatted_date_of_diagnosis_n390 IS NOT NULL AND dd.primary_dx_code_10 IS NOT NULL
                    THEN dd.formatted_date_of_diagnosis_n390::timestamp
                    ELSE dx.earliest_diagnosis_date::timestamp
               END - d.birth_date::timestamp
           )) / 365.25
       )::numeric AS patient_age_at_diagnosis,
       CASE WHEN dd.formatted_date_of_diagnosis_n390 IS NOT NULL AND dd.primary_dx_code_10 IS NOT NULL 
        THEN dd.primary_dx_code_10 ELSE dx.icd10_dx1 END AS dx_1_code,
       CASE WHEN dd.formatted_date_of_diagnosis_n390 IS NOT NULL AND dd.primary_dx_code_10 IS NOT NULL 
        THEN dd.secondary1_dx_code_10 ELSE dx.icd10_dx2 END AS dx_2_code,
       CASE WHEN dd.formatted_date_of_diagnosis_n390 IS NOT NULL AND dd.primary_dx_code_10 IS NOT NULL 
        THEN dd.secondary2_dx_code_10 ELSE dx.icd10_dx3 END AS dx_3_code,
       p.primary_oncologist AS primary_oncologist,
       CASE 
            WHEN r.study_type_c = 'B0035' THEN 'Interventional'
            WHEN r.study_type_c = 'B0036' THEN 'Observational'
            WHEN r.study_type_c = 'B0037' THEN 'Expanded Access'
            ELSE NULL 
       END AS study_type,
       r.research_study_name,
       tp.treatment_plan_count,
       tp.treatment_plan_names,
       tp.first_treatment_plan_order_date,
       cs.start_date AS chemo_start_date,
       cs.route as chemo_route_type,
       cr.ord_value AS radiation_start_date,
       nr.entry_date AS nutrition_referral_date,
       cl.Child_Life_Contact_Date AS child_life_referral_date,
       rr.entry_date AS reproductive_med_referral_date,
       sw.ordering_date AS social_work_referral_date,
       gr.entry_date AS genetics_referral_date,
       pr.entry_date AS psychology_referral_date,
       f.fertility_referral_date,
       pa.ordering_date as palliative_care_referral_date
       
       
FROM analytics_b.cancer_encounters e
JOIN analytics_b.cancer_patient_demographic d ON e.pat_id = d.pat_id
LEFT JOIN (SELECT DISTINCT ON (pat_id)
           pat_id,
           formatted_date_of_diagnosis_n390,
           primary_dx_code_10,
           secondary1_dx_code_10,
           secondary2_dx_code_10
           
    FROM analytics_b.cancer_naaccr_dx_date
    ORDER BY pat_id,
             CASE WHEN formatted_date_of_diagnosis_n390 IS NOT NULL THEN 1 ELSE 2 END
) dd ON d.pat_id = dd.pat_id
-- Get one row per patient from cancer_dx
LEFT JOIN (SELECT DISTINCT ON (pat_id) *
    FROM analytics_b.cancer_dx
    ORDER BY pat_id
) dx ON d.pat_id = dx.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_prime_onc ORDER BY pat_id, rank
) p ON p.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_chemo_combine_startdate ORDER BY pat_id, row
) cs ON cs.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_rad_startdate ORDER BY pat_id, row
) cr ON cr.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_sw_referral_startdate ORDER BY pat_id, rank
) sw ON sw.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_psych_referral_startdate ORDER BY pat_id, rank
) pr ON pr.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_childlife_startdate ORDER BY pat_id, rank
) cl ON cl.pat_id = p.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_nutrition_referral_startdate ORDER BY pat_id, rank
) nr ON nr.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_genetics_referral_startdate ORDER BY pat_id, rank
) gr ON gr.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_reprod_referral_startdate ORDER BY pat_id, rank
) rr ON rr.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_fertility_combine ORDER BY pat_id, rank=1
) f ON f.pat_id = d.pat_id
LEFT JOIN (
    SELECT DISTINCT ON (pat_id) * FROM analytics_b.cancer_palliative_care ORDER BY pat_id, rank=1
) pa ON pa.pat_id = d.pat_id
LEFT JOIN analytics_b.cancer_treatment_plan_summary tp ON d.pat_id = tp.pat_id
LEFT JOIN analytics_b.cancer_research_reporting r ON d.pat_id = r.pat_id
LEFT JOIN encounter_counts ec ON e.pat_id = ec.pat_id;

DROP TABLE IF EXISTS analytics_b.fh_cancer_reporting;

CREATE TABLE analytics_b.fh_cancer_reporting AS

SELECT DISTINCT
    d.pat_id,
    d.patient_display_name,
    d.number_of_visits,
    d.site_b_patient_key,
    d.birth_date,
    d.sex,
    d.primary_race,
    d.ethnicity,
    d.city,
    d.zip,
    d.death_date,
    d.pcp,
    d.pcp_location,
    d.pcp_location_type,
    d.financial_class_name,
    d.diagnosis_date,
    d.patient_age_at_diagnosis,
    d.dx_1_code,

    CASE 
        WHEN edg10_1.record_type_c = '2' THEN edg10_1.dx_name
        WHEN edg9_1.record_type_c = '2' THEN edg9_1.dx_name
        WHEN edg10_1.record_type_c IS NULL 
         AND edg9_1.record_type_c IS NULL THEN mi1.description
        ELSE NULL
    END AS dx_1_name,

    d.dx_2_code,

    CASE 
        WHEN edg10_2.record_type_c = '2' THEN edg10_2.dx_name
        WHEN edg9_2.record_type_c = '2' THEN edg9_2.dx_name
        WHEN edg10_2.record_type_c IS NULL 
         AND edg9_2.record_type_c IS NULL THEN mi2.description
        ELSE NULL
    END AS dx_2_name,

    d.dx_3_code,

    CASE 
        WHEN edg10_3.record_type_c = '2' THEN edg10_3.dx_name
        WHEN edg9_3.record_type_c = '2' THEN edg9_3.dx_name
        WHEN edg10_3.record_type_c IS NULL 
         AND edg9_3.record_type_c IS NULL THEN mi3.description
        ELSE NULL
    END AS dx_3_name,

    d.primary_oncologist,

    COUNT(DISTINCT d.research_study_name) AS research_study_total_count,

    COUNT(DISTINCT d.research_study_name) FILTER (
        WHERE d.study_type = 'Interventional'
    ) AS interventional_study_count,

    COUNT(DISTINCT d.research_study_name) FILTER (
        WHERE d.study_type = 'Expanded Access'
    ) AS expanded_access_study_count,

    COUNT(DISTINCT d.research_study_name) FILTER (
        WHERE d.study_type = 'Observational'
    ) AS observational_study_count,

    COUNT(DISTINCT d.research_study_name) FILTER (
        WHERE d.research_study_name IS NOT NULL
          AND d.study_type IS NULL
    ) AS other_study_count,

    STRING_AGG(
        DISTINCT d.research_study_name,
        ' | '
        ORDER BY d.research_study_name
    ) AS research_study_name,

    STRING_AGG(
        DISTINCT CASE
            WHEN d.research_study_name IS NOT NULL 
             AND d.study_type IS NULL THEN 'Other'
            ELSE d.study_type
        END,
        ' | '
        ORDER BY CASE
            WHEN d.research_study_name IS NOT NULL 
             AND d.study_type IS NULL THEN 'Other'
            ELSE d.study_type
        END
    ) FILTER (
        WHERE d.research_study_name IS NOT NULL
    ) AS study_type,

    d.chemo_start_date,
    d.chemo_route_type,
    d.radiation_start_date,
    d.nutrition_referral_date,
    d.child_life_referral_date,
    d.reproductive_med_referral_date,
    d.social_work_referral_date,
    d.genetics_referral_date,
    d.psychology_referral_date,
    d.fertility_referral_date,
    d.palliative_care_referral_date

FROM analytics_b.cancer_combine_wo_dx_name d

LEFT JOIN reference_b.clarity_edg edg10_1 
    ON d.dx_1_code = edg10_1.current_icd10_list 
   AND edg10_1.record_type_c = '2'

LEFT JOIN reference_b.clarity_edg edg9_1 
    ON d.dx_1_code = edg9_1.current_icd9_list 
   AND edg10_1.record_type_c IS NULL 
   AND edg9_1.record_type_c = '2'

LEFT JOIN analytics_b.missing_icd mi1 
    ON d.dx_1_code = mi1.icd_code 
   AND edg10_1.record_type_c IS NULL 
   AND edg9_1.record_type_c IS NULL

LEFT JOIN reference_b.clarity_edg edg10_2 
    ON d.dx_2_code = edg10_2.current_icd10_list 
   AND edg10_2.record_type_c = '2'

LEFT JOIN reference_b.clarity_edg edg9_2 
    ON d.dx_2_code = edg9_2.current_icd9_list 
   AND edg10_2.record_type_c IS NULL 
   AND edg9_2.record_type_c = '2'

LEFT JOIN analytics_b.missing_icd mi2 
    ON d.dx_2_code = mi2.icd_code 
   AND edg10_2.record_type_c IS NULL 
   AND edg9_2.record_type_c IS NULL

LEFT JOIN reference_b.clarity_edg edg10_3 
    ON d.dx_3_code = edg10_3.current_icd10_list 
   AND edg10_3.record_type_c = '2'

LEFT JOIN reference_b.clarity_edg edg9_3 
    ON d.dx_3_code = edg9_3.current_icd9_list 
   AND edg10_3.record_type_c IS NULL 
   AND edg9_3.record_type_c = '2'

LEFT JOIN analytics_b.missing_icd mi3 
    ON d.dx_3_code = mi3.icd_code 
   AND edg10_3.record_type_c IS NULL 
   AND edg9_3.record_type_c IS NULL

WHERE d.patient_age_at_diagnosis >= 15
  AND d.patient_age_at_diagnosis < 50
  AND d.diagnosis_date::date>= DATE '2015-01-01'

GROUP BY
    d.pat_id,
    d.patient_display_name,
    d.number_of_visits,
    d.site_b_patient_key,
    d.birth_date,
    d.sex,
    d.primary_race,
    d.ethnicity,
    d.city,
    d.zip,
    d.death_date,
    d.pcp,
    d.pcp_location,
    d.pcp_location_type,
    d.financial_class_name,
    d.diagnosis_date,
    d.patient_age_at_diagnosis,
    d.dx_1_code,
    d.dx_2_code,
    d.dx_3_code,
    d.primary_oncologist,
    d.chemo_start_date,
    d.chemo_route_type,
    d.radiation_start_date,
    d.nutrition_referral_date,
    d.child_life_referral_date,
    d.reproductive_med_referral_date,
    d.social_work_referral_date,
    d.genetics_referral_date,
    d.psychology_referral_date,
    d.fertility_referral_date,
    d.palliative_care_referral_date,
    edg10_1.record_type_c,
    edg10_1.dx_name,
    edg10_2.record_type_c,
    edg10_2.dx_name,
    edg10_3.record_type_c,
    edg10_3.dx_name,
    edg9_1.record_type_c,
    edg9_1.dx_name,
    edg9_2.record_type_c,
    edg9_2.dx_name,
    edg9_3.record_type_c,
    edg9_3.dx_name,
    mi1.description,
    mi2.description,
    mi3.description;
--removed as not sending LDS to analytics server
DROP TABLE IF EXISTS analytics_b.fh_lds_cancer_reporting;
CREATE TABLE analytics_b.fh_lds_cancer_reporting AS

Select Distinct
       svp.patient_num,
       number_of_visits,
       birth_date,
       sex,
       primary_race,
       ethnicity,
       city,
       zip,
       death_date,
       pcp,
       pcp_location,
       financial_class_name,
       diagnosis_date,
       dx_1_code,
       dx_1_name,
       dx_2_code,
       dx_2_name,
       dx_3_code,
       dx_3_name,
       primary_oncologist,
       study_type,
       --STRING_AGG(DISTINCT research_study_name, ', ' ORDER BY research_study_name) AS research_study_name,
       chemo_start_date,
       chemo_route_type,
       radiation_start_date,
       nutrition_referral_date,
       child_life_referral_date,
       reproductive_med_referral_date,
       social_work_referral_date,
       genetics_referral_date,
       psychology_referral_date,
       fertility_referral_date,
       palliative_care_referral_date

From analytics_b.fh_cancer_reporting
Join identity_b.patient_crosswalk svp On fh_cancer_reporting.pat_id=svp.pat_id

Group by 
svp.patient_num,
       number_of_visits,
       birth_date,
       sex,
       primary_race,
       ethnicity,
       city,
       zip,
       death_date,
       pcp,
       pcp_location,
       financial_class_name,
       diagnosis_date,
       dx_1_code,
       dx_1_name,
       dx_2_code,
       dx_2_name,
       dx_3_code,
       dx_3_name,
       primary_oncologist,
       study_type,
       chemo_start_date,
       chemo_route_type,
       radiation_start_date,
       nutrition_referral_date,
       child_life_referral_date,
       reproductive_med_referral_date,
       social_work_referral_date,
       genetics_referral_date,
       psychology_referral_date,
       fertility_referral_date,
       palliative_care_referral_date
