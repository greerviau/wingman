# Measurement: wedged-mid-turn vs idle-at-prompt, from the watcher's vantage point

**Date:** 2026-08-03
**For:** issue #202, `docs/plans/2026-08-03-issue-202-foreground-watcher-wedge-plan.md` §2.6

This file preserves the sampler and the complete raw series behind the plan's §2.6, so the
measurement outlives the scratch directory it was taken in and any reader can re-derive the
table independently. Review round 2 asked for exactly this.

## What was measured

A crew session's own pane, sampled every 3s from outside the session, recording the signals
`bin/watch-fleet` already reads for every member each poll:

- `now - #{window_activity}` - the tmux signal `wm_tmux_window_activity_age`
  (`bin/lib/common.sh:415`) reads;
- a `capture-pane` hash - the signal `wm_pane_snapshot` (`bin/lib/common.sh:393`) hashes;
- the longest-running descendant of the pane's root pid, reimplementing
  `_longest_running_descendant`'s rule (`bin/lib/wm-state.py:1402`): a descendant that
  started more than 30s after the root, largest own elapsed.

Two phases on one real crew session:

- **t+7s..t+82s** - the session blocked in the FOREGROUND on `timeout 75 bin/watch-fleet`.
- **t+95s..t+334s** - the same session idle at its prompt.

The session was mid-turn from t+0 to roughly t+92 (the block, plus finishing the turn
around it); it went idle at t+95. Phase boundaries below are derived from the observable
(the pane hash freezing), not from when the block was issued - conflating the two is the
error round 2 caught in the plan's first table.

## Derived statistics

| segment | offsets | n | span | activity age min/median/max | pane hash changed | descendant elapsed |
|---|---|---|---|---|---|---|
| mid-turn (incl. the block) | 0-30 | 31 | 92s | 0 / 0 / **1s** | **30 of 30** transitions | 0s -> 91s |
| the 75s foreground block alone | 3-26 | 24 | 71s | 0 / 0 / **1s** | **23 of 23** transitions | 9s -> 79s |
| idle at prompt | 31-109 | 79 | 239s | 3 / 122 / **242s** | **0 of 78** transitions | 95s -> 333s |

**Units convention, used throughout this file:** every duration is
last-sample-minus-first-sample of the samples in question, i.e. `(n - 1) x 3s`. A span is
never reported as `n x 3s`.

Longest run containing no sample with `age >= 60` (the statistic that governs a false
positive, since that is how long the step-4 anchor could survive un-reset):

- whole series: 50 consecutive samples = 147s (the mid-turn stretch plus the first few
  idle samples before the age crossed 60);
- idle segment alone: 19 consecutive samples = 54s.

## Two honest caveats

1. **The descendant tracked here was the sampler itself.** Its elapsed time climbs
   monotonically 0 -> 333s across *both* phases with no discontinuity at the boundary,
   because the sampler ran as a harness-tracked background task for the whole run. That is
   still a valid instance of the general claim - any legitimately armed background task
   produces this reading, which is why descendant duration alone cannot discriminate - but
   it is not a second, separately armed watcher, and the plan should not describe it as one.
2. **This run does not reach the 1800s decision window.** 75s of wedge and 239s of idle
   support the *shape* of the discrimination, not a claim about 1800s of continuity. Review
   round 2's independent measurement (`docs/analysis/2026-08-03-issue-202-plan-review-round-2.md`,
   "Independent measurement") covers that: 810s across five live panes, with a 555s single
   blocking foreground call holding a maximum activity age of 1s, and every healthy
   idle/parked pane capping its continuously-live run at ~61s.

## The sampler

```bash
#!/usr/bin/env bash
# Samples this crew session's OWN pane from the watcher's vantage point:
# exactly the signals bin/watch-fleet already reads each poll.
set -u
WIN=wm-fix-github-issue-202-in-the-wing-architect
PANE=%17645
ROOT=3726181
OUT="$1"; TICKS="${2:-100}"; GAP="${3:-3}"
printf 'epoch\tphase\tactivity_age\tpane_hash\tcomposer_tail\tlongest_desc_elapsed\n' > "$OUT"
i=0
while [ "$i" -lt "$TICKS" ]; do
  i=$((i+1))
  now=$(date +%s)
  act=$(tmux list-windows -t "=wingman" -F '#{window_name} #{window_activity}' 2>/dev/null | awk -v w="$WIN" '$1==w {print $2; exit}')
  age=$(( now - ${act:-0} ))
  txt=$(tmux capture-pane -p -t "$PANE" 2>/dev/null)
  h=$(printf '%s' "$txt" | cksum | cut -d' ' -f1)
  # last non-blank line, trimmed - an idle composer ends in the anchor glyph
  tail_line=$(printf '%s\n' "$txt" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-40 | tr '\t' ' ')
  # longest-running descendant of the pane root, the #155 long_shell_elapsed signal
  ld=$(ps -ax -o pid=,ppid=,etime= 2>/dev/null | python3 -c '
import sys
rows={}; ch={}
def secs(e):
    d=0
    if "-" in e: d,e=e.split("-",1); d=int(d)
    p=[int(x) for x in e.split(":")]
    while len(p)<3: p.insert(0,0)
    return d*86400+p[0]*3600+p[1]*60+p[2]
for l in sys.stdin:
    f=l.split()
    if len(f)!=3: continue
    try: pid,ppid,el=int(f[0]),int(f[1]),secs(f[2])
    except Exception: continue
    rows[pid]=el; ch.setdefault(ppid,[]).append(pid)
root=int(sys.argv[1])
if root not in rows: print("na"); raise SystemExit
re_=rows[root]; st=[root]; seen=set(); best=-1
while st:
    p=st.pop()
    if p in seen: continue
    seen.add(p); st.extend(ch.get(p,[]))
    if p!=root and (re_-rows[p])>30 and rows[p]>best: best=rows[p]
print(best)
' "$ROOT")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "${PHASE:-?}" "$age" "$h" "$tail_line" "$ld" >> "$OUT"
  sleep "$GAP"
done
```

