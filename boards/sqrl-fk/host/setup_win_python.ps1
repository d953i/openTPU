# The Windows host's Python for models (docs/sqrl-fk.md "Windows host"): build\venv-win of the repository (git-ignored),
# a virtual environment of a base Python 3.10+ (-BasePython, else python.org's py -3 or python on PATH, else the one AMD's
# 2025.2 tools ship; left unchanged) with
# requirements.txt (torch CPU, transformers, safetensors, tokenizers, huggingface_hub, textual, numpy).
# otpu-fk.cmd uses it when it exists. boards\sqrl-fk\windows\setup.cmd runs this (Linux: boards/sqrl-fk/linux/setup.sh).
#   powershell -ExecutionPolicy Bypass -File setup_win_python.ps1 [-BasePython <python.exe>] [-Model <id>[,<id>...]]
# -Model: also download those checkpoints into models\<name> (opentpu.llm.MODELS' directory names: Qwen/Qwen3.5-0.8B ->
# models\Qwen3.5-0.8B, the short name qwen35; a name without "/" is Qwen's: Qwen3.5-9B). setup.cmd runs it.
param(
    [string] $BasePython = '',
    [string[]] $Model = @()
)
$ErrorActionPreference = 'Stop'
if (-not $BasePython) {
    # a Python 3.10+: python.org's launcher (py -3), else python on PATH (not the Microsoft Store's stub), else the one
    # AMD's 2025.2 tools ship
    $cands = @()
    $py3 = Get-Command py -ErrorAction SilentlyContinue
    if ($py3) { $p = & py -3 -c "import sys; print(sys.executable)" 2>$null; if ($p) { $cands += $p.Trim() } }
    $cands += @(Get-Command python -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*WindowsApps*' } |
                ForEach-Object Source)
    $cands += 'C:\AMDDesignTools\2025.2\tps\win64\python-3.13.0\python.exe'
    foreach ($c in $cands) {
        if ($c -and (Test-Path $c)) {
            & $c -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
            if ($LASTEXITCODE -eq 0) { $BasePython = $c; break }
        }
    }
    if (-not $BasePython) {
        throw 'No Python 3.10 or later found. Install Python from https://www.python.org/downloads/ (tick "Add python.exe to PATH"), then run this again.'
    }
}
"Python: $BasePython"
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$venv = Join-Path $repo 'build\venv-win'
$py = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $py)) {
    & $BasePython -m venv $venv
    if ($LASTEXITCODE) { throw "venv from $BasePython failed" }
}
& $py -m pip install --disable-pip-version-check --only-binary ':all:' -r (Join-Path $PSScriptRoot 'requirements.txt')
if ($LASTEXITCODE) { throw 'pip install failed' }
& $py -c "import torch, transformers, safetensors, numpy; print('torch', torch.__version__, '| transformers', transformers.__version__, '| numpy', numpy.__version__)"
foreach ($m in ($Model | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })) {
    # (powershell -File passes "a,b" as one string: setup.cmd's list split here)
    if ($m -notmatch '/') { $m = "Qwen/$m" }            # (Qwen3.5-9B: Qwen/Qwen3.5-9B)
    $dir = Join-Path $repo ('models\' + ($m -split '/')[-1])
    if (Test-Path (Join-Path $dir 'config.json')) { "model: $dir (already there; hf completes a partial download)" }
    & (Join-Path $venv 'Scripts\hf.exe') download $m --local-dir $dir
    if ($LASTEXITCODE) { throw "hf download $m failed" }
    "model: $dir"
}
