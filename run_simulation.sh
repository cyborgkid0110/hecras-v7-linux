#!/usr/bin/env bash
# =============================================================================
# run_simulation.sh — HEC-RAS v6.6 Linux end-to-end runner
#
# Usage:
#   ./run_simulation.sh  <input.zip>  [output.zip]
#
# The input zip must contain a single HEC-RAS project folder, e.g.:
#
#   BEC.zip
#   └── BEC/
#       ├── BEC.g01
#       ├── BEC.g01.hdf          ← mesh topology (RASMapper output)
#       ├── BEC.p01              ← plan text file
#       ├── BEC.b01              ← boundary conditions
#       ├── BEC.x01              ← runtime cross-section index
#       ├── BEC.u01.hdf          ← unsteady event conditions (optional)
#       ├── Terrain/
#       │   └── *.tif            ← DEM GeoTIFF
#       └── Land Classification/
#           ├── LandCover.hdf
#           ├── *.tif
#           └── Infiltration.hdf ← optional
#
# Output zip contains:
#   <name>.g01.hdf   — geometry HDF with hydraulic tables
#   <name>.p01.hdf   — simulation results
#   <name>.bco01     — computation log
#
# Requirements:
#   • Python 3 with numpy / scipy / h5py / gdal installed
#   • Docker with image hecras-v66-amd64 built (see README)
#   • unzip, zip
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <input.zip> [output.zip]" >&2
    exit 1
fi

# realpath requires the file to exist; use a portable absolute-path helper
_abspath() {
    if command -v realpath >/dev/null 2>&1 && realpath "$1" >/dev/null 2>&1; then
        realpath "$1"
    else
        # Resolve manually: if relative, prepend $PWD
        case "$1" in
            /*) echo "$1" ;;
            *)  echo "$PWD/$1" ;;
        esac
    fi
}

INPUT_ZIP="$(_abspath "$1")"
OUTPUT_ZIP="${2:-$(basename "${1%.zip}")_results.zip}"
OUTPUT_ZIP="$(_abspath "$OUTPUT_ZIP")"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_IMAGE="hecras-v66-amd64"
RAS_BIN="/opt/hecras/bin"
RAS_LIBS="/opt/hecras/libs:/opt/hecras/libs/rhel_8:/opt/hecras/libs/mkl"

echo "============================================="
echo " HEC-RAS v6.6 Linux Simulation Runner"
echo "============================================="
echo " Input  : $INPUT_ZIP"
echo " Output : $OUTPUT_ZIP"
echo ""

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
for cmd in python3 docker unzip zip; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done

if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Docker image '$DOCKER_IMAGE' not found."
    echo "  Build it first:  docker build --platform linux/amd64 -t $DOCKER_IMAGE ."
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Extract input zip to a temp working directory
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT   # always clean up

echo "[1/4] Extracting $INPUT_ZIP ..."
unzip -q "$INPUT_ZIP" -d "$WORKDIR/input"

# Find the project directory: the deepest folder that contains a .g01 or .g01.hdf file.
# This handles both flat zips (BEC.g01 at root) and nested zips (Examples/BEC/BEC.g01).
PROJECT_DIR=""
while IFS= read -r hdf; do
    candidate="$(dirname "$hdf")"
    # Skip __MACOSX sidecar directories that macOS zip sometimes includes
    [[ "$candidate" == *__MACOSX* ]] && continue
    PROJECT_DIR="$candidate"
    break
done < <(find "$WORKDIR/input" \( -name "*.g01.hdf" -o -name "*.g01" \) \
              ! -path "*/__MACOSX/*" | sort | head -1)

# Fallback: use the extraction root if no .g01 found
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$WORKDIR/input"
    echo "WARNING: Could not find a .g01 / .g01.hdf file; using zip root as project dir."
fi

echo "    Project dir : $PROJECT_DIR"

# ---------------------------------------------------------------------------
# 3. Python preprocessing (Workflows A / B / C auto-detected)
# ---------------------------------------------------------------------------
RUN_DIR="$WORKDIR/run"
mkdir -p "$RUN_DIR"

echo "[2/4] Running Python preprocessor ..."
python3 "$SCRIPT_DIR/ras_preprocess.py" "$PROJECT_DIR" --output-dir "$RUN_DIR"

# Detect project name from generated g01.hdf (guaranteed to exist after step above)
G01_HDF="$(ls "$RUN_DIR"/*.g01.hdf 2>/dev/null | head -1)"
if [[ -z "$G01_HDF" ]]; then
    echo "ERROR: No .g01.hdf found in output directory after preprocessing." >&2
    exit 1
fi
PROJECT_NAME="$(basename "$G01_HDF" | sed 's/\.g01\.hdf$//')"
echo "    Project name : $PROJECT_NAME"

# Copy boundary-condition files the solver needs (.b01 .x01) from the project dir
for f in "$PROJECT_DIR"/*.b01 "$PROJECT_DIR"/*.x01; do
    [[ -e "$f" ]] && cp "$f" "$RUN_DIR/"
done

# ---------------------------------------------------------------------------
# 4. Docker: RasGeomPreprocess → RasUnsteady
# ---------------------------------------------------------------------------
TMP_HDF="${PROJECT_NAME}.p01.tmp.hdf"
RESULT_HDF="${PROJECT_NAME}.p01.hdf"

echo "[3/4] Running Docker simulation (RasGeomPreprocess + RasUnsteady) ..."
docker run --rm --platform linux/amd64 \
    -v "${RUN_DIR}:/work" \
    "$DOCKER_IMAGE" \
    bash -c "
        export PATH=${RAS_BIN}:\$PATH
        export LD_LIBRARY_PATH=${RAS_LIBS}:\$LD_LIBRARY_PATH
        cd /work
        echo '  → RasGeomPreprocess ...'
        RasGeomPreprocess '${TMP_HDF}' x01
        echo '  → RasUnsteady ...'
        RasUnsteady '${TMP_HDF}' x01
        mv '${TMP_HDF}' '${RESULT_HDF}'
        echo '  → Simulation complete.'
    "

# ---------------------------------------------------------------------------
# 5. Package output
# ---------------------------------------------------------------------------
echo "[4/4] Packaging results into $OUTPUT_ZIP ..."
OUTPUT_FILES=()
for pat in "*.g01.hdf" "*.p01.hdf" "*.bco01" "*.ic.o01" "*.hyd.o01"; do
    while IFS= read -r f; do
        [[ -e "$f" ]] && OUTPUT_FILES+=("$f")
    done < <(ls "$RUN_DIR"/$pat 2>/dev/null || true)
done

if [[ ${#OUTPUT_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No output files found to package." >&2
    exit 1
fi

# Remove old output zip if it exists
[[ -e "$OUTPUT_ZIP" ]] && rm "$OUTPUT_ZIP"
(cd "$RUN_DIR" && zip -j "$OUTPUT_ZIP" "${OUTPUT_FILES[@]##*/}" )

echo ""
echo "============================================="
echo " Done!"
echo " Results : $OUTPUT_ZIP"
echo " Contents:"
unzip -l "$OUTPUT_ZIP" | awk 'NR>3 && $NF ~ /\./  {printf "   %-40s (%s bytes)\n", $NF, $1}'
echo "============================================="
