# TIVA and Difficult-Airway Evaluation

## Overview

This project identifies surgical cases consistent with total intravenous
anesthesia by requiring documented propofol administration and excluding cases
with documented volatile anesthetic use.

The resulting cohort is supplemented with airway-device documentation,
medications, vital signs, demographics, diagnoses, and body measurements to
support difficult-airway evaluation.

## Key SQL Techniques

- CTE-based cohort construction
- EXISTS and NOT EXISTS logic
- Multi-encounter reconciliation
- Medication administration analysis
- Flowsheet extraction
- Conditional dose aggregation
