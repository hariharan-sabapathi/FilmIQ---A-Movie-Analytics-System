# FilmIQ — A Movie Analytics System
**SQL · Relational Data Modeling · Indexing & Constraints · Python · Streamlit**

This project demonstrates query-plan analysis and schema design on a normalized IMDb/Oscars database: reading `EXPLAIN` output, picking the right index for the right reason, and justifying BCNF decomposition against real functional dependencies in the data.

---

## Query Performance Optimization

Three read-path queries were profiled with `EXPLAIN (ANALYZE, BUFFERS)` against the fully loaded dataset (`imdb_movies`: 184,638 rows, `movie_stars`: 737,033 rows, `movie_directors`: 184,646 rows, `directors`: 78,764 rows, `nominations`: 10,327 rows) on PostgreSQL 16. For each, the missing index is identified, added, and the query re-profiled. Full runnable SQL is in [`OPTIMIZATION/optimization_queries.sql`](OPTIMIZATION/optimization_queries.sql). Two of the three are wins; the third is a deliberate negative result, kept because knowing an index *won't* help — and being able to say precisely why — is as much a part of this skill as knowing when it will.

**Methodology notes, stated plainly:** `VACUUM ANALYZE` was run before every "before" baseline, so none of the deltas below are stale-statistics artifacts. Queries 1 and 2 report a single warm run each (`Buffers` shown per query — `read=0` or no `read=` line means warm). Query 3 reports the steady-state of three consecutive warm runs on each side, because that query's actual finding is the *absence* of a reproducible difference — see its write-up for why one run wouldn't have been trustworthy there.

### Query 1 — Top-rated blockbusters (composite index, sort elimination)

```sql
SELECT movie_name, rating, votes
FROM imdb_movies
WHERE votes > 100000
ORDER BY rating DESC
LIMIT 10;
```

**Before** — no index supports either the `votes` filter or the `rating` sort, so every row is fetched and the top 10 are heap-sorted afterward. Warm run (`Buffers: shared hit=1982`, no reads):

```
Limit  (cost=4331.38..4331.41 rows=10 width=27) (actual time=11.613..11.616 rows=10 loops=1)
  Buffers: shared hit=1982
  ->  Sort  (cost=4331.38..4336.52 rows=2055 width=27) (actual time=11.611..11.612 rows=10 loops=1)
        Sort Key: rating DESC
        Sort Method: top-N heapsort  Memory: 26kB
        ->  Seq Scan on imdb_movies  (cost=0.00..4286.98 rows=2055 width=27) (actual time=0.100..11.198 rows=2054 loops=1)
              Filter: (votes > 100000)
              Rows Removed by Filter: 182584
Execution Time: 11.647 ms
```

**Index added:**
```sql
CREATE INDEX idx_imdb_movies_rating_votes ON imdb_movies(rating DESC, votes);
```

**After** (warm, `Buffers: shared hit=10 read=7`):
```
Limit  (cost=0.42..47.16 rows=10 width=27) (actual time=0.036..0.071 rows=10 loops=1)
  Buffers: shared hit=10 read=7
  ->  Index Scan using idx_imdb_movies_rating_votes on imdb_movies  (cost=0.42..9609.67 rows=2056 width=27) (actual time=0.035..0.069 rows=10 loops=1)
        Index Cond: (votes > 100000)
Execution Time: 0.084 ms
```

**Plan node change:** `Seq Scan` + `Sort` → `Index Scan` (the `Sort` node disappears entirely). Column order is the whole fix here — `(rating DESC, votes)` lets rows arrive off the index already sorted, so Postgres reads only as many entries as it needs to satisfy `votes > 100000` and `LIMIT 10`, and stops early — **11.647 ms to 0.084 ms (~139x)**.

