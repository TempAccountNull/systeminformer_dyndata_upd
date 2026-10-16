<#
.SYNOPSIS
    One unattended refresh of the vmloader-kph dynamic data: update, regenerate, commit, push.

.DESCRIPTION
    1. Fast-forwards the local branch to the remote (refuses to run on a dirty tree or another branch).
    2. Runs Update-VmLoaderDynData.ps1 against the committed kphlib/kphdyn.xml.
    3. Stops (exit 0) when the manifest did not change.
    4. Builds CustomBuildTool and regenerates kphlib/kphdyn.c and kphlib/include/kphdyn.h.
    5. Commits the three generated files, listing new kernels, and fast-forward pushes.

    Every run writes a transcript under -LogDirectory (the newest 30 are kept).
    Exit code 0 means success or nothing to do; any failure exits 1.
#>
[CmdletBinding()]
param(
    # Defaults to the repository containing this script.
    [string]$RepositoryPath,

    [string]$Branch = 'vmloader-kph',

    [string]$Remote = 'origin',

    # Keep short: the symbol cache below it must stay under MAX_PATH.
    [string]$WorkDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmldd'),

    [string]$LogDirectory,

    [ValidateRange(0, 1000)]
    [int]$VerifyCount = 8,

    # kphtools nightly already carries the v20 members for most kernels; it is used as the first
    # reference and anything it lacks is resolved from symbols. Empty to skip.
    [string]$KphtoolsUri = 'https://github.com/HLND2T/kphtools/releases/download/nightly/kphdyn.xml',

    [string]$DebuggerPath = (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'),

    # .NET SDK target used to build CustomBuildTool (its project defaults to a newer TFM).
    [string]$TargetFramework = 'net9.0-windows7.0',

    [switch]$NoFetch,

    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# $PSScriptRoot is not available in Windows PowerShell parameter defaults.
if (-not $RepositoryPath) {
    $RepositoryPath = Join-Path $PSScriptRoot '..\..'
}
$RepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path
New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
if (-not $LogDirectory) {
    $LogDirectory = Join-Path $WorkDirectory 'logs'
}
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
Get-ChildItem -LiteralPath $LogDirectory -Filter 'refresh-*.log' |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 29 | Remove-Item -Force
$logFile = Join-Path $LogDirectory ('refresh-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
Start-Transcript -LiteralPath $logFile | Out-Null

# Arguments come from $args rather than a [string[]] parameter: Windows PowerShell would join an
# array argument into one string, while native invocation passes each array element separately.
function Invoke-Native {
    $FilePath = $args[0]
    $Arguments = @($args | Select-Object -Skip 1)

    # Windows PowerShell turns native stderr into terminating errors under 'Stop'.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed with exit code $exitCode."
    }
    return $output
}

function Invoke-Git {
    return Invoke-Native 'git' '-C' $RepositoryPath @args
}

function Get-KernelSummary {
    param([string]$Path)

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        $document.Load($reader)
    }
    finally {
        $reader.Dispose()
    }

    $firmwareIds = @{}
    foreach ($fields in $document.SelectNodes("/dyn/fields[field/@name='ExpFirmwareTableResource']")) {
        $firmwareIds[$fields.GetAttribute('id')] = $true
    }

    $summary = @{}
    foreach ($data in $document.SelectNodes('/dyn/data')) {
        $file = $data.GetAttribute('file')
        if ($file -ne 'ntoskrnl.exe' -and $file -ne 'ntkrla57.exe') {
            continue
        }
        $key = '{0}|{1}|{2}|{3}' -f $data.GetAttribute('arch'), $file,
            $data.GetAttribute('timestamp').ToLowerInvariant(), $data.GetAttribute('size').ToLowerInvariant()
        $summary[$key] = @{
            Label = '{0} {1} {2}' -f $data.GetAttribute('version'), $data.GetAttribute('arch'), $file
            Firmware = $firmwareIds.ContainsKey($data.InnerText.Trim())
        }
    }
    return $summary
}

$exitCode = 0
try {
    $manifestRelative = 'kphlib/kphdyn.xml'
    $manifest = Join-Path $RepositoryPath 'kphlib\kphdyn.xml'
    $generated = @($manifestRelative, 'kphlib/kphdyn.c', 'kphlib/include/kphdyn.h')

    $current = (Invoke-Git 'rev-parse' '--abbrev-ref' 'HEAD' | Select-Object -Last 1).Trim()
    if ($current -ne $Branch) {
        throw "Repository is on '$current', expected '$Branch'."
    }
    if (Invoke-Git 'status' '--porcelain' '--untracked-files=no') {
        throw 'Repository has uncommitted changes to tracked files; refusing to refresh.'
    }
    if (-not $NoFetch) {
        Invoke-Git 'fetch' $Remote $Branch | Out-Null
        Invoke-Git 'merge' '--ff-only' "$Remote/$Branch" | Out-Null
    }

    $before = Get-KernelSummary $manifest

    $references = @()
    if ($KphtoolsUri) {
        $kphtools = Join-Path $WorkDirectory 'kphtools-kphdyn.xml'
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri $KphtoolsUri -OutFile $kphtools -Headers @{ 'Cache-Control' = 'no-cache' }
            $references += $kphtools
            Write-Host "Using kphtools reference from $KphtoolsUri."
        }
        catch {
            Write-Warning "kphtools reference unavailable ($($_.Exception.Message)); resolving gaps from symbols only."
        }
    }
    $references += $manifest

    & (Join-Path $PSScriptRoot 'Update-VmLoaderDynData.ps1') `
        -ReferenceManifest $references `
        -OutputManifest $manifest `
        -WorkDirectory $WorkDirectory `
        -DebuggerPath $DebuggerPath `
        -VerifyCount $VerifyCount

    # Line-ending-only rewrites are not changes.
    Invoke-Git 'add' '--' $manifestRelative | Out-Null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $RepositoryPath diff --cached --quiet -- $manifestRelative 2>$null
    $changed = $LASTEXITCODE -ne 0
    $ErrorActionPreference = $previous
    if (-not $changed) {
        Invoke-Git 'reset' '-q' '--' $manifestRelative | Out-Null
        Invoke-Git 'checkout' '--' $manifestRelative | Out-Null
        Write-Host 'Dynamic data is already current; nothing to commit.'
        return
    }

    $after = Get-KernelSummary $manifest
    $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) } | ForEach-Object {
            $after[$_].Label + $(if (-not $after[$_].Firmware) { ' (no firmware fields)' } else { '' }) })
    $gained = @($after.Keys | Where-Object {
            $before.ContainsKey($_) -and -not $before[$_].Firmware -and $after[$_].Firmware } |
        ForEach-Object { $after[$_].Label })
    $removed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) } | ForEach-Object { $before[$_].Label })

    $toolOutput = Join-Path $WorkDirectory 'cbt'
    $toolIntermediate = Join-Path $WorkDirectory 'cbtobj'
    Invoke-Native 'dotnet' 'msbuild' (Join-Path $RepositoryPath 'tools\CustomBuildTool\CustomBuildTool.csproj') `
        '-restore' '-t:Build' '-p:Configuration=Release' '-p:Platform=x64' "-p:TargetFramework=$TargetFramework" `
        '-p:PublishAot=false' '-p:PublishReadyToRun=false' '-p:PublishSingleFile=false' '-p:SelfContained=false' `
        "-p:OutDir=$toolOutput\" "-p:IntDir=$toolIntermediate\" '-v:minimal' | Out-Null
    Push-Location $RepositoryPath
    try {
        $exe = Join-Path $toolOutput 'CustomBuildTool.exe'
        if (Test-Path -LiteralPath $exe) {
            Invoke-Native $exe '-dyndata' | Out-Null
        }
        else {
            Invoke-Native 'dotnet' (Join-Path $toolOutput 'CustomBuildTool.dll') '-dyndata' | Out-Null
        }
    }
    finally {
        Pop-Location
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("kph: refresh VmLoader dyndata ($($added.Count) new kernels)")
    $lines.Add('')
    $lines.Add('Automated run of tools/VmLoaderDynData/Invoke-VmLoaderDynDataRefresh.ps1.')
    foreach ($section in @(@('New kernels:', $added), @('Kernels that gained firmware fields:', $gained),
            @('Kernels no longer listed upstream:', $removed))) {
        if ($section[1].Count -gt 0) {
            $lines.Add('')
            $lines.Add($section[0])
            $section[1] | Sort-Object | Select-Object -First 60 | ForEach-Object { $lines.Add("- $_") }
            if ($section[1].Count -gt 60) {
                $lines.Add("- ... and $($section[1].Count - 60) more")
            }
        }
    }
    $messageFile = Join-Path $WorkDirectory 'commit-message.txt'
    [System.IO.File]::WriteAllLines($messageFile, $lines, (New-Object System.Text.UTF8Encoding($false)))

    Invoke-Git 'add' '--' $generated | Out-Null
    Invoke-Git 'commit' '-q' '-F' $messageFile | Out-Null
    Write-Host ("Committed {0}: {1} new, {2} gained firmware, {3} removed." -f
        (Invoke-Git 'rev-parse' '--short' 'HEAD' | Select-Object -Last 1), $added.Count, $gained.Count, $removed.Count)

    if (-not $NoPush) {
        Invoke-Git 'push' $Remote "HEAD:$Branch" | Out-Null
        Write-Host "Pushed to $Remote/$Branch."
    }
}
catch {
    Write-Host "Refresh failed: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    Stop-Transcript | Out-Null
}
exit $exitCode
