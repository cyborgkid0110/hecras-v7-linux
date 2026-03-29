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

## Repository layout

```
.
├── ras_preprocess.py          # Main preprocessor (Python 3)
├── Dockerfile                 # Rocky Linux 8 container
├── scripts/
│   ├── run_geompre.sh         # Wrapper: RasGeomPreprocess
│   ├── run_unsteady.sh        # Wrapper: RasUnsteady
│   ├── run_steady.sh          # Wrapper: RasSteady
│   └── clean.sh               # Remove HEC-RAS result files
├── Examples/
│   ├── BEFORE_RUN/            # Pre-compute state (mesh only, no hydraulic tables)
│   ├── AFTER_RUN/             # Post-compute reference (used for validation)
│   ├── BEC/                   # BEC example (SCS infiltration)
│   ├── BEC_WO_Infiltration/   # BEC without infiltration model
│   ├── VA/                    # Virginia example (precipitation BC)
│   └── Muncie/                # Muncie example (flow + precipitation BCs)
├── remove_HDF5_Results_Sed.py # Strip results from an existing p01.hdf
├── RAS_v.6.6_Linux.pdf        # Official HEC-RAS 6.6 Linux documentation
└── remove_HDF5_Results.pdf    # Guide: removing HDF5 results
```

> **Not committed to git** (too large / not redistributable):
> `bin/` – HEC-RAS Linux executables
> `libs/` – HEC-RAS shared libraries

---

## Prerequisites

### Python (local / CI)
```
pip install numpy scipy h5py gdal
```

### Docker image
The image bundles Python + HEC-RAS binaries.  You need `bin/` and `libs/`
on the build host (obtain from the HEC-RAS 6.6 Linux distribution):

```bash
docker build --platform linux/amd64 -t hecras-v66-amd64 .
```

---

## How it works — two workflows

### Workflow A — RASMapper g01.hdf already exists (typical use case)
HEC-RAS RASMapper creates the mesh and writes topology into `<name>.g01.hdf`
**before** "Compute Geometry" is clicked.  The preprocessor detects this file
and:

1. Reads mesh topology (cells, faces, face-points, BC polylines) from g01.hdf
2. Samples terrain GeoTIFF → cell volume-elevation curves
3. Samples terrain GeoTIFF → face area-elevation profiles
4. Samples land-cover raster + HDF table → Manning's *n* per cell
5. Samples infiltration HDF (if present) → Curve Number or Green-Ampt values
6. Computes BC External Faces (BFS chain traversal along perimeter)
7. Copies source g01.hdf to output directory and adds the hydraulic tables
8. Assembles `p01.tmp.hdf` (Plan Data from `.p01` text file + Event Conditions
   from `u01.hdf`)

### Workflow B — No g01.hdf (build Voronoi mesh from scratch)
When no g01.hdf exists the preprocessor builds the Voronoi mesh from the seed
point coordinates in the `.g01` text file, clips cells to the perimeter polygon
using the Sutherland-Hodgman algorithm, adds ghost/boundary cells, then
continues from step 2 above and writes a new g01.hdf.

---

## Usage

```bash
python3 ras_preprocess.py <project_dir> [options]
```

| Argument | Default | Description |
|---|---|---|
| `project_dir` | (required) | Path to the HEC-RAS project folder |
| `--output-dir DIR` | same as project_dir | Where to write the output HDF files |
| `--plan N` | `1` | Plan number (produces `p01.tmp.hdf`, `g01.hdf`) |
| `--project-name NAME` | auto-detect | Override project name (e.g. `BEC`) |

### Example — preprocess and simulate
```bash
# Step 1: Preprocess (runs on macOS/Linux, no Docker needed)
python3 ras_preprocess.py Examples/BEC --output-dir /tmp/bec_run

# Step 2: Copy boundary condition files
cp Examples/BEC/BEC.b01 Examples/BEC/BEC.x01 /tmp/bec_run/

# Step 3: Simulate in Docker
docker run --rm --platform linux/amd64 \
  -v /tmp/bec_run:/work \
  hecras-v66-amd64 bash -c "
    cd /work
    RasGeomPreprocess BEC.p01.tmp.hdf x01
    RasUnsteady       BEC.p01.tmp.hdf x01
    mv BEC.p01.tmp.hdf BEC.p01.hdf
  "
```

### Boundary conditions note
The preprocessor writes an empty `Event Conditions/Unsteady/Boundary Conditions`
group in `p01.tmp.hdf`.  For projects whose boundary conditions are defined
as simple text values in the `.b01` file (e.g. constant flow + normal depth),
`RasUnsteady` reads them directly from `.b01` — no extra work needed.

For projects whose flow hydrographs live in a DSS file, the pre-existing
`u01.hdf` (if it contains baked-in `Flow Hydrographs` datasets) is
automatically copied into `p01.tmp.hdf`.  Otherwise the DSS file must be
accessible to `RasUnsteady` at runtime (mount it into the container).

---

## Output files

After preprocessing, `--output-dir` contains:

| File | Description |
|---|---|
| `<name>.g01.hdf` | Geometry HDF with full hydraulic tables |
| `<name>.p01.tmp.hdf` | Plan HDF ready for RasGeomPreprocess |

After simulation:

| File | Description |
|---|---|
| `<name>.p01.hdf` | Final results HDF (rename from `.tmp.hdf`) |

---

## Dependencies

| Library | Purpose |
|---|---|
| `numpy` | Array operations |
| `scipy` | Voronoi tessellation (Workflow B) |
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
  g01.hdf already has one **or** an `Infiltration.hdf` is present — projects
  with no infiltration model are left unchanged.
- **Safe HDF updates**: all hydraulic table datasets are added with `_add_ds()`
  which skips datasets that already exist, making the preprocessor safe to run
  on already-computed g01.hdf files.
