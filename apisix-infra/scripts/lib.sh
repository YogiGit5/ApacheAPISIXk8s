#!/usr/bin/env bash
# Shared helpers for all scripts

# Detect working Python command (python3 → python → py)
detect_python() {
  if python3 -c "import yaml" 2>/dev/null; then
    echo "python3"
  elif python -c "import yaml" 2>/dev/null; then
    echo "python"
  elif py -c "import yaml" 2>/dev/null; then
    echo "py"
  else
    echo ""
  fi
}

PYTHON_CMD=$(detect_python)
if [ -z "$PYTHON_CMD" ]; then
  echo "ERROR: Python with PyYAML is required." >&2
  echo "       Install with: pip install pyyaml  (or py -m pip install pyyaml)" >&2
  exit 1
fi

# Convert path to native format for Python (handles Git Bash /c/ → C:\ on Windows)
native_path() {
  if command -v cygpath &>/dev/null; then
    cygpath -w "$1"
  else
    echo "$1"
  fi
}