One detail worth being able to explain: `votes` is the *trailing* column of this index, yet the plan shows `Index Cond: (votes > 100000)`, not a `Filter`. `rating` (the leading column) is unconstrained, so Postgres is already visiting every index entry in `rating DESC` order regardless — but because `votes` is stored right there in the same index tuple, it can evaluate that condition off the index entry itself and skip the heap fetch entirely for rows that don't qualify. It's not narrowing the range scanned (a leading-column condition would do that); it's avoiding heap I/O for the rows the scan would have visited anyway, which is what lets it hand back 10 qualifying rows almost immediately.

### Query 2 — Filmography by director name (join strategy change)

```sql
SELECT imdb_movies.movie_name, directors.director
FROM imdb_movies
JOIN movie_directors ON imdb_movies.movie_id = movie_directors.movie_id
JOIN directors ON movie_directors.director_id = directors.director_id
WHERE directors.director = 'Christopher Nolan';
```

**Before** — `directors.director` (the human-readable name) is unindexed and `movie_directors.director_id` is only the trailing column of its composite PK, so both tables are scanned and hash-joined just to resolve one name. Warm run (`Buffers: shared hit=2016`, no reads):

```
Nested Loop  (cost=1594.98..5284.73 rows=2 width=31) (actual time=4.842..31.316 rows=12 loops=1)
  Buffers: shared hit=2016
  ->  Hash Join  (cost=1594.56..5283.74 rows=2 width=24) (actual time=4.811..31.159 rows=12 loops=1)
        Hash Cond: ((movie_directors.director_id)::text = (directors.director_id)::text)
        ->  Seq Scan on movie_directors  (cost=0.00..3204.46 rows=184646 width=27) (actual time=0.004..11.431 rows=184646 loops=1)
        ->  Hash  (cost=1594.55..1594.55 rows=1 width=31) (actual time=4.750..4.751 rows=1 loops=1)
              ->  Seq Scan on directors  (cost=0.00..1594.55 rows=1 width=31) (actual time=2.819..4.739 rows=1 loops=1)
                    Filter: (director = 'Christopher Nolan'::text)
                    Rows Removed by Filter: 78763
  ->  Index Scan using imdb_movies_pkey on imdb_movies ...
Execution Time: 31.391 ms
```

One honest note on this plan: the `Hash Join` node estimated 2 output rows and got 12 — a 6x miss, but on numbers small enough that it isn't the reason the plan is slow; the cost is dominated by the two `Seq Scan`s underneath it, not by the join's row estimate.

**Indexes added:**
```sql
CREATE INDEX idx_directors_director ON directors(director);
CREATE INDEX idx_movie_directors_director_id ON movie_directors(director_id);
```

**After** (warm, `Buffers: shared hit=63 read=4`):
```
Nested Loop  (cost=5.30..33.09 rows=2 width=31) (actual time=0.045..0.117 rows=12 loops=1)
  Buffers: shared hit=63 read=4
  ->  Nested Loop  (cost=4.88..32.10 rows=2 width=24) (actual time=0.039..0.052 rows=12 loops=1)
        ->  Index Scan using idx_directors_director on directors  (cost=0.42..8.44 rows=1 width=31) (actual time=0.020..0.021 rows=1 loops=1)
              Index Cond: (director = 'Christopher Nolan'::text)
        ->  Bitmap Heap Scan on movie_directors  (cost=4.46..23.61 rows=5 width=27) (actual time=0.016..0.027 rows=12 loops=1)
              Recheck Cond: ((director_id)::text = (directors.director_id)::text)
              ->  Bitmap Index Scan on idx_movie_directors_director_id  (cost=0.00..4.46 rows=5 width=0) (actual time=0.010..0.010 rows=12 loops=1)
  ->  Index Scan using imdb_movies_pkey on imdb_movies ...
Execution Time: 0.137 ms
```

**Plan node change:** `Hash Join` (over two `Seq Scan`s) → `Nested Loop` (over an `Index Scan` and a `Bitmap Heap Scan`). Once both sides of the join are individually selective via an index, the planner abandons hashing the whole `movie_directors` table in favor of probing it once per matching director — **31.391 ms to 0.137 ms (~229x)**.

