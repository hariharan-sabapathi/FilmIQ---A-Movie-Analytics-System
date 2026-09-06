-- =====================================================================
-- FilmIQ — Query Optimization, Window Functions & Recursive CTEs
-- =====================================================================
-- Environment this was captured on: PostgreSQL 16, dataset loaded from
-- imdb_final.csv (187,921 rows) and oscars_final.csv (10,327 rows) via
-- the ETL in work.sql. Resulting fact/bridge table sizes:
--
--   imdb_movies       184,638 rows
--   directors          78,764 rows
--   movie_directors   184,646 rows
--   stars             305,866 rows
--   movie_stars       737,033 rows
--   genres                 27 rows
--   movie_genres       389,052 rows
--   films               4,894 rows
--   nominations         10,327 rows
--
-- Methodology: `VACUUM ANALYZE` is run before every "before" baseline
-- below, so the deltas aren't stale-statistics artifacts. See
-- README.md -> "Query Performance Optimization" for the pasted plans,
-- timings, and the honesty notes on cache warmth per query.
-- =====================================================================


-- =====================================================================
-- QUERY 1 — Top-rated blockbusters (composite index, sort elimination)
-- "Highest rated movies among those with a large audience (votes > 100k)"
-- Bottleneck: no index supports either the votes filter or the rating
-- sort, so Postgres scans the whole table and sorts the survivors.
-- =====================================================================

VACUUM ANALYZE imdb_movies;

-- BEFORE
EXPLAIN (ANALYZE, BUFFERS)
SELECT movie_name, rating, votes
FROM imdb_movies
WHERE votes > 100000
ORDER BY rating DESC
LIMIT 10;

CREATE INDEX idx_imdb_movies_rating_votes ON imdb_movies(rating DESC, votes);
ANALYZE imdb_movies;

-- AFTER
EXPLAIN (ANALYZE, BUFFERS)
SELECT movie_name, rating, votes
FROM imdb_movies
WHERE votes > 100000
ORDER BY rating DESC
LIMIT 10;


-- =====================================================================
-- QUERY 2 — Filmography by director name (join strategy change)
-- "What did Christopher Nolan (or any director, looked up by name) direct?"
-- Bottleneck: directors.director (the human-readable name) is
-- unindexed, and movie_directors.director_id is only the trailing
-- column of its composite PK — so the whole join is Seq Scan + Hash
-- Join on two large tables just to resolve one name.
-- =====================================================================

VACUUM ANALYZE directors, movie_directors;

-- BEFORE
EXPLAIN (ANALYZE, BUFFERS)
SELECT imdb_movies.movie_name, directors.director
FROM imdb_movies
JOIN movie_directors ON imdb_movies.movie_id = movie_directors.movie_id
JOIN directors ON movie_directors.director_id = directors.director_id
WHERE directors.director = 'Christopher Nolan';

CREATE INDEX idx_directors_director ON directors(director);
CREATE INDEX idx_movie_directors_director_id ON movie_directors(director_id);
ANALYZE directors;
ANALYZE movie_directors;

-- AFTER
EXPLAIN (ANALYZE, BUFFERS)
SELECT imdb_movies.movie_name, directors.director
FROM imdb_movies
JOIN movie_directors ON imdb_movies.movie_id = movie_directors.movie_id
JOIN directors ON movie_directors.director_id = directors.director_id
WHERE directors.director = 'Christopher Nolan';


-- =====================================================================
-- QUERY 3 — when the index isn't the bottleneck (partial index, negative result)
-- "Which actors appeared in an Oscar-winning film?"
-- Bottleneck: nominations.winner is unindexed, so the ~2,152 winning
-- rows (of 10,327) are found by scanning and filtering the whole
-- table. Note (see README): repeated warm runs show NO reproducible
-- wall-clock difference before/after — nominations access is ~0.35%
-- of this query's total buffer touches, so replacing its Seq Scan
-- with a Bitmap Index Scan can't move the total. The index is still
-- the structurally correct fix; it just isn't the bottleneck here.
-- =====================================================================

VACUUM ANALYZE nominations;

-- BEFORE
EXPLAIN (ANALYZE, BUFFERS)
SELECT DISTINCT stars.star
FROM stars
JOIN movie_stars ON stars.star_id = movie_stars.star_id
JOIN nominations ON movie_stars.movie_id = nominations.filmid
WHERE nominations.winner = TRUE;

CREATE INDEX idx_nominations_winner ON nominations(winner) WHERE winner = TRUE;
ANALYZE nominations;

-- AFTER
EXPLAIN (ANALYZE, BUFFERS)
SELECT DISTINCT stars.star
FROM stars
JOIN movie_stars ON stars.star_id = movie_stars.star_id
JOIN nominations ON movie_stars.movie_id = nominations.filmid
WHERE nominations.winner = TRUE;


-- =====================================================================
-- WINDOW FUNCTION — Top 3 highest-rated movies per genre
-- Real question: "Within each genre, which films define the ceiling for
-- audience rating, and how do the runners-up compare?" DENSE_RANK lets
-- ties share a rank without leaving gaps, and PARTITION BY genre resets
-- the ranking per genre in a single pass instead of N per-genre queries.
-- A minimum-votes floor keeps low-sample outliers out of the ranking.
-- =====================================================================

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


-- =====================================================================
-- RECURSIVE CTE — Co-star "degrees of separation" (Bacon-number style)
-- Real question: "Starting from one actor, how many hops through shared
-- casts does it take to reach every other actor in the dataset?" This
-- walks the implicit actor-collaboration graph encoded in movie_stars:
-- two actors are adjacent if they share a movie_id. The `visited` array
-- blocks cycles, and the depth cap keeps the walk bounded (the graph is
-- densely connected, so hop count explodes past 2-3 degrees).
-- =====================================================================

WITH RECURSIVE costar_chain AS (
    -- anchor: the starting actor, degree 0
    SELECT s.star_id::text AS star_id,
           0 AS degree,
           ARRAY[s.star_id::text] AS visited
    FROM stars s
    WHERE s.star_id = '/name/nm0000138/'  -- Leonardo DiCaprio

    UNION ALL

    -- recursive step: everyone who shares a movie with the current frontier
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
