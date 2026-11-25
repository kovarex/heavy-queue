# heavy-queue's detached job (heavy.cmd --detach): started by WMI with the job file heavy.ps1 wrote, it takes
# the caller's folder and environment back, runs the job through heavy.cmd (queue, slot and pages as for any
# other) with its output in the log, then writes the exit code to LOG.exit and as the log's last line.
param([string]$jobFile)
$ErrorActionPreference = 'Stop'
$job = Get-Content -Raw -LiteralPath $jobFile | ConvertFrom-Json
Remove-Item -LiteralPath $jobFile -Force -ErrorAction SilentlyContinue
# (ROOT\detached\ID.PID.session while this process lives: the job's session, for lock\threads.ps1, which
# finds no record of the job between this file's removal and the job's own place in the line)
$sessionFile = ''
if ($job.session -match '^[\w-]+$')
{
  $sessionFile = [IO.Path]::ChangeExtension($jobFile, "$PID.session")
  try { [IO.File]::WriteAllText($sessionFile, "session $($job.session)") } catch { $sessionFile = '' }
}
$log = $job.log
function Append([string]$text) { [IO.File]::AppendAllText($log, $text + "`r`n", (New-Object System.Text.UTF8Encoding($false))) }
$code = 1
try
{
  # The environment WMI gave this process is the user's defaults: the caller's replaces it.
  foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator())
  {
    if ($null -eq $job.env.($e.Name)) { [Environment]::SetEnvironmentVariable([string]$e.Name, $null) }
  }
  foreach ($p in $job.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value) }
  $env:HEAVY_QUEUE_COMMAND = $job.line
  Set-Location -LiteralPath $job.cwd
  Append "heavy: detached job (pid $PID) in $($job.cwd), started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $($job.line)"
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $env:ComSpec
  $powershell = Join-Path $PSHOME 'powershell.exe'
  $info.Arguments = '/d /s /c ""' + $powershell + '" -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'heavy.ps1') + '" >> "' + $log + '" 2>&1 <nul"'
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.WorkingDirectory = $job.cwd
  $process = [System.Diagnostics.Process]::Start($info)
  $process.WaitForExit()
  $code = $process.ExitCode
}
catch { Append "heavy: the detached job could not run: $_" }
finally
{
  Append "heavy: detached job ended $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') with exit code $code."
  [IO.File]::WriteAllText("$log.exit", "$code`r`n", (New-Object System.Text.UTF8Encoding($false)))
  if ($sessionFile) { Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue }
}
exit $code
