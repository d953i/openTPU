# Shared by the SQRL FK step scripts in this folder (sourced, not run): the repository, its Python environment
# (build/venv-linux, 2-setup.sh makes it), the launcher boards/sqrl-fk/host/otpu_fk_run.py (the card's target found by
# itself, the largest context the card holds), and Vivado (any edition) for flashing.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VENV="${OTPU_VENV:-$REPO/build/venv-linux}"
PY="$VENV/bin/python"

need_venv() {
    if [ ! -x "$PY" ]; then
        echo "No Python environment yet: run  bash boards/sqrl-fk/linux/2-setup.sh  first." >&2
        exit 1
    fi
}

# run an openTPU tool through the launcher: fk -m opentpu.host.selftest ... | fk chat MODEL ... | fk serve MODEL ...
fk() {
    need_venv
    PYTHONPATH="$REPO${PYTHONPATH:+:$PYTHONPATH}" "$PY" "$REPO/boards/sqrl-fk/host/otpu_fk_run.py" "$@"
}

# the largest Qwen3.5 checkpoint in models/ (empty when there is none)
largest_model() {
    local m best=""
    for m in Qwen3.5-0.8B Qwen3.5-2B Qwen3.5-4B Qwen3.5-9B; do
        if [ -f "$REPO/models/$m/config.json" ]; then best=$m; fi
    done
    echo "$best"
}

# Vivado to load the image, any edition and version (the free Lab Edition too): $VIVADO, else 2019.2 (the build's) in
# the default install folders, else the newest other one there (/tools/Xilinx or /opt/Xilinx, either layout), else
# vivado_lab / vivado on PATH
find_vivado() {
    local v
    for v in "${VIVADO:-}" \
             /tools/Xilinx/Vivado_Lab/2019.2/bin/vivado_lab /opt/Xilinx/Vivado_Lab/2019.2/bin/vivado_lab \
             /tools/Xilinx/Vivado/2019.2/bin/vivado /opt/Xilinx/Vivado/2019.2/bin/vivado \
             $(ls -d /tools/Xilinx/Vivado*/*/bin/vivado* /opt/Xilinx/Vivado*/*/bin/vivado* \
                     /tools/Xilinx/*/Vivado*/bin/vivado* /opt/Xilinx/*/Vivado*/bin/vivado* 2>/dev/null | \
               grep -E '/vivado(_lab)?$' | sort -r) \
             "$(command -v vivado_lab || true)" "$(command -v vivado || true)"; do
        if [ -n "$v" ] && [ -x "$v" ]; then echo "$v"; return 0; fi
    done
    return 1
}

# flash PART DIR [CABLE | list]: write a prebuilt image to the card's flash over JTAG (boards/sqrl-fk/scripts/fk_flash.tcl)
flash() {
    local part=$1 dir=$2 viv work
    shift 2
    if ! viv=$(find_vivado); then
        echo "Vivado not found: install Vivado Lab Edition (free, from AMD; any version) or Vivado, or set VIVADO=/path/to/vivado_lab" >&2
        exit 1
    fi
    echo "Vivado: $viv"
    work=$(mktemp -d)
    (cd "$work" && "$viv" -mode batch -nojournal -nolog -source "$REPO/boards/sqrl-fk/scripts/fk_flash.tcl" \
                          -tclargs "$dir" "$part" "$@")
    rm -rf "$work"
    if [ "${1:-}" != "list" ]; then
        echo
        echo "Done. Power the PC off and on, then run  bash boards/sqrl-fk/linux/2-setup.sh"
        echo "(after 2-setup.sh has run once, a reflash needs only:  $VENV/bin/otpu-setup --rescan)"
    fi
}
