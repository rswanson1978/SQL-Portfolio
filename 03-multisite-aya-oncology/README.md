# Multi-Site AYA Oncology Reporting

## Overview

This project demonstrates the development of a standardized adolescent and young adult (AYA) oncology reporting model across two independent hospital systems with different electronic health record (EHR) workflows.

Although both organizations required the same final reporting metrics, the underlying clinical documentation, oncology workflows, source tables, referral processes, and treatment documentation differed significantly. Separate PostgreSQL extraction pipelines were developed for each hospital, followed by harmonization into a common patient-level reporting model that supports combined analytics and Power BI reporting.

All organization names, database schemas, identifiers, and internal workflows have been generalized for portfolio purposes. No protected health information (PHI) is included.

---

## Repository Contents

| File | Description |
|------|-------------|
| **hospital_a_aya_pipeline.sql** | PostgreSQL pipeline for Hospital A using registry, cancer problem, referral, SmartData Element, and note-based workflows. |
| **hospital_b_aya_pipeline.sql** | PostgreSQL pipeline for Hospital B using oncology encounters, registry data, medication workflows, referrals, and treatment plans. |
| **workflow_crosswalk.md** | Side-by-side comparison of how equivalent clinical concepts were identified across both hospitals. |
| **combined_reporting_model.sql** *(optional)* | Example of standardizing both hospital outputs into a single reporting model for Power BI. |

---

# Business Problem

The Adolescent and Young Adult (AYA) Cancer Program required a unified reporting platform that combined patient data from two separate hospital systems.

Although leadership expected identical reporting metrics, each organization documented oncology care differently. Clinical concepts such as diagnosis, chemotherapy, radiation therapy, referrals, supportive care, survivorship, and research participation were captured through different workflows, requiring separate extraction logic before the data could be standardized.

The objective was to create one patient-level dataset that supported consistent reporting across both organizations while preserving the integrity of each site's clinical documentation practices.

---

# Hospital Workflow Differences

## Hospital A

Primary workflow characteristics included:

- Cancer registry and cancer problem driven cohort identification
- Separate workflow required for deceased patients
- Referrals commonly identified through procedure orders
- Additional concepts derived from provider notes
- SmartData Element extraction
- Treatment summary documentation
- Registry-based diagnosis workflows

---

## Hospital B

Primary workflow characteristics included:

- Oncology department and encounter driven cohort identification
- Registry diagnosis supplemented encounter diagnoses
- Independent oral and intravenous chemotherapy workflows
- Radiation treatment dates parsed from multiple documentation formats
- Referral workflows spanning referrals, provider encounters, orders, SmartData Elements, and clinical notes
- Treatment plan integration

---

# Clinical Domains Integrated

The standardized reporting model includes:

- Patient demographics
- Primary cancer diagnosis
- Diagnosis date
- Age at diagnosis
- Primary oncology provider
- Chemotherapy
- Radiation therapy
- Treatment plans
- Clinical trial participation
- Fertility preservation
- Genetics
- Nutrition
- Psychology
- Social work
- Child life
- Palliative care
- Sexual health
- Primary care provider information
- Mortality status

---

# Technical Skills Demonstrated

- PostgreSQL
- Complex Common Table Expressions (CTEs)
- Multi-table joins
- Window functions
- Conditional aggregation
- Temporal cohort construction
- Multi-site EHR data harmonization
- ICD-9 and ICD-10 normalization
- Cancer registry integration
- SmartData Element extraction
- Clinical note integration
- Referral workflow analysis
- Longitudinal patient timelines
- Power BI data preparation
- Healthcare data modeling

---

# Technical Challenges

This project required considerably more than simply querying patient data.

Key challenges included:

- Identifying equivalent clinical concepts across different EHR workflows
- Harmonizing two independent oncology data models
- Reconciling registry, diagnosis, medication, referral, and treatment documentation
- Standardizing variable definitions across organizations
- Managing one-to-many clinical relationships while producing one patient-level record
- Validating output against clinical expectations and reporting requirements
- Preparing a reusable dataset optimized for downstream Power BI dashboards

---

# Outcome

The completed pipelines produced standardized patient-level datasets for each hospital while preserving site-specific clinical workflows.

The harmonized outputs were combined into a unified reporting model supporting interactive Power BI dashboards for the Adolescent and Young Adult Cancer Program, enabling consistent reporting, quality improvement initiatives, operational analytics, and clinical research across both organizations.

---

# Portfolio Notes

To protect patient privacy and proprietary infrastructure:

- Organization names have been generalized.
- Database schemas have been anonymized.
- Internal identifiers have been replaced.
- Proprietary workflows have been abstracted where appropriate.
- No production data or protected health information is included.

The SQL demonstrates the architectural design, data engineering approach, and healthcare informatics methodologies used to build a multi-site clinical reporting solution.
