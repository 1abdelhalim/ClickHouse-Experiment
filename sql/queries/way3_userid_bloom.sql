-- Way 3: point lookup exercising the bloom_filter(0.01) index on user_id.
-- The id is the dataset's max user_id (a light-tail user, few rows). Bloom prunes
-- granules that provably lack it; rows-scanned vs rows-matched is the bloom tax.
SELECT count(), sum(amount)
FROM exp.events_skip
WHERE user_id = (SELECT max(user_id) FROM exp.events_skip);
