# Hospital Workflow Crosswalk

| Clinical concept | Hospital A workflow | Hospital B workflow | Harmonized output |
|---|---|---|---|
| Initial cohort | Cancer registry and cancer-problem records; separate deceased-patient registry path | Oncology department groupers and qualifying encounters | One patient-level AYA oncology cohort |
| Diagnosis source | Cancer problem table, problem list, diagnosis terminology, treatment-summary notes | Registry/NAACCR diagnosis when valid; encounter diagnosis fallback | Diagnosis date, age at diagnosis, up to three diagnosis codes/names |
| Age criteria | Pediatric/AYA cancer logic with final shared age filter | Final cohort driven by age at diagnosis 15–49 | Standardized age-at-diagnosis field |
| Deceased patients | Separate registry membership and problem-list workflow | Mortality source joined to the encounter-derived cohort | Death date and vital-status support |
| Primary oncologist | Most recently signed staging form, including deceased-patient path | Most recently signed staging form | Primary oncologist |
| Chemotherapy | Earliest administered antineoplastic medication order | Oral and IV chemotherapy derived separately, then combined | First chemotherapy date and route |
| Radiation | Radiation-oncology document/encounter workflow | Order-result components with multi-format date parsing | First radiation date |
| Treatment plans | First and most recent treatment plan dates | Count, concatenated plan names, and first plan order date | Treatment-plan summary |
| Research studies | Therapeutic, non-therapeutic, and other groupings with enrollment dates | Interventional, observational, expanded-access, and other categories | Study counts, types, and names |
| Fertility | Referral orders plus SmartData Element outcomes and preservation methods | SmartData Elements and note-text pattern matching | First fertility-related date |
| Psychology | Provider-authored notes and encounter context | Referral procedure workflow | First psychology service date |
| Social work | First social-work-authored note after diagnosis | Order-specific question response | First social-work date |
| Child life | Procedure-order referrals | Child-life provider encounter | First child-life date |
| Nutrition | Procedure-order referrals | Referral procedure workflow | First nutrition date |
| Genetics | Specialized predisposition/AYA visits | Specialty referral workflow | First genetics date |
| Palliative care | Inpatient/outpatient orders plus palliative-note count | Order questions and referral date | First palliative-care date |
| Sexual health | Dedicated appointment-procedure workflow | Not derived through the same source workflow | Site-specific field where available |
| PCP location | Provider hierarchy with site-specific exception handling | Internal hierarchy plus external provider address | PCP location and internal/external classification |
| Final grain | One row per patient | One row per patient after deduplication and aggregation | Combined Power BI–ready patient model |

## Employer-Facing Takeaway

The two scripts intentionally remain separate. They show that achieving a shared
analytics definition often requires different extraction logic at each hospital.
The harmonization work occurs at the semantic and output-model layers rather than
by forcing both sites into identical source queries.
