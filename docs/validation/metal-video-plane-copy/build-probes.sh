#!/bin/sh
set -eu
: "${REPO:?Set REPO to the absolute RX4Darwin checkout}"
dest=${1:-bin}
mkdir -p "$dest"
for probe in fixed sequence frame partial; do
    xcrun clang++ -std=c++17 -O2 -fobjc-arc -include chrono \
        "probes/$probe.mm" -framework Foundation -framework Metal -framework IOKit \
        -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -framework IOSurface -o "$dest/$probe"
done
xcrun clang -dynamiclib -O2 -I"$REPO/include" probes/count.c -framework IOKit -o "$dest/count.dylib"
