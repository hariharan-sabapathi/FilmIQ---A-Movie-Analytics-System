# FilmIQ — A Movie Analytics System
**SQL · Relational Data Modeling · Indexing & Constraints · Python · Streamlit**

---

## Overview

This repository documents **FilmIQ**, a production-style **movie analytics system** designed around a rigorously normalized relational database. The system integrates **IMDb ratings data** with **Academy Awards (Oscars)** data to support analytical queries on film performance, award trends, and rating correlations.

The system emphasizes core **data engineering principles**: BCNF-compliant schema design, database-enforced integrity, performance-oriented indexing, and predictable analytical query behavior. Visualization is treated strictly as a downstream consumer of the engineered data model.

---

## Architecture

### Data Sources
- IMDb movie metadata and audience ratings (CSV)
- Oscars nominations and award outcomes (CSV)

### Storage & Modeling
- Relational database (SQL)
- Fully normalized schema (BCNF)

### Access & Analytics
- SQL for analytical querying
- Python
- Streamlit for interactive analytical access

---

## Relational Schema Design

The system is built on a **BCNF-compliant relational schema** to eliminate redundancy, prevent update anomalies, and enforce correctness at the database layer.

### Core Entities
- Movies
- People (actors, directors, nominees)
- Genres
- Award ceremonies and categories

### Fact Tables
- **IMDB_MOVIES** – Audience and commercial metrics (ratings, votes, runtime, revenue)
- **NOMINATIONS** – Awards fact table capturing nominations and win outcomes

### Relationship Modeling
Complex relationships are explicitly modeled using bridge tables and foreign keys:
- MOVIE_GENRES
- MOVIE_STARS
- MOVIE_DIRECTORS

This approach preserves correct cardinality across many-to-many and one-to-many relationships while supporting flexible analytical aggregation.

---

## Data Engineering Implementation

### Integrity Enforcement
- Foreign-key constraints enforce valid movie–person and movie–award relationships
- Database triggers maintain consistent one-to-many film–award mappings during insert and update operations
- Referential integrity is enforced upstream to eliminate downstream correction logic

### Performance Optimization
- Composite multi-key indexes are applied to join-heavy and high-cardinality columns
- Indexing strategy is optimized for read-heavy analytical workloads
- Query execution plans remain stable under increasing data volume

### Grain and Aggregation Strategy
- Analytical queries anchor on **MOVIES** or **NOMINATIONS** to establish a stable grain
- Award counts, wins, and rating aggregates are computed without join fan-out
- Aggregations remain consistent regardless of relationship multiplicity

---

## Analytical Capabilities

The engineered schema supports analytics such as:
- IMDb rating distributions for nominated versus winning films
- Award nomination and win counts per movie
- Genre-level award concentration
- Longitudinal trends in audience ratings and award recognition

All analytical results are derived directly from the relational layer without embedding business logic in the visualization tier.

---

## Interactive Access Layer

A lightweight **Streamlit** application consumes the relational tables to provide:
- Interactive filtering across years, genres, and award outcomes
- Real-time visualization of rating distributions
- Historical trend analysis of ratings and awards

The interface validates that the schema supports low-latency, ad-hoc analytical access at scale.

---

## Repository Structure

```text
FilmIQ/
├── .streamlit/
│   └── config.toml              
│
├── FUNCTIONS/                   
├── INDEXING/                    
├── PROCEDURES/                  
├── QUERIES/                     
├── TRIGGERS/
│   ├── FAILURE/                
│   └── SUCCESS/                 
│
├── imdb_final.csv               
├── oscars_final.csv             
│
├── movie_dashboard.py           
├── movie_dashboard-copy.txt     
│
├── work.sql                    
├── work-copy.txt                
│
├── ER DIAGRAM.png               
├── Background.png               
│
├── requirements.txt             
└── README.md                    
```
---

## Assumptions and Limitations

- Each Oscar category has at most one winner per ceremony
- IMDb gross revenue contains missing values and is not treated as a complete financial record
- Ratings and votes reflect audience behavior rather than objective quality
- Observed relationships represent correlation, not causation

These constraints are explicitly documented to preserve analytical and engineering integrity.

---

## Key Takeaways

- BCNF-compliant schema design reduces redundancy and update anomalies
- Database-enforced constraints and triggers improve upstream data correctness
- Indexing strategy is critical for scalable analytical performance
- Treating visualization as a consumer encourages robust data system design

---

## Authors
Hariharan Nadanasabapathi  
Aishwarya Rudraswamy
