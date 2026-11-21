---
name: ai-playground
description: Execute Python scripts and Jupyter notebooks on Google Colab virtual machine runtimes using the official colab CLI. Supports direct local/VM file staging, CPU/GPU/TPU hardware selection, local artifact retrieval, and automatic teardown. Triggers on "run on Colab", "colab で実行", "train on GPU", "Colab で学習", "ai-playground".
---

# ai-playground: Colab Experiment Runner

Run local Python scripts (`.py`) and Jupyter notebooks (`.ipynb`) on managed Google Colab VMs using the official `google-colab-cli`. The runner handles runtime provisioning, dependency installation, input file staging, code execution, artifact collection, log inspection, and VM teardown in a single reproducible lifecycle.

## Operator Approval Requirement

> [!IMPORTANT]
> **Operator confirmation is mandatory before execution.**
> You must obtain explicit operator approval before launching any live run that provisions a remote Colab VM, installs dependencies, or transfers files. Always present the script name, requested hardware (CPU, GPU, or TPU), timeout, staged input files, and output directory to the operator before proceeding.

## Input / Output Contract

The runner script is located at:
```bash
~/.agents/skills/ai-playground/scripts/run.py
```
(Also accessible via `~/.claude/skills/ai-playground/scripts/run.py`.)

### Arguments and Options

| Parameter | Type | Required | Description |
|---|---|---|---|
| `SCRIPT` | Positional | Yes | Path to local `.py` script or `.ipynb` notebook. |
| `--output-dir DIR` | Flag | Yes | Fresh, empty local directory for artifacts and logs. |
| `--input FILE` | Repeatable | No | Local input file staged to `/content/ai-playground/inputs/<leaf>`. |
| `--output NAME` | Repeatable | No | Declared leaf filename retrieved from `/content/ai-playground/outputs/<NAME>`. |
| `--requirements FILE`| Flag | No | Requirements file installed via `colab install` before execution. |
| `--gpu [TYPE]` | Flag / Value | No | Request GPU runtime (default accelerator: `T4`, e.g. `--gpu A100`). |
| `--tpu [TYPE]` | Flag / Value | No | Request TPU runtime (default accelerator: `v5e1`). |
| `--timeout SECS` | Flag | No | Positive execution timeout in seconds (default: `1800` / 30 min). |
| `--keep-on-failure` | Flag | No | Preserve VM and state on failure for debugging. |

### Remote Filesystem Layout

Inside the remote Colab virtual machine:
- Input files live at `/content/ai-playground/inputs/<filename>`.
- Code must write outputs to `/content/ai-playground/outputs/<filename>`.
- Contents API commands use paths relative to the VM root: `content/ai-playground/...`.

### Local Output Artifacts

All collected outputs and logs are written into `--output-dir`:
- Explicit declared output files (`--output <NAME>`).
- Preserved executed notebook (`<stem>_output.ipynb`) with executed cells and error tracebacks (even on failure).
- Structured execution event history (`execution.jsonl`).
- Result metadata (`run.json`).

The `run.json` document contains:
```json
{
  "session_name": "ai-playground-...",
  "requested_hardware": "cpu" | "gpu:<type>" | "tpu:<type>",
  "execution_outcome": "success" | "failure",
  "artifacts_collected": ["metrics.json", "model.pt", "..."],
  "vm_cleanup_outcome": "released" | "preserved" | "failed" | "uncertain"
}
```

## Usage Examples

### 1. Basic CPU Script Run
```bash
~/.agents/skills/ai-playground/scripts/run.py \
  scripts/preprocess.py \
  --output-dir results/run-01 \
  --input data/raw.csv \
  --output cleaned.csv
```

### 2. GPU Training with Requirements and Checkpoint Output
```bash
~/.agents/skills/ai-playground/scripts/run.py \
  models/train.py \
  --output-dir results/train-gpu-01 \
  --gpu T4 \
  --requirements requirements.txt \
  --input data/train.pt \
  --output weights.pt \
  --output metrics.json \
  --timeout 3600
```

### 3. Executing a Jupyter Notebook
```bash
~/.agents/skills/ai-playground/scripts/run.py \
  notebooks/eda.ipynb \
  --output-dir results/nb-run \
  --output report.png
```
*(The executed notebook with all cell outputs is preserved as `eda_output.ipynb` inside `results/nb-run/`.)*

### 4. Preserving VM for Debugging
```bash
~/.agents/skills/ai-playground/scripts/run.py \
  scripts/buggy_train.py \
  --output-dir results/debug-run \
  --gpu \
  --keep-on-failure
```

## Resumption & Limitations

- **Local-Only v1 Architecture**: Storage is strictly local. VMs are ephemeral and torn down upon completion. To resume training or continue an experiment, pass previously recovered artifacts (such as model checkpoints) as `--input` arguments to the next run.
- **Base64 Buffering**: The underlying Colab CLI transfers files individually using base64 buffering. Avoid extremely large binary transfers (> a few GB) without prior operator coordination.
- **No Unrequested Fallback**: If a requested accelerator (GPU/TPU) fails to allocate due to quota or availability, the runner immediately reports an error and aborts without silently falling back to a CPU runtime.

## Manual Recovery

When `--keep-on-failure` is active or if a VM teardown fails, the runner leaves its isolated private configuration intact and displays shell-safe recovery commands:

```bash
# Check runtime status
colab --config 'PATH_TO_SESSIONS_JSON' status -s 'SESSION_NAME'

# Download an artifact manually
colab --config 'PATH_TO_SESSIONS_JSON' download -s 'SESSION_NAME' content/ai-playground/outputs/FILENAME LOCAL_DEST

# Terminate and release the VM
colab --config 'PATH_TO_SESSIONS_JSON' stop -s 'SESSION_NAME'
```

## Setup & Prerequisites

The skill requires Python 3 (stdlib only) and the Google Colab CLI installed on the host:
```bash
# Recommended installation via uv
uv tool install google-colab-cli

# Or via pip
pip install google-colab-cli
```
Interactive authentication (`colab auth`) should be performed once by the operator prior to running automated jobs.