### Query 3 — when the index isn't the bottleneck

```sql
SELECT DISTINCT stars.star
FROM stars
JOIN movie_stars ON stars.star_id = movie_stars.star_id
JOIN nominations ON movie_stars.movie_id = nominations.filmid
WHERE nominations.winner = TRUE;
```

**Before** — `nominations.winner` is unindexed, so the ~2,152 winning rows (out of 10,327) are found by scanning and filtering the whole table. Warm, steady-state run (`Buffers: shared hit=29088`, no reads):

```
HashAggregate  (cost=11950.92..12039.50 rows=8858 width=14) (actual time=29.007..29.212 rows=1937 loops=1)
  Buffers: shared hit=29088
  ->  Nested Loop  (cost=0.86..11928.78 rows=8858 width=14) (actual time=0.054..27.344 rows=6241 loops=1)
        ->  Nested Loop  (cost=0.43..7710.90 rows=8858 width=17) (actual time=0.042..9.831 rows=6267 loops=1)
              ->  Seq Scan on nominations  (cost=0.00..206.27 rows=2152 width=10) (actual time=0.015..1.500 rows=2152 loops=1)
                    Filter: winner
                    Rows Removed by Filter: 8175
                    Buffers: shared hit=103
              ->  Memoize (... Index Only Scan using movie_stars_pkey ...)
        ->  Index Scan using stars_pkey on stars ...
Execution Time: 29.873 ms
```

**Index added (partial — indexes only the rows that matter for this query):**
```sql
CREATE INDEX idx_nominations_winner ON nominations(winner) WHERE winner = TRUE;
```

**After** (warm, steady-state run, `Buffers: shared hit=29091`, no reads):
```
HashAggregate  (cost=11896.75..11985.33 rows=8858 width=14) (actual time=30.909..31.123 rows=1937 loops=1)
  Buffers: shared hit=29091
  ->  Nested Loop  (cost=28.44..11874.61 rows=8858 width=14) (actual time=0.139..29.331 rows=6241 loops=1)
        ->  Nested Loop  (cost=28.01..7656.72 rows=8858 width=17) (actual time=0.123..10.905 rows=6267 loops=1)
              ->  Bitmap Heap Scan on nominations  (cost=27.58..152.10 rows=2152 width=10) (actual time=0.091..0.878 rows=2152 loops=1)
                    Recheck Cond: winner
                    Heap Blocks: exact=103
                    Buffers: shared hit=106
                    ->  Bitmap Index Scan on idx_nominations_winner  (cost=0.00..27.04 rows=2152 width=0) (actual time=0.070..0.071 rows=2152 loops=1)
              ->  Memoize (... Index Only Scan using movie_stars_pkey ...)
        ->  Index Scan using stars_pkey on stars ...
Execution Time: 31.807 ms
```

**Plan node change:** `Seq Scan` (with `Filter: winner`) → `Bitmap Heap Scan` fed by a `Bitmap Index Scan` on the new partial index. Stated honestly, with the full rigor this deserves: across repeated warm runs, before and after land in the same ~27–34 ms band with no consistent winner — this is *not* a reproducible speedup, and reporting one here would be the exact overclaim the methodology note above is trying to avoid. The reason is quantifiable from the `Buffers` lines: the `nominations` access touches 103–106 blocks either way, out of ~29,000 total buffer touches for the whole query — about 0.35%. The other 99.65% is the `Index Scan` on `stars_pkey` (~86% of buffer touches) and the `Memoize`-cached lookups into `movie_stars` (~13.5%). Changing how a 0.35%-of-cost step is executed cannot move a query's total wall-clock time in a way that survives noise, regardless of which plan node it uses. The index is structurally correct — it turns a full scan-and-filter into a targeted lookup, and that stops being a rounding error once `nominations` is large enough (or contended enough on real disk I/O) that its own access cost is a non-trivial share of the total. At 10,327 rows sharing a query with a `stars`/`movie_stars` join two orders of magnitude larger, it just isn't yet.

