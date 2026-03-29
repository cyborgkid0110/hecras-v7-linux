# HEC-RAS v6.6 Linux Preprocessor

Run HEC-RAS 2D unsteady simulations entirely on Linux / Docker — no Windows or
HEC-RAS GUI required.

The core script `ras_preprocess.py` replicates the **"Compute Geometry"** step
that the HEC-RAS GUI performs before a simulation: it reads a project's mesh
topology, samples terrain and land-cover rasters, builds hydraulic tables
(volume-elevation curves, face area-elevation profiles, Manning's *n* per cell,
infiltration, percent impervious, BC external faces) and writes a ready-to-run
`p01.tmp.hdf` file.  The Linux binary `RasGeomPreprocess` then adds the
internal solver index tables and `RasUnsteady` runs the simulation.

## Verified results

| Example model | Cells | Volume error | Max WSE diff vs GUI |
|---|---|---|---|
| BEFORE_RUN (test_hdf) | 503 | **0.00 %** | — |
| BEC | 2 315 | **0.00 %** | 0.000 ft |
| BEC_WO_Infiltration | 2 622 | **0.00 %** | 0.000 ft |
| VA | 1 221 | **0.00 %** | 0.000 ft |
| Muncie | 3 146 | **0.00 %** | 0.001 ft |

---

## Installation

Three commands and you're ready to simulate.

### Step 1 — Clone the repository

The HEC-RAS v6.6 Linux binaries (`bin/`, `libs/`) are stored in the repo via
**git LFS** — they download automatically when you clone.

```bash
git clone https://github.com/neeraip/hecras-v66-linux.git
cd Linux_RAS_v66
```

> **Requires git-lfs.** Install it first if needed:
> ```bash
> # macOS
> brew install git-lfs && git lfs install
>
> # Ubuntu / Debian
> sudo apt install git-lfs && git lfs install
> ```

### Step 2 — Install Python dependencies

Only needed for the preprocessing step (runs on your machine, not in Docker):

```bash
pip install numpy scipy h5py gdal
```

> **macOS / Conda tip:** GDAL is easiest via conda:
> ```bash
> conda install -c conda-forge gdal numpy scipy h5py
> ```

### Step 3 — Build the Docker image

```bash
docker build --platform linux/amd64 -t hecras-v66-amd64 .
```

This builds a Rocky Linux 8 image with Python, the HEC-RAS binaries, and all
shared libraries baked in.  Takes 2–5 minutes, produces a ~1.1 GB image.

That's it — you're ready to simulate.

---

## Quick start — zip in, zip out

The easiest way to run a simulation is with the `run_simulation.sh` wrapper.
Give it a zip file containing your HEC-RAS project folder and it handles
everything: preprocessing, Docker execution, and packaging the results.

```bash
./run_simulation.sh MyProject.zip
# → produces MyProject_results.zip
```

Specify a custom output name:
```bash
./run_simulation.sh MyProject.zip simulation_output.zip
```

### What the input zip must contain

```
MyProject.zip
└── MyProject/
    ├── MyProject.g01           ← geometry text file (seed points / perimeter)
    ├── MyProject.g01.hdf       ← mesh topology (created by RASMapper)
    ├── MyProject.p01           ← plan text file
    ├── MyProject.b01           ← boundary conditions
    ├── MyProject.x01           ← cross-section index
    ├── MyProject.u01.hdf       ← unsteady event conditions (optional)
    ├── Terrain/
    │   └── *.tif               ← DEM GeoTIFF (required)
    └── Land Classification/    ← optional; enables Manning's n + infiltration
        ├── LandCover.hdf
        ├── *.tif
        └── Infiltration.hdf
```

### What the output zip contains

| File | Description |
|---|---|
| `<name>.g01.hdf` | Geometry HDF with full hydraulic tables |
| `<name>.p01.hdf` | Simulation results |
| `<name>.bco01` | Computation log |

---

## Step-by-step usage (without zip wrapper)

```bash
python3 ras_preprocess.py <project_dir> [options]
```

