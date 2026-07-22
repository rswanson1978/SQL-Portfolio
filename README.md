# SQL Portfolio

This repository contains selected PostgreSQL projects demonstrating healthcare
analytics, clinical research data extraction, cohort development, data
harmonization, and reusable research data infrastructure.

All organization names, schemas, identifiers, and internal database structures
have been generalized. No protected health information is included.

## Featured Projects

| Project | Description | Skills Demonstrated |
|---|---|---|
| [Preoperative Clinical Research Pipeline](01-anesthesia-preoperative-research/) | Integrates preoperative encounters, diagnoses, problem lists, surgical cases, complications, flowsheets, and clinical notes. | Temporal cohort construction, EHR integration, clinical research ETL |
| [TIVA and Difficult-Airway Evaluation](02-anesthesia-difficult-airway/) | Identifies propofol-based anesthesia cases without volatile anesthetic exposure and integrates airway, medication, vital-sign, and demographic data. | CTEs, EXISTS/NOT EXISTS, MAR analysis, flowsheet extraction |
| [Multi-Site AYA Oncology Reporting](03-multisite-aya-oncology/) | Creates a standardized oncology reporting model across two hospitals with different EHR workflows and supports a combined Power BI report. | Multi-site harmonization, ICD normalization, referrals, treatment timelines |
| [Identified Honest Broker Dataset](04-honest-broker-identified-data/) | Builds a reusable identified research dataset for approved self-service cohort development. | Reusable data modeling, research informatics, data governance |
| [De-identified Honest Broker Dataset](05-honest-broker-deidentified-data/) | Creates a privacy-preserving self-service research dataset using transformed identifiers and limited data elements. | De-identification, data governance, research infrastructure |

## Technical Skills

- PostgreSQL
- Complex joins and common table expressions
- Window functions
- Conditional aggregation
- Longitudinal patient timelines
- Healthcare data modeling
- Clinical terminology and diagnosis normalization
- Medication and flowsheet data
- Multi-site data harmonization
- Identified and de-identified research datasets
- Power BI data preparation

## Portfolio Notes

The original projects were developed in enterprise healthcare environments.
For this public portfolio:

- Institution and employee names were removed.
- Database and schema names were generalized.
- Patient and provider identifiers were replaced.
- Proprietary clinical IDs were replaced with synthetic examples.
- No production data or protected health information is included.
