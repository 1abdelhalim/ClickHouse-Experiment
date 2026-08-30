-- Way 3: point lookup exercising the bloom_filter(0.01) index on user_id.
-- user_id is power-law skewed and hash-scattered; 9999998 is a high id -> a
-- light user with few rows. Bloom prunes granules that provably lack the value;
-- the over-read (rows scanned vs rows matched) is the bloom-filter tax.
SELECT count(), sum(amount) FROM exp.events_skip WHERE user_id = 9999998;
