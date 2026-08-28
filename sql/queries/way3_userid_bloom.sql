-- Way 3: point lookup exercising the bloom_filter(0.01) index on user_id.
SELECT count(), sum(amount) FROM exp.events_skip WHERE user_id = 424242;
