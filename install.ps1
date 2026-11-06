# xenon installer for windows. run it from the xenon folder:
#   powershell -ExecutionPolicy Bypass -File install.ps1
# it: checks rokit, installs lune (rokit.toml), adds bin\ to your user PATH, builds + installs the studio plugin.
# it changes nothing else. run it again any time (after git pull) to update.

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$bin = Join-Path $root "bin"

function Step($text) { Write-Host "`n> $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "  ok  $text" -ForegroundColor Green }
function Stop-With($text) {
	Write-Host "  !!  $text" -ForegroundColor Red
	exit 1
}

Write-Host "xenon installer" -ForegroundColor White
Write-Host "folder: $root"

# 1. rokit (installs lune for us)
Step "rokit"
if (-not (Get-Command rokit -ErrorAction SilentlyContinue)) {
	Write-Host "  rokit is not installed. install it, open a new terminal, run this again:"
	Write-Host "    https://github.com/rojo-rbx/rokit#installation"
	Stop-With "rokit missing"
}
Ok (rokit --version)

# 2. lune, pinned in this folder's rokit.toml
Step "lune (from rokit.toml)"
Push-Location $root
try {
	rokit install --no-trust-check
	if ($LASTEXITCODE -ne 0) { Stop-With "rokit install failed" }
	$lune = lune --version
	if ($LASTEXITCODE -ne 0) { Stop-With "lune does not run" }
	Ok $lune
} finally {
	Pop-Location
}

# 3. bin\ on the user PATH, so `xenon` works in any folder
Step "PATH"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }
$parts = $userPath.Split(";") | Where-Object { $_ -ne "" }
if ($parts -contains $bin) {
	Ok "already on PATH: $bin"
} else {
	$newPath = (@($parts) + $bin) -join ";"
	[Environment]::SetEnvironmentVariable("Path", $newPath, "User")
	Ok "added to your user PATH: $bin"
}
if (-not (($env:Path.Split(";")) -contains $bin)) { $env:Path = "$env:Path;$bin" }

# 4. studio plugin
Step "studio plugin"
& (Join-Path $bin "xenon.cmd") build
if ($LASTEXITCODE -ne 0) { Stop-With "plugin build failed" }

# 5. check
Step "check"
$version = & (Join-Path $bin "xenon.cmd") version
Ok $version

Write-Host "`ndone. next:" -ForegroundColor Green
Write-Host "  1. open a NEW terminal (so PATH is fresh)"
Write-Host "  2. restart Roblox Studio (loads the plugin)"
Write-Host "  3. new game:       xenon init my-game"
Write-Host "     existing game:  cd your-game-folder ; xenon serve"