## Raw series

Columns: `epoch`, `phase` (unused), `activity_age`, `pane_hash`, `last non-blank pane line`, `longest_descendant_elapsed`. `offset` is the 0-based sample index, `t+` is seconds since the first sample.

```
offset  t+     age  pane_hash   ld
     0     0      0  3010707369  0
     1     3      0  1404230049  3
     2     6      0  670438742   6
     3     9      0  3181452496  9
     4    12      0  2102904553  12
     5    15      0  4130696749  15
     6    18      0  1380148029  18
     7    22      1  2744493082  21
     8    25      0  2776973806  24
     9    28      0  1937313723  27
    10    31      0  781782557   30
    11    34      0  799776349   33
    12    37      0  3369246814  36
    13    40      0  2149690149  39
    14    43      0  1707116876  42
    15    46      0  2049138186  46
    16    49      0  3377484259  49
    17    52      0  2293422141  52
    18    55      0  2824217854  55
    19    58      0  3948916929  58
    20    61      0  1140029735  61
    21    64      0  4198875571  64
    22    67      0  1861561100  67
    23    71      0  3464667452  70
    24    74      0  3633425387  73
    25    77      0  4109410927  76
    26    80      0  336810814   79
    27    83      0  2065122973  82
    28    86      0  1407497388  85
    29    89      0  668923048   88
    30    92      0  2847538547  91
    31    95      3  2847538547  95
    32    98      6  2847538547  98
    33   101      9  2847538547  101
    34   104     12  2847538547  104
    35   107     15  2847538547  107
    36   110     18  2847538547  110
    37   113     21  2847538547  113
    38   116     24  2847538547  116
    39   119     27  2847538547  119
    40   123     31  2847538547  122
    41   126     34  2847538547  125
    42   129     37  2847538547  128
    43   132     40  2847538547  131
    44   135     43  2847538547  134
    45   138     46  2847538547  137
    46   141     49  2847538547  140
    47   144     52  2847538547  143
    48   147     55  2847538547  147
    49   150     58  2847538547  150
    50   153     61  2847538547  153
    51   156     64  2847538547  156
    52   159     67  2847538547  159
    53   162     70  2847538547  162
    54   165     73  2847538547  165
    55   168     76  2847538547  168
    56   171     79  2847538547  171
    57   175     83  2847538547  174
    58   178     86  2847538547  177
    59   181     89  2847538547  180
    60   184     92  2847538547  183
    61   187     95  2847538547  186
    62   190     98  2847538547  189
    63   193    101  2847538547  192
    64   196    104  2847538547  195
    65   199    107  2847538547  199
    66   202    110  2847538547  202
    67   205    113  2847538547  205
    68   208    116  2847538547  208
    69   211    119  2847538547  211
    70   214    122  2847538547  214
    71   217    125  2847538547  217
    72   220    128  2847538547  220
    73   223    131  2847538547  223
    74   227    135  2847538547  226
    75   230    138  2847538547  229
    76   233    141  2847538547  232
    77   236    144  2847538547  235
    78   239    147  2847538547  238
    79   242    150  2847538547  241
    80   245    153  2847538547  244
    81   248    156  2847538547  247
    82   251    159  2847538547  250
    83   254    162  2847538547  254
    84   257    165  2847538547  257
    85   260    168  2847538547  260
    86   263    171  2847538547  263
    87   266    174  2847538547  266
    88   269    177  2847538547  269
    89   272    180  2847538547  272
    90   275    183  2847538547  275
    91   279    187  2847538547  278
    92   282    190  2847538547  281
    93   285    193  2847538547  284
    94   288    196  2847538547  287
    95   291    199  2847538547  290
    96   294    202  2847538547  293
    97   297    205  2847538547  296
    98   300    208  2847538547  299
    99   303    211  2847538547  302
   100   306    214  2847538547  306
   101   309    217  2847538547  309
   102   312    220  2847538547  312
   103   315    223  2847538547  315
   104   318    226  2847538547  318
   105   321    229  2847538547  321
   106   324    232  2847538547  324
   107   327    235  2847538547  327
   108   331    239  2847538547  330
   109   334    242  2847538547  333
```
