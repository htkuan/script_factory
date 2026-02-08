# Python Environment Management Rules

All Python script execution MUST use `uv` as the sole package manager and runtime executor. No exceptions.

## Execution Workflow

When running any Python script (including skills, automation, or one-off scripts), follow these steps **in order**. Stop immediately on failure and report the error to the user.

### Step 1: Verify uv is installed

```bash
which uv
```

- If uv is NOT found, **stop immediately** and display:
  > ❌ `uv` is not installed. Please install it first: https://docs.astral.sh/uv/getting-started/installation/
- Do NOT attempt to install uv automatically.

### Step 2: Ensure .venv exists

Check if `.venv/` directory exists in the project root.

- If `.venv/` does NOT exist, create it:
  ```bash
  uv venv .venv --python 3.12
  ```
- If `.venv/` already exists, skip this step.

### Step 3: Install dependencies

Check for dependency files and install accordingly:

- If `pyproject.toml` exists → `uv sync`
- If `requirements.txt` exists → `uv pip install -r requirements.txt`
- If neither exists but the script has third-party imports → create a `requirements.txt` first, then install via `uv pip install -r requirements.txt`
- If no external dependencies are needed, skip this step.

### Step 4: Verify config.json

Check if `config.json` exists in the expected location (project root unless specified otherwise).

- If `config.json` does NOT exist, **stop and ask the user** to provide or create one.
- Do NOT generate a default config.json without explicit user confirmation.

### Step 5: Execute with uv

ALWAYS run Python scripts using:

```bash
uv run python <script_path>
```

## Strict Prohibitions

- NEVER use bare `python`, `python3`, or `python3.x` to run scripts.
- NEVER use `pip`, `pip3`, `poetry`, `conda`, `pipenv`, or any other package manager.
- NEVER install packages globally or with `--break-system-packages`.
- NEVER create virtual environments with `python -m venv`.