| Argument | Default | Description |
|---|---|---|
| `project_dir` | (required) | Path to the HEC-RAS project folder |
| `--output-dir DIR` | same as project_dir | Where to write the output HDF files |
| `--plan N` | `01` | Plan number (produces `p01.tmp.hdf`, `g01.hdf`) |
| `--project-name NAME` | auto-detect | Override project name (e.g. `BEC`) |

### Example

```bash
# Step 1: Preprocess (runs on macOS/Linux, no Docker needed)
python3 ras_preprocess.py Examples/BEC --output-dir /tmp/bec_run

# Step 2: Copy boundary condition files
cp Examples/BEC/BEC.b01 Examples/BEC/BEC.x01 /tmp/bec_run/

# Step 3: Simulate in Docker
docker run --rm --platform linux/amd64 \
  -v /tmp/bec_run:/work \
  hecras-v66-amd64 bash -c "
    export PATH=/opt/hecras/bin:\$PATH
    export LD_LIBRARY_PATH=/opt/hecras/libs:/opt/hecras/libs/rhel_8:/opt/hecras/libs/mkl:\$LD_LIBRARY_PATH
    cd /work
    RasGeomPreprocess BEC.p01.tmp.hdf x01
    RasUnsteady       BEC.p01.tmp.hdf x01
    mv BEC.p01.tmp.hdf BEC.p01.hdf
  "
```

---

## How it works — three workflows

The preprocessor auto-detects which workflow applies based on what files are
present in the project directory.

### Workflow A — GUI-computed project (re-run without Windows)

**When:** `g01.hdf` already has hydraulic tables (geometry was fully computed
by the HEC-RAS GUI) **and** a `p01.hdf` exists.

This is the simplest case — all the heavy lifting was already done by the GUI.
The preprocessor just:

1. Copies `g01.hdf` to the output directory (no recomputation)
2. Strips the `Results` group from the existing `p01.hdf` → `p01.tmp.hdf`

Then `RasGeomPreprocess` + `RasUnsteady` run the simulation from scratch,
producing a fresh `p01.hdf` on Linux.

> **Use this workflow when:** you have an existing Windows/GUI project and
> want to re-run it on Linux (e.g. in a CI pipeline or cloud batch job).

### Workflow B — RASMapper mesh exists, tables not yet computed

**When:** `g01.hdf` exists (RASMapper created the mesh) but does **not**
contain hydraulic tables — i.e. "Compute Geometry" has not been clicked.

The preprocessor replicates the GUI's geometry compute step:

1. Reads mesh topology (cells, faces, face-points, BC polylines) from `g01.hdf`
2. Samples terrain GeoTIFF → cell volume-elevation curves
3. Samples terrain GeoTIFF → face area-elevation profiles
4. Samples land-cover raster + HDF table → Manning's *n* per cell
5. Samples infiltration HDF (if present) → Curve Number or Green-Ampt values
6. Computes BC External Faces (BFS chain traversal along perimeter)
7. Copies source `g01.hdf` to output directory and adds the hydraulic tables
8. Assembles `p01.tmp.hdf` (Plan Data from `.p01` + Event Conditions from `u01.hdf`)

> **Use this workflow when:** you designed the mesh in RASMapper on Windows
> but want to run geometry compute + simulation entirely on Linux.

### Workflow C — No g01.hdf (build mesh from scratch)

**When:** No `g01.hdf` exists.

The preprocessor builds the Voronoi mesh from the seed point coordinates
in the `.g01` text file, clips cells to the perimeter polygon using the
Sutherland-Hodgman algorithm, adds ghost/boundary cells, then continues
from step 2 of Workflow B and writes a new `g01.hdf`.

> **Use this workflow when:** you have only a `.g01` text file (cell seed
> points + perimeter) and no HDF geometry file.

---

## Repository layout

