CREATE TABLE zomato_raw (
    url              TEXT,
    address          TEXT,
    name             TEXT,
    online_order     TEXT,
    book_table       TEXT,
    rate             TEXT,
    votes            TEXT,
    phone            TEXT,
    location         TEXT,
    rest_type        TEXT,
    dish_liked       TEXT,
    cuisines         TEXT,
    approx_cost      TEXT,
    reviews_list     TEXT,
    menu_item        TEXT,
    listed_in_type   TEXT,
    listed_in_city   TEXT
);
SELECT*FROM zomato_raw;
SELECT COUNT(*) FROM zomato_raw;
SELECT name, location, rate, approx_cost, cuisines
FROM zomato_raw
LIMIT 10;
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT url) AS distinct_restaurants
FROM zomato_raw;
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT (name, address)) AS distinct_name_address
FROM zomato_raw;
SELECT name, address, listed_in_type, listed_in_city, url
FROM zomato_raw
WHERE (name, address) IN (
    SELECT name, address
    FROM zomato_raw
    GROUP BY name, address
    ORDER BY COUNT(*) DESC
    LIMIT 1
)
ORDER BY listed_in_type;
SELECT COUNT(*) AS inconsistent_restaurants
FROM (
    SELECT name, address
    FROM zomato_raw
    GROUP BY name, address
    HAVING COUNT(DISTINCT rate) > 1
        OR COUNT(DISTINCT votes) > 1
        OR COUNT(DISTINCT approx_cost) > 1
        OR COUNT(DISTINCT location) > 1
        OR COUNT(DISTINCT cuisines) > 1
) AS t;
SELECT
    COUNT(*) FILTER (WHERE n_rate  > 1) AS rate_differs,
    COUNT(*) FILTER (WHERE n_votes > 1) AS votes_differs,
    COUNT(*) FILTER (WHERE n_cost  > 1) AS cost_differs,
    COUNT(*) FILTER (WHERE n_loc   > 1) AS location_differs,
    COUNT(*) FILTER (WHERE n_cuis  > 1) AS cuisines_differs
FROM (
    SELECT COUNT(DISTINCT rate)        AS n_rate,
           COUNT(DISTINCT votes)       AS n_votes,
           COUNT(DISTINCT approx_cost) AS n_cost,
           COUNT(DISTINCT location)    AS n_loc,
           COUNT(DISTINCT cuisines)    AS n_cuis
    FROM zomato_raw
    GROUP BY name, address
) AS per_restaurant;
CREATE TABLE restaurants_clean AS
WITH converted AS (
    SELECT
        name,
        address,
        location,
        rest_type,
        cuisines,
        (online_order = 'Yes') AS online_order,
        (book_table = 'Yes')   AS book_table,
        substring(rate FROM '^\s*([0-9.]+)\s*/\s*5')::numeric AS rating,
        NULLIF(regexp_replace(votes, '[^0-9]', '', 'g'), '')::int AS votes,
        NULLIF(regexp_replace(approx_cost, '[^0-9]', '', 'g'), '')::int AS cost_for_two
    FROM zomato_raw
)
SELECT DISTINCT ON (name, address) *
FROM converted
ORDER BY name, address, votes DESC NULLS LAST;
ALTER TABLE restaurants_clean ADD COLUMN restaurant_id SERIAL PRIMARY KEY;
SELECT COUNT(*)                AS restaurants,
       COUNT(rating)           AS rated,
       ROUND(AVG(rating), 2)   AS avg_rating,
       COUNT(cost_for_two)     AS with_cost,
       MIN(cost_for_two)       AS min_cost,
       MAX(cost_for_two)       AS max_cost
FROM restaurants_clean;
CREATE TABLE locations AS
SELECT ROW_NUMBER() OVER (ORDER BY location)::int AS location_id,
       location AS location_name
FROM (SELECT DISTINCT location
      FROM restaurants_clean
      WHERE location IS NOT NULL) AS t;

ALTER TABLE locations ADD PRIMARY KEY (location_id);

ALTER TABLE restaurants_clean ADD COLUMN location_id INT;

UPDATE restaurants_clean r
SET location_id = l.location_id
FROM locations l
WHERE r.location = l.location_name;
CREATE TABLE cuisines AS
SELECT ROW_NUMBER() OVER (ORDER BY cuisine_name)::int AS cuisine_id,
       cuisine_name
FROM (
    SELECT DISTINCT TRIM(c.cuisine) AS cuisine_name
    FROM restaurants_clean r
    CROSS JOIN LATERAL unnest(string_to_array(r.cuisines, ',')) AS c(cuisine)
    WHERE r.cuisines IS NOT NULL
) AS t;

