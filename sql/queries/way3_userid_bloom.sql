-- Way 3: point lookup exercising the bloom_filter(0.01) index on user_id.
-- user_id 9999979 is a light-tail user (~84 rows, hash-scattered). The bloom
-- filter prunes granules that provably lack it; rows-scanned vs rows-matched is
-- the bloom-filter tax.
SELECT count(), sum(amount) FROM exp.events_skip WHERE user_id = 9999979;
