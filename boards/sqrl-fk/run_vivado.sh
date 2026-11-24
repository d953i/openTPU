#!/usr/bin/env bash
# Build the openTPU bitstream for the SQRL Forest Kitten boards in Vivado batch mode (docs/sqrl-fk.md):
#   TARGET=sqrl-fk35 (the default: xcvu35p-fsvh2104-2-e) or sqrl-fk33 (xcvu33p-fsvh2104-2-e), 8 GB HBM2, PCIe x8.
# The knobs:
#   OUT_DIR (build/vivado_<TARGET>)   JOBS (8)   STEP=full|synth|impl (impl: the implementation of a finished
#   synthesis)   CORE_MHZ (the target's core_mhz)   UCLK_MHZ (450: the HBM's AXI ports, the bridges' AXI halves)
#   RLY (each bridge's pipeline N: the FK35 5, the FK33 0)   SET="K=V ..." (make_defines.py --set: otpu_board's
#   parameters)   PCIE_GEN=4|3 (Gen4 x8 or Gen3 x8; default the target's)   FP=hard|soft|none (sqrl_fk_floorplan.tcl)
#   FAST=1 (Vivado's default strategies)   IMPL_STRATEGY   PREFLIGHT=1|0   RQS=<file.rqs>   PRE_OPT=<file.tcl>
# Vivado 2019.2 builds it (its HBM and XDMA IPs; the VU33P / VU35P need a license that covers them). The bitstream
# is loaded over JTAG (Vivado's hardware manager) and the card's PCIe device rescanned; otpu_primary.mcs /
# otpu_secondary.mcs are the flash image (SPI x8, the card's two MT25QU256).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
target="${TARGET:-sqrl-fk35}"
out="${OUT_DIR:-$root/build/vivado_$target}"
jobs="${JOBS:-8}"
mkdir -p "$out"
args=("$out" --target "$target" --uclk-mhz "${UCLK_MHZ:-450}")
if [[ -n "${CORE_MHZ:-}" ]]; then args+=(--core-mhz "$CORE_MHZ"); fi
if [[ -n "${RLY:-}" ]]; then args+=(--rly "$RLY"); fi
for kv in ${SET:-}; do args+=(--set "$kv"); done
if [[ "${STEP:-full}" != impl ]]; then
  python3 "$here/scripts/make_defines.py" "${args[@]}"
fi
part="$(sed -n 's/^set PART //p' "$out/fk_params.tcl")"
export OTPU_IP_CACHE="${OTPU_IP_CACHE-$HOME/.cache/otpu-vivado-ip}"
export OTPU_FAST="${FAST:-0}"
export OTPU_FK_FP="${FP:-hard}"
export OTPU_FK_OUT="$out"
export OTPU_RQS="${RQS:-}"
export OTPU_PRE_OPT="${PRE_OPT:-}"
if [[ -n "${PCIE_GEN:-}" ]]; then export PCIE_GEN; fi
run() { local script="$1"; shift
  vivado -mode batch -nojournal -log "$out/$(basename "$script" .tcl).log" -source "$script" -tclargs "$@"; }
if [[ "${PREFLIGHT:-1}" != 0 ]]; then
  if ! command -v vivado > /dev/null; then
    echo "run_vivado: no vivado on PATH (source <Vivado 2019.2>/settings64.sh)" >&2; exit 2
  fi
  if ! (cd "$out" && vivado -mode batch -nojournal -nolog -source "$here/scripts/preflight.tcl" \
          -tclargs "$part") > "$out/preflight.log" 2>&1; then
    grep -E "PREFLIGHT|ERROR" "$out/preflight.log" >&2 || tail -20 "$out/preflight.log" >&2
    echo "run_vivado: preflight failed ($out/preflight.log); PREFLIGHT=0 skips it" >&2
    exit 2
  fi
  grep "PREFLIGHT ok" "$out/preflight.log" >&2
fi
case "${STEP:-full}" in
  impl)  run "$here/vivado/build.tcl" "$out" "$jobs" impl "${IMPL_STRATEGY:-}" ;;
  synth) run "$here/vivado/create_project.tcl" "$out"
         run "$here/vivado/build.tcl" "$out" "$jobs" synth ;;
  full)  run "$here/vivado/create_project.tcl" "$out"
         run "$here/vivado/build.tcl" "$out" "$jobs" full "${IMPL_STRATEGY:-}" ;;
  *)     echo "run_vivado: STEP ${STEP}: full, synth or impl" >&2; exit 2 ;;
esac
echo "done: $out"