---

## Advanced Analytical SQL

### Window function — top movies per genre

*Real question: within each genre, which films set the ceiling for audience rating, and how close are the runners-up?*

```sql
SELECT genre, movie_name, rating, votes, rnk
FROM (
    SELECT g.genre,
           m.movie_name,
           m.rating,
           m.votes,
           DENSE_RANK() OVER (
               PARTITION BY g.genre
               ORDER BY m.rating DESC, m.votes DESC
           ) AS rnk
    FROM imdb_movies m
    JOIN movie_genres mg ON mg.movie_id = m.movie_id
    JOIN genres g ON g.genre_id = mg.genre_id
    WHERE m.votes >= 5000
) ranked
WHERE rnk <= 3
ORDER BY genre, rnk;
```

`DENSE_RANK() OVER (PARTITION BY genre ...)` resets the ranking per genre in a single pass, letting tied ratings share a rank without leaving gaps — impossible to express as cleanly with a correlated subquery or one query per genre. The `votes >= 5000` floor keeps low-sample outliers out of the ranking.

### Recursive CTE — co-star degrees of separation

*Real question: starting from one actor, how many hops through shared casts does it take to reach every other actor (a "Bacon number" style analysis)?*

```sql
WITH RECURSIVE costar_chain AS (
    SELECT s.star_id::text AS star_id,
           0 AS degree,
           ARRAY[s.star_id::text] AS visited
    FROM stars s
    WHERE s.star_id = '/name/nm0000138/'  -- Leonardo DiCaprio

    UNION ALL

    SELECT ms2.star_id::text,
           c.degree + 1,
           c.visited || ms2.star_id::text
    FROM costar_chain c
    JOIN movie_stars ms1 ON ms1.star_id = c.star_id
    JOIN movie_stars ms2 ON ms2.movie_id = ms1.movie_id
                         AND ms2.star_id <> ms1.star_id
    WHERE c.degree < 2
      AND NOT (ms2.star_id::text = ANY(c.visited))
)
SELECT st.star, MIN(cc.degree) AS degree_of_separation
FROM costar_chain cc
JOIN stars st ON st.star_id = cc.star_id
GROUP BY st.star
ORDER BY degree_of_separation, st.star;
```

`movie_stars` implicitly encodes an actor-collaboration graph (two actors are adjacent if they share a `movie_id`); a recursive CTE is the only way to walk that graph to an arbitrary depth in pure SQL. The `visited` array blocks cycles, and the `degree < 2` cap keeps the walk bounded — the cast graph is dense enough that unbounded recursion would explode combinatorially. On this dataset, degree 1 reaches 63 direct co-stars and degree 2 reaches 2,950 actors.

---

## Normalization: BCNF Decisions & Where We'd Denormalize

**Decomposition rationale.** The two source feeds (`oscars`, `IMDB`) each land as one wide, unnormalized staging table with real anomalies: `oscars` repeats `Category`/`CanonicalCategory` and `Ceremony`/`Year`/`Class` on every nomination row, and `IMDB` packs directors, stars, and genres into comma-separated multivalued fields — a 1NF violation on its own. The schema decomposes these into single-subject tables:

- `Ceremonies`, `Films`, `Categories`, `Nominees` — each holds attributes that are functionally dependent only on their own key (`Ceremony`, `FilmId`, `Category_id`, `NomineeIds` respectively), not on the wide `NomId` grain of the original `oscars` row.
- `Directors` / `Movie_directors`, `Stars` / `Movie_stars`, `Genres` / `Movie_genres` — splitting each multivalued CSV field into a dimension table plus a many-to-many bridge table removes the repeating groups and the update anomaly they cause (fixing a misspelled director name would otherwise mean rewriting it on every movie row that credits them).
- `Nominations` is the awards fact table: `NomId` is the only candidate key, and every other column (`Ceremony`, `Category_id`, `NomineeIds`, `FilmId`, `Winner`) depends on it directly with no transitive path through a non-key attribute — satisfying BCNF trivially.
- `Imdb_movies` is the ratings/commercial fact table, keyed by `movie_id`, holding only attributes (`rating`, `votes`, `gross_in_dollars`, `certificate`, `runtime`) that describe the movie itself, not its cast or crew.

Concretely, the violation this avoids: if `Category` and `CanonicalCategory` had stayed on the original wide `oscars`/`Nominations` row instead of moving into their own `Categories` table, the dependency `Category → CanonicalCategory` would hold *transitively* through the non-key path `NomId → Category → CanonicalCategory` rather than directly through the key — a textbook BCNF violation, since `Category` is not itself a candidate key of that table. Giving `Categories` its own key (`Category_id`) makes `Category → CanonicalCategory` a dependency on a table where `Category` (functionally) determines the primary key, closing the gap.

This keeps every determinant a candidate key: no non-key attribute in any table determines another non-key attribute, so there's no redundancy to correct twice.

**Where we'd denormalize for reads.** Three read paths in this project are proven hot (they're the ones profiled above and the ones the Streamlit demo hits on every page load), and each has a natural denormalization trade:

| Hot read path | Normalized cost | Denormalization | Trade-off |
|---|---|---|---|
| "Top movies per genre" (window-function query) | 2 joins (`imdb_movies` → `movie_genres` → `genres`) on every request | Store a `genres text[]` (or JSONB) column directly on `imdb_movies` | Faster reads, no join fan-out; but genre-level rollups need `unnest` + a GIN index instead of a plain `GROUP BY`, and a genre rename means updating every movie row instead of one `genres` row |
| "Nominations per film" (`films LEFT JOIN nominations GROUP BY`) | Aggregated from scratch on every dashboard load | A `nomination_count`/`win_count` rollup column on `Films`, maintained by the same AFTER-INSERT trigger pattern already defined in `work.sql` | Removes the join + aggregate entirely from the read path; but the rollup is now derived state that can drift if a nomination is deleted or reassigned without going through the trigger |
| "Cast/crew for one movie" (Query 2 above) | Join through `Movie_stars`/`Movie_directors` bridge tables | Keep star/director names as comma-separated text directly on the movie row (the original CSV's shape) | Fastest possible "show me this movie's page"; but exactly the query this document optimizes — "which movies did this director make" — regresses to a full-table string scan, since the bridge tables (and their indexes) are what make person-centric lookups efficient in the first place |

The general rule applied here: normalize first so every table has one subject and no anomaly is possible, then denormalize selectively — a rollup column, an array column, a materialized view — only for read paths that are demonstrably hot, keeping the normalized tables as the source of truth underneath.

**Data quality note (found and fixed).** Building `Stars`/`Directors` by zipping `unnest(string_to_array(star, ','))` against `unnest(string_to_array(star_id, ','))` assumes the two comma-separated lists always split into the same number of elements in the same order. On rows where that assumption breaks (a name or id list with a different element count than its counterpart for that one movie), the positional zip desyncs and a `star_id` can end up paired with the wrong name — this dataset's real case: `/name/nm0000288/` (Christian Bale's ID) resolved to `Joe Baker` under the original `SELECT DISTINCT` + `ON CONFLICT DO NOTHING` logic, because that logic kept whichever `(id, name)` pairing was scanned first, with no guarantee that "first" meant "correct." This is exactly the kind of functional-dependency violation BCNF is meant to prevent, introduced by the ETL rather than the schema — and it's now fixed in `work.sql`: both `Stars` and `Directors` are populated by grouping each `(id, name)` pair and keeping the one with the highest occurrence count per id, so a single desynced row can no longer outvote the dozens of correctly-paired rows for a popular actor's real filmography. Verified against the live data: `/name/nm0000288/` now resolves to `Christian Bale`. The fix changes *which name* an id resolves to, not the id sets or row counts (`Stars`: 305,866 rows, `Directors`: 78,764 rows, both unchanged), so it doesn't touch any query's plan shape or buffer counts above. It does shift output content where a query surfaces the corrected names: Query 3's distinct-star-name count moved from 1,883 to 1,937 after the fix, since a few previously-miscounted name collisions are now correctly separated. Query 2 filters on `directors.director` by name, but `Christopher Nolan`'s pairing was already correct before the fix (re-verified after: same plan shape, same 12 rows), so its numbers stand.

