# Experiment v2 — SUMMARY

_dir: `results/linux`_

## Regime: hot

| label | n | p50 ms | min–max | CV | read_rows p50 | read_bytes p50 | marks p50 | ×rows vs base |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| baseline | 20 | 113 | 106–664 | 79% ⚠︎ | 8,222,000 | 115,108,000 | 1,004 | 1.0× |
| n1_pointlookup_base | 15 | 3 | 3–5 | 17% ⚠︎ | 8,192 | 99,388 | 1 | 1003.7× |
| n1_pointlookup_ord | 15 | 3 | 3–4 | 11% ⚠︎ | 8,192 | 237,568 | 1 | 1003.7× |
| n2_timerange_base | 12 | 8 | 7–9 | 9% | 554,288 | 2,217,152 | 68 | 14.8× |
| n2_timerange_ord | 12 | 26 | 25–31 | 8% | 6,051,120 | 24,204,480 | 739 | 1.4× |
| way1_orderby | 20 | 27 | 23–41 | 17% ⚠︎ | 434,176 | 6,078,464 | 53 | 18.9× |
| way2_n3_product | 12 | 138 | 130–221 | 20% ⚠︎ | 8,222,000 | 139,774,000 | 1,004 | 1.0× |
| way2_n4_eventtype | 12 | 44 | 39–47 | 6% | 8,222,000 | 41,110,000 | 1,004 | 1.0× |
| way2_proj_full | 20 | 24 | 21–37 | 17% ⚠︎ | 434,176 | 6,078,464 | 53 | 18.9× |
| way2_proj_lw | 20 | 163 | 155–600 | 48% ⚠︎ | 8,222,000 | 115,108,000 | 1,004 | 1.0× |
| way2_proj_narrow | 20 | 35 | 22–350 | 141% ⚠︎ | 434,176 | 6,078,464 | 53 | 18.9× |
| way3_country_heavy | 15 | 151 | 108–202 | 18% ⚠︎ | 8,222,000 | 115,108,000 | 1,004 | 1.0× |
| way3_main | 20 | 142 | 108–194 | 19% ⚠︎ | 8,222,000 | 115,108,000 | 1,004 | 1.0× |
| way3_tenant_pos | 15 | 6 | 5–8 | 14% ⚠︎ | 57,344 | 917,504 | 7 | 143.4× |
| way3_userid_bloom | 15 | 86 | 81–92 | 4% | 1,515,520 | 15,111,944 | 185 | 5.4× |
| way4_mv | 20 | 5 | 5–9 | 17% ⚠︎ | 7,099 | 307,543 | 1 | 1158.2× |
| way4_n5_product | 12 | 150 | 130–208 | 13% ⚠︎ | 8,222,000 | 139,774,000 | 1,004 | 1.0× |

## Regime: directio

| label | n | p50 ms | min–max | CV | read_rows p50 | read_bytes p50 | marks p50 | ×rows vs base |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| baseline | 20 | 133 | 124–212 | 17% ⚠︎ | 8,222,000 | 115,108,000 | 1,004 | 1.0× |
| way1_orderby | 20 | 29 | 26–52 | 22% ⚠︎ | 434,176 | 6,078,464 | 53 | 18.9× |
| way2_proj_full | 20 | 35 | 25–47 | 19% ⚠︎ | 434,176 | 6,078,464 | 53 | 18.9× |
| way2_proj_lw | 20 | 184 | 176–224 | 5% | 8,222,000 | 115,108,000 | 1,004 | 1.0× |
| way2_proj_narrow | 20 | 28 | 24–436 | 178% ⚠︎ | 434,176 | 6,078,464 | 53 | 18.9× |
| way3_main | 20 | 136 | 127–205 | 15% ⚠︎ | 8,222,000 | 115,108,000 | 1,004 | 1.0× |
| way4_mv | 20 | 6 | 5–13 | 29% ⚠︎ | 7,099 | 307,543 | 1 | 1158.2× |

## Interleaved pass (directio, drift-controlled)

**Do not cite this table as a fair baseline.** After Way 2 negatives, `proj_country_day`
was still on `exp.events`. `interleaved.csv` "baseline" reads 434,176 rows / 53 marks
(the projection), matching Way 1/2, not the standalone 8.22 M / 1,004. Standalone
read-volume above is the source of truth. The harness now drops that projection
before interleave.

| label | rounds | p50 ms | min–max | CV |
|---|--:|--:|--:|--:|
| baseline | 20 | 27 | 20–42 | 17% ⚠︎ |
| way1 | 20 | 24 | 20–29 | 8% |
| way2 | 20 | 29 | 20–36 | 12% ⚠︎ |
| way3 | 20 | 132 | 126–146 | 5% |
| way4 | 20 | 5 | 5–7 | 12% ⚠︎ |

_⚠︎ = CV > 10%: run-to-run noise exceeds the signal; treat that median as directional only._
