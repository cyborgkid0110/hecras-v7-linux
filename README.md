# HEC-RAS v7.0 Linux Engine

> Migrated and adapted from [neeraip/hecras-v66-linux](https://github.com/neeraip/hecras-v66-linux).

Run HEC-RAS 2D unsteady simulations entirely on Linux / Docker — no Windows or HEC-RAS GUI required.

---

## 1. Prerequisites

Docker and Conda are already installed. Set your Conda path in `run_simulation.sh`:

```bash
CONDA_PATH=/home/ad/anaconda3/condabin/conda
```

---

## 2. Download HEC-RAS v7.0 Linux engine

Download the engine zip from the [GitHub Releases](../../releases) page and unzip it into the repository root:

```bash
# Download
wget https://github.com/cyborgkid0110/hecras-v7-linux/releases/download/v7.0/Linux_RAS_v7.zip

# Unzip and organize binaries
unzip Linux_RAS_v7.zip
# Move executables to bin/
mkdir -p bin
cp Linux_RAS_v7/bin/* bin/
# Move shared libraries to libs/
mkdir -p libs
cp -r Linux_RAS_v7/libs/* libs/
```

---

## 3. Setup Conda environment

```bash
conda create -n hecras python=3.8 -y
conda activate hecras
conda install -c conda-forge gdal numpy scipy h5py matplotlib -y
```

---

## 4. Build Docker image
Two options for building Docker image:
- Pull from Docker Hub:
```bash
docker pull cyborgkid/hecras-v70-amd64:latest
```
- Build from source:
```bash
docker build --platform linux/amd64 -t hecras-v70-amd64 .
```

---

## 5. Run simulation

```bash
./run_simulation.sh MyProject.zip
# → produces MyProject_results.zip
```

Specify a custom output name:

```bash
./run_simulation.sh MyProject.zip simulation_output.zip
```

**Input zip structure:**

```
MyProject.zip
└── MyProject/
    ├── MyProject.g01           ← geometry text file
    ├── MyProject.g01.hdf       ← mesh topology (RASMapper)
    ├── MyProject.p01           ← plan text file
    ├── MyProject.b01           ← boundary conditions
    ├── MyProject.x01           ← cross-section index
    ├── Terrain/
    │   └── *.tif               ← DEM GeoTIFF (required)
    └── Land Classification/    ← optional
        ├── LandCover.hdf
        ├── *.tif
        └── Infiltration.hdf
```

**Output zip contents:**

| File | Description |
|---|---|
| `<name>.g01.hdf` | Geometry HDF with hydraulic tables |
| `<name>.p01.hdf` | Simulation results |
| `<name>.bco01` | Computation log |
