-- N1: point lookup on user_id (not in any sort key). Reordering must NOT help this.
SELECT count(), sum(amount) FROM exp.events_orderby WHERE user_id = 424242;
