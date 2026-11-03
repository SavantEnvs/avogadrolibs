#!/usr/bin/env bash
#
# mayhem/build.sh — build AvogadroLibs' libFuzzer harnesses (sanitized, DWARF 3) AND its gtest suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem; offline and re-runnable.
#   build/fuzz   sanitized project + the tests/**/fuzz-*.cpp, fuzztest.cpp harnesses (upstream's own CMake
#                ENABLE_FUZZ path); each harness is copied to /mayhem/<name> and relinked against the
#                standalone driver as /mayhem/<name>-standalone, both with LeakSanitizer turned off.
#   build/tests  Qt-free, unsanitized build of the core/calc/io/quantumio gtest binaries for mayhem/test.sh.
# Both directories live under the gitignored build/ so `git clean -ffdX` removes them.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${AVOGADRO_DATA_ROOT:=/opt/avogadrodata}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS AVOGADRO_DATA_ROOT

cd "$SRC"
# Fresh trees every run: CMake wipes a cache whose compiler spelling changed (clang vs /usr/bin/clang) and the
# half-reconfigured result is not reliable, so an in-place re-run is made idempotent by starting over.
rm -rf build/tests build/fuzz
mkdir -p build

COMMON_OPTS=(
  -G Ninja
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DUSE_LIBMSYM=OFF -DUSE_PLOTTER=OFF
  -DENABLE_TESTING=ON -DAVOGADRO_DATA_ROOT="$AVOGADRO_DATA_ROOT"
)

# 1) Test suite, NORMAL flags and no fuzzing. env -u: upstream's CMake turns ENABLE_FUZZ on (and compiles in
#    FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION) whenever LIB_FUZZING_ENGINE is set in the environment.
env -u LIB_FUZZING_ENGINE -u CFLAGS -u CXXFLAGS cmake -S . -B build/tests "${COMMON_OPTS[@]}" \
  -DCMAKE_BUILD_TYPE=Release -DENABLE_FUZZ=OFF -DUSE_QT=OFF -DUSE_OPENGL=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$COVERAGE_FLAGS"
env -u LIB_FUZZING_ENGINE cmake --build build/tests -j"$MAYHEM_JOBS" \
  --target AvogadroTests AvogadroCalcTests AvogadroIOTests AvogadroQuantumIOTests

# 2) Leak detection off, at build time (linked into every fuzz and -standalone binary).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/build/lsan_off.o"
# The standalone driver is C; compile it as C so its LLVMFuzzerTestOneInput reference keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/build/standalone_main.o"

# 3) Sanitized project + harnesses. -fsanitize=fuzzer-no-link puts SanitizerCoverage into the libraries as
#    well (upstream's CMake only adds it itself when LIB_FUZZING_ENGINE is unset); the harness executables
#    get the libFuzzer engine from $LIB_FUZZING_ENGINE via upstream's CMake.
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
LINK_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B build/fuzz "${COMMON_OPTS[@]}" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DENABLE_FUZZ=ON \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -g" -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -g" \
  -DCMAKE_EXE_LINKER_FLAGS="$LINK_FLAGS $SRC/build/lsan_off.o" \
  -DCMAKE_SHARED_LINKER_FLAGS="$LINK_FLAGS" -DCMAKE_MODULE_LINKER_FLAGS="$LINK_FLAGS"

cd build/fuzz
mapfile -t TARGETS < <(ninja -t targets all | sed -n 's/^\(fuzz_[A-Za-z0-9_-]*\): phony$/\1/p' | sort -u)
[ "${#TARGETS[@]}" -gt 0 ] || { echo "no fuzz_* targets found" >&2; exit 1; }
cmake --build . -j"$MAYHEM_JOBS" --target "${TARGETS[@]}"

# 4) Install each harness as /mayhem/<name>, and relink the same objects with the run-once driver in place of
#    libFuzzer as /mayhem/<name>-standalone (a reproducer that crashes naturally on one input file).
for t in "${TARGETS[@]}"; do
  cp -f "bin/$t" "$SRC/$t"
  read -ra words < <(ninja -t commands "bin/$t" | tail -n 1 | sed -e 's/^: && //' -e 's/ && :$//')
  out=()
  for w in "${words[@]}"; do
    case "$w" in
      -fsanitize=fuzzer) out+=("$SRC/build/standalone_main.o") ;;
      "bin/$t") out+=("$SRC/$t-standalone") ;;
      *) out+=("$w") ;;
    esac
  done
  "${out[@]}"
done