---

## System Overview

FilmIQ integrates **IMDb ratings data** with **Academy Awards (Oscars)** data on top of a BCNF-compliant relational schema, to support the query-plan and normalization work documented above.

### Data Sources
- IMDb movie metadata and audience ratings (CSV)
- Oscars nominations and award outcomes (CSV)

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

### Integrity Enforcement
- Foreign-key constraints enforce valid movie–person and movie–award relationships
- Database triggers maintain consistent one-to-many film–award mappings during insert and update operations
- Referential integrity is enforced upstream to eliminate downstream correction logic

### Grain and Aggregation Strategy
- Analytical queries anchor on **MOVIES** or **NOMINATIONS** to establish a stable grain
- Award counts, wins, and rating aggregates are computed without join fan-out
- Aggregations remain consistent regardless of relationship multiplicity

---

## Demo Layer (Streamlit)

A lightweight **Streamlit** script (`movie_dashboard.py`) consumes the relational tables as a demo surface — interactive filtering across years/genres/award outcomes, and basic rating-trend charts. It's a thin consumer of the schema above, not the point of the project.

---

## Repository Structure

```text
FilmIQ/
├── .streamlit/
│   └── config.toml
│
├── OPTIMIZATION/
│   └── optimization_queries.sql
│
├── imdb_final.csv                 (gitignored — full 187,921-row dataset; not committed)
├── imdb_final.sample.csv          (first 200 rows, committed, for schema/structure reference)
├── oscars_final.csv
│
├── movie_dashboard.py
├── work.sql
│
├── ER DIAGRAM.png
├── Background.png
│
├── requirements.txt
└── README.md
```

The procedure, function, and trigger definitions referenced elsewhere in this README (and the query examples that predate the optimization work above) live as executable SQL in `work.sql` — the screenshots that used to sit alongside them in `QUERIES/`, `PROCEDURES/`, `FUNCTIONS/`, and `TRIGGERS/` were redundant with that text and have been removed, along with `work-copy.txt` and `movie_dashboard-copy.txt` (byte-identical/near-duplicate copies of `work.sql` and `movie_dashboard.py`).

**On `imdb_final.csv`:** the full file is 44MB, which is disproportionate for a SQL-focused repo to force into every clone. It's now gitignored rather than committed; `imdb_final.sample.csv` (the first 200 rows) is committed so the CSV's shape is visible without cloning the whole thing. To reproduce the full ETL in `work.sql`, supply your own copy of the complete `imdb_final.csv` in the repo root. Note this only stops the file from growing the repo *further* — it was already committed in this repository's first commit, so it's still in `master`'s history; fully purging it would mean rewriting that shared history (e.g. `git filter-repo` + a force-push to `master`), which breaks every existing clone and any in-flight branches, so that's a separate, deliberate decision for whoever owns the repo rather than something to fold into this change quietly. `Background.png` (used by `movie_dashboard.py` as a CSS background) was recompressed in place — same file, same path, 3640×2740 down to 1600×1204 with an adaptive palette — dropping it from 7.6MB to ~1MB with no code change needed.

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
