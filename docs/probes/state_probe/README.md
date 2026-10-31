# State copy probe (2026-10-31)

Temporary game script that measured what `state:get()` / `state:set()` of a game script cost for
different table shapes (Transport Fever 3 build 40425, Linux, big save loaded, each shape set and
read three times, fastest run). To run it again copy the folder into `kampfmoehre_running_costs_1/content/`,
load a save, read `stdout.txt` ("state probe:" lines) and remove the folder before any upload.

| Shape | tables | values | set µs | get µs | per table | per value |
|---|---:|---:|---:|---:|---:|---:|
| 10 000 tables × 1 number | 10 001 | 10 000 | 894 | 1 004 | 0.19 | 0.19 |
| 1 000 tables × 10 numbers (string keys) | 1 001 | 10 000 | 374 | 980 | 1.35 | 0.14 |
| 1 table × 10 000 numbers (array) | 1 | 10 000 | 656 | 313 | – | 0.10 |
| 1 table × 10 000 numbers (string keys) | 1 | 10 000 | 1 696 | 1 105 | – | 0.28 |
| 1 table × 10 000 numbers (sparse integer keys) | 1 | 10 000 | 1 328 | 835 | – | 0.22 |
| 1 000 tables × 10 short strings | 1 001 | 10 000 | 381 | 731 | 1.11 | 0.11 |
| 1 table × 1 000 strings of 100 chars | 1 | 1 000 | 53 | 103 | – | 0.16 |
| 1 table × 1 000 strings of 1 000 chars | 1 | 1 000 | 74 | 781 | – | 0.85 |
| 389 cost rings, 7 buckets × 8 numbers (0.3.1 flat tables) | 3 502 | 22 951 | 908 | 1 616 | 0.72 | 0.11 |
| 389 cost rings as 7 packed strings (~70 chars) | 779 | 3 890 | 163 | 321 | 0.62 | 0.12 |
| 389 cost rings as one packed string each (~500 chars) | 1 | 389 | 30 | 400 | – | 1.11 |

Conclusions: the copy costs ~0.1–0.3 µs per element, a table and a value alike; string-keyed
fields cost about twice an array element; long strings cost extra on `get` (~0.7 µs per 1 000
chars). So the lever is the element count, not the table count: a bucket packed into one string
of ~80 chars is five times cheaper than the same bucket as a table of 8 fields.
