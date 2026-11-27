# Reproducing the video-plane measurements

## Review and replay the saved results

The baseline is `bf0ed7e`, the first commit in the series. The candidate is `e065c37`, which adds the GPU copy. To recreate the statistics from the archived samples, run this command inside the extracted validation directory.

```sh
python3 summarize.py
```

| Dataset | Meaning |
|---|---|
| `data/frame-timings.csv` | One measured operation per row. `port` denotes `e065c37`. Workload, block, build and sample identify the observation. Times are milliseconds. |
| `data/wallpaper-timings.csv` | One window move and its following position read per row. Series 1–3 each contain steps 1–36. Both columns are milliseconds. |
| `data/checks.txt` | Fixed-frame digest, original timing summaries, pixel checks and dispatch/write counters for the isolated process. |

P95 uses the nearest rank on sorted samples. The pooled desktop median uses all 108 measurements per operation. A slow call took strictly more than 50 ms. The desktop counts by series show how much the result varied.

| Series, 36 calls per operation | Moves >50 ms, bf0ed7e → e065c37 | Reads >50 ms, bf0ed7e → e065c37 |
|---|---:|---:|
| 1 | 28 → 9 | 36 → 8 |
| 2 | 31 → 2 | 36 → 5 |
| 3 | 29 → 1 | 36 → 7 |
| **Pooled** | **88 → 12** | **108 → 20** |

## Repeat the isolated frame test

Use a working RX4Darwin accelerator, Xcode command-line tools, the RX4Darwin source checkout and one built Metal bundle per commit. Point `BASE` and `CANDIDATE` at their **Mach-O executables** inside the two bundles. The probes load each binary in a separate process and verify the device implementation's origin. The measured configuration used a 4K 10-bit bi-planar Los Angeles Overpass asset. Set `MOVIE` to the local video. The asset is not distributed with the probes.

Run from this directory with `REPO` set to the absolute checkout path.

```sh
export REPO
./build-probes.sh
./bin/frame "$CANDIDATE" "$MOVIE"
./bin/partial "$CANDIDATE" "$MOVIE"
for binary in "$BASE" "$CANDIDATE"; do
    DYLD_INSERT_LIBRARIES="$PWD/bin/count.dylib" ./bin/frame "$binary" "$MOVIE"
done
```

The reference checks visible bytes at every level against the existing per-plane reduction rules. The expected count is 12 levels for 3840×2160 R16 and 11 for 1920×1080 RG16. The partial probe also checks the surrounding destination pixels. Compare the final `COUNTS` line for each binary. The counter classifies dispatches by workgroup shape in this isolated workload and counts successful host-write calls and their byte lengths. It is specific to these probes.

For timings, run the following with the counter disabled and record each invocation separately. Build order alternates across blocks.

```sh
for block in 1 2 3 4 5 6; do
    for probe in fixed sequence; do
        if [ $((block % 2)) -eq 1 ]; then
            set -- "$BASE" "$CANDIDATE"
        else
            set -- "$CANDIDATE" "$BASE"
        fi
        slot=0
        for binary do
            slot=$((slot + 1))
            "./bin/$probe" "$binary" "$MOVIE" > "$probe-$block-$slot.log" || exit 1
        done
    done
done
```

Each invocation discards three warm-up iterations and reports twelve. The fixed workload reuses one decoded frame. The sequence advances through decoded frames. Each iteration times two operations on both planes, first copying and generating mipmaps, then generating mipmaps on the populated textures. Timing begins before command buffer creation and ends after completion. Decoding and the CPU reference comparison occur outside that interval. The fixed-frame digest covers visible rows only and is recorded in `checks.txt`.

## Repeat the WindowServer test

1. For each build, verify that WindowServer has loaded the intended Metal executable in the current boot. Compare its runtime sender image UUID with `dwarfdump --uuid` on the executable. The recorded UUIDs were `5AA5F5D7-EF7F-312D-8302-D0979A658D88` for the baseline and `11FCF48C-7128-303C-9AEC-A79217A17C94` for the candidate. Locally rebuilt binaries may have different UUIDs.
2. Use the same display setup for both builds. The recorded sessions reported 2560×1440 at 165 Hz in CoreGraphics and about 164.95–164.96 Hz on the physical link, RGB 10 bpc on HBR3 ×4. Open System Settings to Wallpaper, bring it to the front, select Los Angeles Overpass and check that the preview is advancing. Use the same initial window position with room to move right.
3. After 15 seconds of active preview, run the command below from a session that leaves Wallpaper frontmost. System Events needs Accessibility access. Use a new output filename on each of the three runs per build.
4. Check the display mode and WindowServer PID before and after each series. The script verifies each requested position and restores the initial position. It measures 36 horizontal moves and immediate reads. Convert each tick difference to milliseconds using the system's Mach timebase numerator divided by its denominator and by 1,000,000. For a move use `setEnd - begin`. For its read use `readEnd - setEnd`.

```sh
osascript -l JavaScript probes/motion.js > motion-series-1.json
```

The frames and window operations are complementary measurements. The isolated test identifies the transfer that changed. The window script measures the latency observed by a UI automation client across System Events, Settings and WindowServer. The captures do not assign an individual slow call to a particular GPU operation or measure presentation frame rate.
