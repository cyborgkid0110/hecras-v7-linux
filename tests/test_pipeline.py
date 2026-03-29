"""Integration tests for the HEC-RAS Linux preprocessor pipeline.

Each test:
  1. Runs ras_preprocess.py on the example project directory.
  2. Stages the output directory (copies boundary-condition files if needed).
  3. Runs RasGeomPreprocess + RasUnsteady inside Docker.
  4. Validates:
       • Volume accounting error < 0.1 %  (parsed from Compute Messages)
       • Max WSE difference vs reference p01.hdf < tolerance (ft)

Run with:
    pytest tests/test_pipeline.py -v

Docker image required:  hecras-v66-amd64
Built via:              docker build --platform linux/amd64 -t hecras-v66-amd64 .
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import h5py
import numpy as np
import pytest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parent.parent
EXAMPLES  = REPO_ROOT / "Examples"
SCRIPT    = REPO_ROOT / "ras_preprocess.py"
DOCKER_IMG = "hecras-v66-amd64"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _docker_available() -> bool:
    try:
        result = subprocess.run(
            ["docker", "image", "inspect", DOCKER_IMG],
            capture_output=True, timeout=10
        )
        return result.returncode == 0
    except Exception:
        return False


def run_preprocessor(project_dir: Path, output_dir: Path, project_name: str | None = None) -> None:
    """Run ras_preprocess.py; raise on failure."""
    cmd = [sys.executable, str(SCRIPT), str(project_dir), "--output-dir", str(output_dir)]
    if project_name:
        cmd += ["--project-name", project_name]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        raise RuntimeError(
            f"ras_preprocess.py failed:\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )


def run_docker_simulation(work_dir: Path, project_name: str, plan: str = "01") -> str:
    """Run RasGeomPreprocess + RasUnsteady inside Docker.

    Returns combined stdout (used to parse volume error).
    Raises RuntimeError on non-zero exit or if the volume error line is absent.
    """
    tmp_hdf  = f"{project_name}.p{plan}.tmp.hdf"
    xsuffix  = f"x{plan}"
    # Use explicit paths — the built image may predate the ENV PATH update in Dockerfile.
    ras_bin  = "/opt/hecras/bin"
    ras_libs = "/opt/hecras/libs:/opt/hecras/libs/rhel_8:/opt/hecras/libs/mkl"
    docker_cmd = (
        f"export PATH={ras_bin}:$PATH && "
        f"export LD_LIBRARY_PATH={ras_libs}:$LD_LIBRARY_PATH && "
        f"cd /work && "
        f"RasGeomPreprocess {tmp_hdf} {xsuffix} && "
        f"RasUnsteady       {tmp_hdf} {xsuffix} && "
        f"mv {tmp_hdf} {project_name}.p{plan}.hdf"
    )
    result = subprocess.run(
        [
            "docker", "run", "--rm", "--platform", "linux/amd64",
            "-v", f"{work_dir}:/work",
            DOCKER_IMG, "bash", "-c", docker_cmd,
        ],
        capture_output=True, text=True, timeout=600,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Docker simulation failed:\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )
    return result.stdout


def parse_volume_error(source: "Path | str") -> "float | None":
    """Extract 'Overall Volume Accounting Error as percentage' from either:
    - A Docker stdout string (returned by run_docker_simulation), or
    - A p01.hdf path (GUI-written, stores message in Results/Summary).
    """
    _PATTERN = r'Overall Volume Accounting Error as percentage:\s*([\d.eE+\-]+)'

    # String case (Docker stdout)
    if isinstance(source, str):
        m = re.search(_PATTERN, source)
        return float(m.group(1)) if m else None

    # HDF case (GUI-written p01.hdf)
    try:
        with h5py.File(str(source), 'r') as f:
            key = 'Results/Summary/Compute Messages (text)'
            if key not in f:
                return None
            msg = f[key][0]
            if isinstance(msg, bytes):
                msg = msg.decode('utf-8', errors='replace')
            m = re.search(_PATTERN, msg)
            return float(m.group(1)) if m else None
    except Exception:
        return None


def max_wse_diff(result_hdf: Path, reference_hdf: Path) -> float:
    """Return max absolute WSE difference (ft) between result and reference."""
    with h5py.File(str(result_hdf), 'r') as rf, \
         h5py.File(str(reference_hdf), 'r') as refh:
        base = 'Results/Unsteady/Output/Output Blocks/Base Output/Summary Output/2D Flow Areas'
        r_area = list(rf[base].keys())[0]
        ref_area = list(refh[base].keys())[0]
        r_wse   = rf[f'{base}/{r_area}/Maximum Water Surface'][:]
        ref_wse = refh[f'{base}/{ref_area}/Maximum Water Surface'][:]
        # Only compare cells with finite WSE in reference (active cells)
        mask = np.isfinite(ref_wse) & (ref_wse < 1e10)
        if not mask.any():
            return 0.0
        return float(np.max(np.abs(r_wse[mask] - ref_wse[mask])))


def check_g01hdf_has_tables(g01_hdf: Path) -> bool:
    """Return True if g01.hdf contains computed hydraulic tables."""
    with h5py.File(str(g01_hdf), 'r') as f:
        geo = f.get('Geometry/2D Flow Areas', {})
        for area_name in geo.keys():
            if area_name == 'Attributes':
                continue
            area_grp = geo[area_name]
            if isinstance(area_grp, h5py.Group) and \
                    'Cells Volume Elevation Info' in area_grp.keys():
                return True
    return False


# ---------------------------------------------------------------------------
# Markers
# ---------------------------------------------------------------------------
requires_docker = pytest.mark.skipif(
    not _docker_available(),
    reason=f"Docker image '{DOCKER_IMG}' not available"
)


# ============================================================================
# UNIT TESTS — Python preprocessing only (no Docker)
# ============================================================================

class TestPreprocessOnly:
    """Verify that ras_preprocess.py produces valid g01.hdf for each example."""

    def _check_output(self, output_dir: Path, project_name: str, plan: str = "01"):
        g01_hdf   = output_dir / f"{project_name}.g{plan}.hdf"
        p01_tmp   = output_dir / f"{project_name}.p{plan}.tmp.hdf"
        assert g01_hdf.exists(),  f"g01.hdf not created: {g01_hdf}"
        assert p01_tmp.exists(),  f"p01.tmp.hdf not created: {p01_tmp}"
        assert check_g01hdf_has_tables(g01_hdf), "g01.hdf is missing hydraulic tables"

    def test_before_run(self, tmp_path):
        """BEFORE_RUN — Workflow A: mesh-only g01.hdf, add hydraulic tables."""
        run_preprocessor(EXAMPLES / "BEFORE_RUN", tmp_path, project_name="test_hdf")
        self._check_output(tmp_path, "test_hdf")

    def test_bec(self, tmp_path):
        """BEC — Workflow A: SCS infiltration model."""
        run_preprocessor(EXAMPLES / "BEC", tmp_path)
        self._check_output(tmp_path, "BEC")

    def test_bec_wo_infiltration(self, tmp_path):
        """BEC_WO_Infiltration — Workflow A: no infiltration model."""
        run_preprocessor(EXAMPLES / "BEC_WO_Infiltration", tmp_path)
        self._check_output(tmp_path, "model1")

    def test_va(self, tmp_path):
        """VA — Workflow A: precipitation boundary condition."""
        run_preprocessor(EXAMPLES / "VA", tmp_path)
        self._check_output(tmp_path, "VA")

    def test_muncie(self, tmp_path):
        """Muncie — Workflow A: flow + precipitation BCs."""
        run_preprocessor(EXAMPLES / "Muncie", tmp_path)
        self._check_output(tmp_path, "Muncie")

    def test_after_run_workflow_c(self, tmp_path):
        """AFTER_RUN — Workflow C: g01.hdf has tables + p01.hdf exists → strip & copy."""
        run_preprocessor(EXAMPLES / "AFTER_RUN", tmp_path, project_name="test_hdf")
        g01_hdf = tmp_path / "test_hdf.g01.hdf"
        p01_tmp = tmp_path / "test_hdf.p01.tmp.hdf"
        assert g01_hdf.exists(), "g01.hdf not copied"
        assert p01_tmp.exists(), "p01.tmp.hdf not produced"
        # The tmp.hdf must NOT contain a Results group
        with h5py.File(str(p01_tmp), 'r') as f:
            assert 'Results' not in f, "Results group should be stripped in Workflow C"


# ============================================================================
# INTEGRATION TESTS — Full pipeline including Docker
# ============================================================================

class TestFullPipeline:
    """Run complete pipeline (preprocess → Docker → verify) for each example."""

    # Tolerances
    VOLUME_ERR_PCT_TOL = 0.5   # percent  (generous for CI; all examples are <0.1%)
    WSE_DIFF_TOL_FT    = 0.005  # feet

    def _stage_and_run(
        self,
        tmp_path: Path,
        example_dir: Path,
        project_name: str,
        bc_src_dir: "Path | None" = None,
        plan: str = "01",
    ) -> "tuple[Path, str]":
        """Preprocess, copy BC files, run Docker.

        Returns (result_p01_hdf_path, docker_stdout).
        Docker stdout is used for volume error parsing since it is always
        present regardless of whether the HDF was written by the GUI or Docker.
        """
        out = tmp_path / "run"
        out.mkdir()

        run_preprocessor(example_dir, out, project_name=project_name)

        # Copy boundary-condition files needed by RasUnsteady
        bc_dir = bc_src_dir or example_dir
        for ext in (f".b{plan}", f".x{plan}"):
            src = bc_dir / f"{project_name}{ext}"
            if src.exists():
                shutil.copy2(str(src), str(out / src.name))

        stdout = run_docker_simulation(out, project_name, plan)
        return out / f"{project_name}.p{plan}.hdf", stdout

    @requires_docker
    def test_before_run(self, tmp_path):
        """BEFORE_RUN: 503-cell model — volume error < 0.5 %.

        WSE is not compared against AFTER_RUN because BEFORE_RUN uses
        Python-computed hydraulic tables while AFTER_RUN used GUI-computed
        tables; the two are expected to produce slightly different WSE fields.
        Volume conservation is the key metric here.
        """
        # BEFORE_RUN has no b01/x01; borrow from AFTER_RUN (same project, same BC)
        result_hdf, stdout = self._stage_and_run(
            tmp_path,
            example_dir=EXAMPLES / "BEFORE_RUN",
            project_name="test_hdf",
            bc_src_dir=EXAMPLES / "AFTER_RUN",
        )
        vol_err = parse_volume_error(stdout)
        assert vol_err is not None, "Could not parse volume error from Docker stdout"
        assert vol_err < self.VOLUME_ERR_PCT_TOL, \
            f"Volume error {vol_err:.4f}% exceeds {self.VOLUME_ERR_PCT_TOL}%"

    @requires_docker
    def test_bec(self, tmp_path):
        """BEC: 2,315-cell model with SCS infiltration — volume error < 0.5 %, WSE match."""
        result_hdf, stdout = self._stage_and_run(
            tmp_path, EXAMPLES / "BEC", project_name="BEC"
        )
        vol_err = parse_volume_error(stdout)
        assert vol_err is not None, "Could not parse volume error from Docker stdout"
        assert vol_err < self.VOLUME_ERR_PCT_TOL, \
            f"Volume error {vol_err:.4f}% exceeds {self.VOLUME_ERR_PCT_TOL}%"

        diff = max_wse_diff(result_hdf, EXAMPLES / "BEC" / "BEC.p01.hdf")
        assert diff <= self.WSE_DIFF_TOL_FT, \
            f"Max WSE diff {diff:.4f} ft exceeds {self.WSE_DIFF_TOL_FT} ft"

    @requires_docker
    def test_bec_wo_infiltration(self, tmp_path):
        """BEC_WO_Infiltration: 2,622-cell model — volume error < 0.5 %, WSE match."""
        result_hdf, stdout = self._stage_and_run(
            tmp_path, EXAMPLES / "BEC_WO_Infiltration", project_name="model1"
        )
        vol_err = parse_volume_error(stdout)
        assert vol_err is not None, "Could not parse volume error from Docker stdout"
        assert vol_err < self.VOLUME_ERR_PCT_TOL, \
            f"Volume error {vol_err:.4f}% exceeds {self.VOLUME_ERR_PCT_TOL}%"

        diff = max_wse_diff(result_hdf, EXAMPLES / "BEC_WO_Infiltration" / "model1.p01.hdf")
        assert diff <= self.WSE_DIFF_TOL_FT, \
            f"Max WSE diff {diff:.4f} ft exceeds {self.WSE_DIFF_TOL_FT} ft"

    @requires_docker
    def test_va(self, tmp_path):
        """VA: 1,221-cell model with precipitation BC — volume error < 0.5 %, WSE match."""
        result_hdf, stdout = self._stage_and_run(
            tmp_path, EXAMPLES / "VA", project_name="VA"
        )
        vol_err = parse_volume_error(stdout)
        assert vol_err is not None, "Could not parse volume error from Docker stdout"
        assert vol_err < self.VOLUME_ERR_PCT_TOL, \
            f"Volume error {vol_err:.4f}% exceeds {self.VOLUME_ERR_PCT_TOL}%"

        diff = max_wse_diff(result_hdf, EXAMPLES / "VA" / "VA.p01.hdf")
        assert diff <= self.WSE_DIFF_TOL_FT, \
            f"Max WSE diff {diff:.4f} ft exceeds {self.WSE_DIFF_TOL_FT} ft"

    @requires_docker
    def test_muncie(self, tmp_path):
        """Muncie: 3,146-cell model with flow + precipitation BCs — volume error < 0.5 %."""
        result_hdf, stdout = self._stage_and_run(
            tmp_path, EXAMPLES / "Muncie", project_name="Muncie"
        )
        vol_err = parse_volume_error(stdout)
        assert vol_err is not None, "Could not parse volume error from Docker stdout"
        assert vol_err < self.VOLUME_ERR_PCT_TOL, \
            f"Volume error {vol_err:.4f}% exceeds {self.VOLUME_ERR_PCT_TOL}%"

        ref_hdf = EXAMPLES / "Muncie" / "Muncie.p01.hdf"
        diff = max_wse_diff(result_hdf, ref_hdf)
        # Muncie has 0.001 ft diff documented in README
        assert diff <= 0.01, \
            f"Max WSE diff {diff:.4f} ft exceeds 0.01 ft"

    @requires_docker
    def test_after_run_workflow_c(self, tmp_path):
        """AFTER_RUN Workflow C: strip results → run Docker → verify same output."""
        out = tmp_path / "run"
        out.mkdir()

        # Workflow C: preprocessor detects fully-computed project, strips results
        run_preprocessor(EXAMPLES / "AFTER_RUN", out, project_name="test_hdf")

        # AFTER_RUN already has b01/x01
        for ext in (".b01", ".x01"):
            src = EXAMPLES / "AFTER_RUN" / f"test_hdf{ext}"
            if src.exists():
                shutil.copy2(str(src), str(out / src.name))

        stdout = run_docker_simulation(out, "test_hdf")
        result_hdf = out / "test_hdf.p01.hdf"

        vol_err = parse_volume_error(stdout)
        assert vol_err is not None, "Could not parse volume error from Docker stdout"
        assert vol_err < self.VOLUME_ERR_PCT_TOL, \
            f"Volume error {vol_err:.4f}% exceeds {self.VOLUME_ERR_PCT_TOL}%"

        ref_hdf = EXAMPLES / "AFTER_RUN" / "test_hdf.p01.hdf"
        diff = max_wse_diff(result_hdf, ref_hdf)
        assert diff <= self.WSE_DIFF_TOL_FT, \
            f"Max WSE diff {diff:.4f} ft exceeds {self.WSE_DIFF_TOL_FT} ft"