```
.
├── run_simulation.sh          # End-to-end runner: zip in → simulate → zip out
├── ras_preprocess.py          # Python preprocessor (Workflows A / B / C)
├── Dockerfile                 # Rocky Linux 8 container
├── scripts/
│   ├── run_geompre.sh         # Wrapper: RasGeomPreprocess
│   ├── run_unsteady.sh        # Wrapper: RasUnsteady
│   ├── run_steady.sh          # Wrapper: RasSteady
│   └── clean.sh               # Remove HEC-RAS result files
├── tests/
│   └── test_pipeline.py       # pytest integration tests (all 5 examples)
├── Examples/
│   ├── BEFORE_RUN/            # Workflow B input: mesh only, no hydraulic tables
│   ├── AFTER_RUN/             # Workflow A input: fully-computed reference
│   ├── BEC/                   # BEC example (SCS infiltration)
│   ├── BEC_WO_Infiltration/   # BEC without infiltration model
│   ├── VA/                    # Virginia example (precipitation BC)
│   └── Muncie/                # Muncie example (flow + precipitation BCs)
├── bin/                       # HEC-RAS Linux executables (git LFS)
│   ├── RasGeomPreprocess
│   ├── RasUnsteady
│   └── RasSteady
├── libs/                      # HEC-RAS shared libraries (git LFS)
│   ├── mkl/
│   └── rhel_8/
├── remove_HDF5_Results_Sed.py # Strip results from an existing p01.hdf
├── RAS_v.6.6_Linux.pdf        # Official HEC-RAS 6.6 Linux documentation
└── remove_HDF5_Results.pdf    # Guide: removing HDF5 results
```

> `bin/` and `libs/` are tracked via **git LFS** and download automatically
> on `git clone`.  Total size: ~733 MB.

---

## Running tests

```bash
# Fast tests — Python preprocessing only (~15 s, no Docker required)
pytest tests/test_pipeline.py::TestPreprocessOnly -v

# Full pipeline tests — requires Docker image (~3 min)
pytest tests/test_pipeline.py::TestFullPipeline -v

# All tests
pytest tests/test_pipeline.py -v
```

Expected output:
```
12 passed in ~184s
```

---

## Boundary conditions note

For projects whose boundary conditions are defined as simple text values in
the `.b01` file (e.g. constant flow + normal depth), `RasUnsteady` reads them
directly from `.b01` — no extra work needed.

For projects whose flow hydrographs live in a DSS file, the pre-existing
`u01.hdf` (if it contains baked-in `Flow Hydrographs` datasets) is
automatically copied into `p01.tmp.hdf`.  Otherwise the DSS file must be
accessible to `RasUnsteady` at runtime (mount it into the container with
`-v /path/to/project.dss:/work/project.dss`).

---

## Dependencies

| Library | Purpose |
|---|---|
| `numpy` | Array operations |
| `scipy` | Voronoi tessellation (Workflow C) |
| `h5py` | HDF5 read/write |
| `gdal` (osgeo) | GeoTIFF terrain/raster sampling |

---

## Architecture notes

- **Volume-elevation curves**: sampled from terrain raster per Voronoi cell,
  simplified with a local-tolerance Douglas-Peucker variant (~20 pts/cell).
- **Face area-elevation profiles**: cross-sections sampled at each mesh face,
  integrated via trapezoid rule.
- **BC External Faces**: BFS traversal on the perimeter face-adjacency graph.
  Start face selected by minimum forward-station (excluding spur faces);
  end face selected by maximum forward-station.
- **Infiltration guard**: Infiltration subgroup is only written when the source
  `g01.hdf` already has one **or** an `Infiltration.hdf` is present — projects
  with no infiltration model are left unchanged.
- **Safe HDF updates**: all hydraulic table datasets are added with `_add_ds()`
  which skips datasets that already exist, making the preprocessor safe to run
  on already-computed `g01.hdf` files.
- **Workflow A strip**: uses h5py to copy all groups except `Results`,
  `Bed Time Series`, `DSS Time Series`, `Transport Time Series`, and
  `Unsteady Time Series` — identical logic to `remove_HDF5_Results_Sed.py`.