ALTER TABLE cuisines ADD PRIMARY KEY (cuisine_id);

CREATE TABLE restaurant_cuisines AS
SELECT DISTINCT r.restaurant_id, cu.cuisine_id
FROM restaurants_clean r
CROSS JOIN LATERAL unnest(string_to_array(r.cuisines, ',')) AS c(cuisine)
JOIN cuisines cu ON cu.cuisine_name = TRIM(c.cuisine);
ALTER TABLE restaurant_cuisines ADD PRIMARY KEY (restaurant_id, cuisine_id);

ALTER TABLE restaurant_cuisines
    ADD FOREIGN KEY (restaurant_id) REFERENCES restaurants_clean(restaurant_id),
    ADD FOREIGN KEY (cuisine_id)    REFERENCES cuisines(cuisine_id);

ALTER TABLE restaurants_clean
    ADD FOREIGN KEY (location_id) REFERENCES locations(location_id);

SELECT (SELECT COUNT(*) FROM locations)           AS areas,
       (SELECT COUNT(*) FROM cuisines)            AS cuisines,
       (SELECT COUNT(*) FROM restaurant_cuisines) AS links,
       (SELECT COUNT(*) FROM restaurants_clean
         WHERE location_id IS NULL)               AS restaurants_without_area;
SELECT l.location_name,
       COUNT(*)                   AS restaurants,
       ROUND(AVG(r.rating), 2)    AS avg_rating,
       ROUND(AVG(r.cost_for_two)) AS avg_cost
FROM restaurants_clean r
JOIN locations l ON l.location_id = r.location_id
WHERE r.rating IS NOT NULL
GROUP BY l.location_name
HAVING COUNT(*) >= 30
ORDER BY avg_rating DESC
LIMIT 10;
SELECT l.location_name, COUNT(*) AS restaurants
FROM restaurants_clean r
JOIN locations l ON l.location_id = r.location_id
GROUP BY l.location_name
ORDER BY restaurants DESC
LIMIT 10;
SELECT cu.cuisine_name,
       COUNT(*)                AS restaurants,
       ROUND(AVG(r.rating), 2) AS avg_rating
FROM restaurant_cuisines rc
JOIN cuisines cu         ON cu.cuisine_id     = rc.cuisine_id
JOIN restaurants_clean r ON r.restaurant_id   = rc.restaurant_id
WHERE r.rating IS NOT NULL
GROUP BY cu.cuisine_name
HAVING COUNT(*) BETWEEN 20 AND 150
ORDER BY avg_rating DESC
LIMIT 10;
SELECT CASE WHEN cost_for_two < 300  THEN '1. Under 300'
            WHEN cost_for_two < 600  THEN '2. 300-599'
            WHEN cost_for_two < 1000 THEN '3. 600-999'
            ELSE '4. 1000+' END      AS price_band,
       COUNT(*)                      AS restaurants,
       ROUND(AVG(rating), 2)         AS avg_rating
FROM restaurants_clean
WHERE rating IS NOT NULL AND cost_for_two IS NOT NULL
GROUP BY 1
ORDER BY 1;
SELECT online_order, book_table,
       COUNT(*)                AS restaurants,
       ROUND(AVG(rating), 2)   AS avg_rating
FROM restaurants_clean
WHERE rating IS NOT NULL
GROUP BY online_order, book_table
ORDER BY online_order, book_table;
SELECT l.location_name,
       COUNT(*)                                    AS restaurants,
       COUNT(*) FILTER (WHERE r.cost_for_two >= 1000) AS premium,
       ROUND(AVG(r.rating), 2)                     AS avg_rating,
       ROUND(SUM(r.votes)::numeric / COUNT(*))     AS votes_per_restaurant
FROM restaurants_clean r
JOIN locations l ON l.location_id = r.location_id
GROUP BY l.location_name
HAVING COUNT(*) >= 100
ORDER BY votes_per_restaurant DESC
LIMIT 15;
SELECT l.location_name, COUNT(*) AS restaurants
FROM restaurant_cuisines rc
JOIN cuisines cu          ON cu.cuisine_id    = rc.cuisine_id
JOIN restaurants_clean r  ON r.restaurant_id  = rc.restaurant_id
JOIN locations l          ON l.location_id    = r.location_id
WHERE cu.cuisine_name IN ('Japanese', 'Korean', 'Modern Indian', 'Mediterranean')
GROUP BY l.location_name
ORDER BY restaurants DESC
LIMIT 10;