<#
.SYNOPSIS
    Builds the VmLoader-compatible kphlib/kphdyn.xml (configuration version 20 layout).

.DESCRIPTION
    Upstream System Informer's kphdyn.xml is the authoritative list of supported kernels, but its
    fields records do not contain the extra members that the "firmware symbol support" patch adds
    to KPH_DYN_KERNEL_FIELDS (ExpFirmwareTable*, the Psp/Cm callback globals, and a few structure
    offsets). This script takes every upstream record and adds those members:

      * from a reference manifest (for example the previous version of this file) when the same
        arch/file/timestamp/size identity already has a complete record, otherwise
      * by downloading the exact kernel image from the Microsoft symbol server, checking it against
        the upstream SHA-256, and resolving the members from its public PDB with cdb.exe.

    Kernel records that only exist in a reference manifest are kept. Fields records are
    de-duplicated and renumbered in the output.

.EXAMPLE
    .\Update-VmLoaderDynData.ps1 -ReferenceManifest ..\..\kphlib\kphdyn.xml -OutputManifest ..\..\kphlib\kphdyn.xml
#>
[CmdletBinding()]
param(
    # Path or URL of upstream System Informer kphlib/kphdyn.xml.
    [string]$UpstreamManifest = 'https://raw.githubusercontent.com/winsiderss/systeminformer/master/kphlib/kphdyn.xml',

    # Manifests that already contain the VmLoader members; values are reused by exact kernel identity.
    [string[]]$ReferenceManifest = @(),

    [Parameter(Mandatory = $true)]
    [string]$OutputManifest,

    [string]$WorkDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmloader-dyndata'),

    [string]$SymbolServer = 'https://msdl.microsoft.com/download/symbols',

    [string]$DebuggerPath = (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'),

    [ValidateRange(1, 32)]
    [int]$ThrottleLimit = 4,

    # Re-resolve this many reused records from symbols and fail if any value differs.
    [ValidateRange(0, 1000)]
    [int]$VerifyCount = 0,

    # Keep downloaded kernel images and PDBs under WorkDirectory.
    [switch]$KeepDownloads
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$KernelFiles = @('ntoskrnl.exe', 'ntkrla57.exe')

$StructFields = @(
    @{ Name = 'OtTypeLock'; Type = '_OBJECT_TYPE'; Member = 'TypeLock'; Bit = $false },
    @{ Name = 'OtCallbackList'; Type = '_OBJECT_TYPE'; Member = 'CallbackList'; Bit = $false },
    @{ Name = 'EpProtection'; Type = '_EPROCESS'; Member = 'Protection'; Bit = $false },
    @{ Name = 'EpCookie'; Type = '_EPROCESS'; Member = 'Cookie'; Bit = $false },
    # Stored as a bit offset: byte offset * 8 + bit position.
    @{ Name = 'EpBreakOnTermination'; Type = '_EPROCESS'; Member = 'BreakOnTermination'; Bit = $true },
    @{ Name = 'KpDirectoryTableBase'; Type = '_KPROCESS'; Member = 'DirectoryTableBase'; Bit = $false }
)

$GlobalFields = @(
    'PspCreateProcessNotifyRoutine',
    'PspLoadImageNotifyRoutine',
    'PspCreateThreadNotifyRoutine',
    'ExReferenceCallBackBlock',
    'ExDereferenceCallBackBlock',
    'PspEnumerateCallback',
    'CmpEnumerateCallback',
    'ExpFirmwareTableResource',
    'ExpFirmwareTableProviderListHead'
)

$ExtraFieldNames = @($StructFields | ForEach-Object { $_.Name }) + $GlobalFields

function Read-SafeXmlDocument {
    param([Parameter(Mandatory = $true)][string]$Path)

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.IgnoreComments = $true
    $settings.IgnoreWhitespace = $true
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        $document.Load($reader)
    }
    finally {
        $reader.Dispose()
    }
    return $document
}

function ConvertFrom-Hex {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value) -or -not $Value.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid hexadecimal value '$Value'."
    }
    return [UInt32]::Parse($Value.Substring(2), [Globalization.NumberStyles]::HexNumber,
        [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Identity {
    param([System.Xml.XmlElement]$Data)

    return '{0}|{1}|{2:X8}|{3:X8}' -f $Data.GetAttribute('arch').ToLowerInvariant(),
        $Data.GetAttribute('file').ToLowerInvariant(),
        (ConvertFrom-Hex $Data.GetAttribute('timestamp')),
        (ConvertFrom-Hex $Data.GetAttribute('size'))
}

function Get-FieldsMap {
    param([System.Xml.XmlDocument]$Document)

    $map = @{}
    foreach ($fields in $Document.SelectNodes('/dyn/fields')) {
        $values = [ordered]@{}
        foreach ($field in $fields.SelectNodes('field')) {
            $values[$field.GetAttribute('name')] = $field.GetAttribute('value')
        }
        $map[$fields.GetAttribute('id')] = $values
    }
    return $map
}

function Test-CompleteExtras {
    param($Values)

    foreach ($name in $ExtraFieldNames) {
        if (-not $Values.Contains($name)) {
            return $false
        }
    }
    return $true
}

function Format-FieldValue {
    param([string]$Name, [UInt32]$Value)

    if ($GlobalFields -contains $Name) {
        return '0x{0:x}' -f $Value
    }
    return '0x{0:x4}' -f $Value
}

$ResolveKernel = {
    param($Entry, $WorkDirectory, $SymbolServer, $DebuggerPath, $StructFields, $GlobalFields, $KeepDownloads)

    $ErrorActionPreference = 'Stop'
    $result = @{ Identity = $Entry.Identity; Values = @{}; Error = $null }
    $directory = Join-Path $WorkDirectory ('kernels\{0}\{1}_{2:X8}_{3:X}' -f
        $Entry.Arch, [IO.Path]::GetFileNameWithoutExtension($Entry.File), $Entry.TimeDateStamp, $Entry.SizeOfImage)
    try {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        $image = Join-Path $directory $Entry.File

        if (-not (Test-Path -LiteralPath $image)) {
            $url = '{0}/{1}/{2:X8}{3:x}/{1}' -f $SymbolServer.TrimEnd('/'), $Entry.File, $Entry.TimeDateStamp, $Entry.SizeOfImage
            $temporary = "$image.download"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $temporary -UserAgent 'Microsoft-Symbol-Server/10.0.0.0'
            Move-Item -LiteralPath $temporary -Destination $image -Force
        }

        $bytes = [IO.File]::ReadAllBytes($image)
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
        if ([BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550 -or
            [BitConverter]::ToUInt32($bytes, $peOffset + 8) -ne $Entry.TimeDateStamp -or
            [BitConverter]::ToUInt32($bytes, $peOffset + 24 + 56) -ne $Entry.SizeOfImage) {
            throw 'Downloaded image does not match the expected PE identity.'
        }
        if ($Entry.Sha256) {
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $hash = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
            }
            finally {
                $sha.Dispose()
            }
            if ($hash -ne $Entry.Sha256.ToLowerInvariant()) {
                throw "Downloaded image SHA-256 $hash does not match upstream $($Entry.Sha256)."
            }
        }

        $module = [IO.Path]::GetFileNameWithoutExtension($Entry.File)
        $commands = New-Object System.Collections.Generic.List[string]
        foreach ($name in $GlobalFields) {
            $commands.Add(".printf `"VMLDD_G $name %p\n`", $module!$name - $module")
        }
        foreach ($group in ($StructFields | Group-Object { $_.Type })) {
            $commands.Add(".echo VMLDD_T $($group.Name)")
            $commands.Add("dt $module!$($group.Name) " + (($group.Group | ForEach-Object { $_.Member }) -join ' '))
        }
        $commands.Add('q')
        $commandFile = Join-Path $directory 'commands.txt'
        [IO.File]::WriteAllLines($commandFile, $commands)

        $symbols = Join-Path $directory 'sym'
        $output = & $DebuggerPath -z $image -y "srv*$symbols*$SymbolServer" -c "`$`$<$commandFile" 2>&1 | ForEach-Object { "$_" }
        [IO.File]::WriteAllLines((Join-Path $directory 'cdb.log'), [string[]]$output)

        $values = @{}
        $type = $null
        $members = @{}
        foreach ($line in $output) {
            if ($line -match '^VMLDD_G (\w+) ([0-9a-fA-F`]+)$') {
                $values[$Matches[1]] = [Convert]::ToUInt64($Matches[2].Replace('`', ''), 16)
            }
            elseif ($line -match '^VMLDD_T (\w+)$') {
                $type = $Matches[1]
            }
            elseif ($type -and $line -match '^\s+\+0x([0-9a-fA-F]+) (\w+)\s+: (?:Pos (\d+), )?') {
                $members["$type.$($Matches[2])"] = @{
                    Offset = [Convert]::ToUInt32($Matches[1], 16)
                    Bit = if ($Matches[3]) { [UInt32]$Matches[3] } else { $null }
                }
            }
        }

        foreach ($name in $GlobalFields) {
            if ($values.ContainsKey($name) -and $values[$name] -gt 0 -and $values[$name] -lt $Entry.SizeOfImage) {
                $result.Values[$name] = [UInt32]$values[$name]
            }
        }
        foreach ($field in $StructFields) {
            $member = $members["$($field.Type).$($field.Member)"]
            if (-not $member -or ($field.Bit -and $null -eq $member.Bit)) {
                continue
            }
            $value = $member.Offset
            if ($field.Bit) {
                $value = [UInt32]($member.Offset * 8 + $member.Bit)
            }
            if ($value -lt 0xffff) {
                $result.Values[$field.Name] = [UInt32]$value
            }
        }

        if ($result.Values.Count -eq 0) {
            throw 'No symbols resolved (PDB unavailable?).'
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        if (-not $KeepDownloads -and (Test-Path -LiteralPath $directory)) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $result
}

function Invoke-Resolution {
    param([object[]]$Entries)

    $results = @{}
    if (-not $Entries -or $Entries.Count -eq 0) {
        return $results
    }

    $queue = New-Object System.Collections.Queue
    $Entries | ForEach-Object { $queue.Enqueue($_) }
    $jobs = New-Object System.Collections.Generic.List[object]
    $completed = 0
    while ($queue.Count -gt 0 -or $jobs.Count -gt 0) {
        while ($queue.Count -gt 0 -and $jobs.Count -lt $ThrottleLimit) {
            $entry = $queue.Dequeue()
            $jobs.Add((Start-Job -ScriptBlock $ResolveKernel -ArgumentList $entry, $WorkDirectory,
                $SymbolServer, $DebuggerPath, $StructFields, $GlobalFields, [bool]$KeepDownloads))
        }
        $done = Wait-Job -Job $jobs.ToArray() -Any
        foreach ($job in @($jobs | Where-Object { $_.State -ne 'Running' })) {
            $result = Receive-Job -Job $job
            Remove-Job -Job $job
            [void]$jobs.Remove($job)
            $completed++
            $results[$result.Identity] = $result
            $status = if ($result.Error) { "FAILED: $($result.Error)" } else { "$($result.Values.Count) fields" }
            Write-Host ("[{0}/{1}] {2} {3}" -f $completed, $Entries.Count, $result.Identity, $status)
        }
    }
    return $results
}

if (-not (Test-Path -LiteralPath $DebuggerPath)) {
    throw "cdb.exe not found at $DebuggerPath (install Debugging Tools for Windows or pass -DebuggerPath)."
}
New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
$WorkDirectory = (Resolve-Path -LiteralPath $WorkDirectory).Path
# symsrv cannot write below MAX_PATH: <work>\kernels\<arch>\<name>\sym\<pdb>\<guid+age>\<pdb> must fit.
if ($WorkDirectory.Length -gt 120) {
    throw "WorkDirectory '$WorkDirectory' is too long for the symbol cache; use a shorter path."
}

if ($UpstreamManifest -match '^https?://') {
    $upstreamPath = Join-Path $WorkDirectory 'upstream-kphdyn.xml'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri $UpstreamManifest -OutFile $upstreamPath -Headers @{ 'Cache-Control' = 'no-cache' }
}
else {
    $upstreamPath = (Resolve-Path -LiteralPath $UpstreamManifest).Path
}
$upstream = Read-SafeXmlDocument $upstreamPath
$upstreamFields = Get-FieldsMap $upstream

# Reference values: identity -> complete field set (first manifest wins).
$referenceRecords = [ordered]@{}
foreach ($path in $ReferenceManifest) {
    $reference = Read-SafeXmlDocument (Resolve-Path -LiteralPath $path).Path
    $referenceFields = Get-FieldsMap $reference
    foreach ($data in $reference.SelectNodes('/dyn/data')) {
        if ($KernelFiles -notcontains $data.GetAttribute('file')) {
            continue
        }
        $identity = Get-Identity $data
        $values = $referenceFields[$data.InnerText.Trim()]
        if (-not $referenceRecords.Contains($identity) -and $values -and (Test-CompleteExtras $values)) {
            $referenceRecords[$identity] = @{ Data = $data; Values = $values }
        }
    }
}

$records = New-Object System.Collections.Generic.List[object]
$seen = @{}
$pending = New-Object System.Collections.Generic.List[object]
$reused = 0
foreach ($data in $upstream.SelectNodes('/dyn/data')) {
    $identity = Get-Identity $data
    if ($seen.ContainsKey($identity)) {
        continue
    }
    $seen[$identity] = $true

    $values = [ordered]@{}
    foreach ($pair in $upstreamFields[$data.InnerText.Trim()].GetEnumerator()) {
        $values[$pair.Key] = $pair.Value
    }
    $record = @{ Identity = $identity; Data = $data; Values = $values }
    $records.Add($record)

    if ($KernelFiles -notcontains $data.GetAttribute('file')) {
        continue
    }
    if ($referenceRecords.Contains($identity)) {
        $referenceValues = $referenceRecords[$identity].Values
        foreach ($name in $ExtraFieldNames) {
            $values[$name] = $referenceValues[$name]
        }
        $reused++
    }
    else {
        $pending.Add($record)
    }
}

# Keep kernel records that only the reference manifests know about.
$referenceOnly = 0
foreach ($identity in $referenceRecords.Keys) {
    if (-not $seen.ContainsKey($identity)) {
        $seen[$identity] = $true
        $records.Add(@{ Identity = $identity; Data = $referenceRecords[$identity].Data; Values = $referenceRecords[$identity].Values })
        $referenceOnly++
    }
}

function New-ResolveEntry {
    param($Record)

    $data = $Record.Data
    $sha = $data.GetAttribute('sha256')
    if (-not $sha) {
        $sha = $data.GetAttribute('hash')
    }
    return [pscustomobject]@{
        Identity = $Record.Identity
        Arch = $data.GetAttribute('arch')
        File = $data.GetAttribute('file')
        TimeDateStamp = ConvertFrom-Hex $data.GetAttribute('timestamp')
        SizeOfImage = ConvertFrom-Hex $data.GetAttribute('size')
        Sha256 = $sha
    }
}

Write-Host "Upstream records: $($records.Count - $referenceOnly); reused: $reused; to resolve: $($pending.Count); reference-only kept: $referenceOnly."

$verifyFailures = 0
if ($VerifyCount -gt 0) {
    $sample = @($records | Where-Object {
            $KernelFiles -contains $_.Data.GetAttribute('file') -and $referenceRecords.Contains($_.Identity) }) |
        Get-Random -Count $VerifyCount
    Write-Host "Verifying $($sample.Count) reused records against symbols..."
    $verification = Invoke-Resolution @($sample | ForEach-Object { New-ResolveEntry $_ })
    foreach ($record in $sample) {
        $result = $verification[$record.Identity]
        if ($result.Error) {
            Write-Warning "Verification skipped for $($record.Identity): $($result.Error)"
            continue
        }
        foreach ($name in $ExtraFieldNames) {
            if ($result.Values.ContainsKey($name) -and
                (ConvertFrom-Hex $record.Values[$name]) -ne $result.Values[$name]) {
                Write-Warning ("Mismatch {0} {1}: manifest {2}, symbols 0x{3:x}" -f
                    $record.Identity, $name, $record.Values[$name], $result.Values[$name])
                $verifyFailures++
            }
        }
    }
    if ($verifyFailures -gt 0) {
        throw "$verifyFailures reused values disagree with symbols; refusing to write the manifest."
    }
}

$resolution = Invoke-Resolution @($pending | ForEach-Object { New-ResolveEntry $_ })
$unsupported = New-Object System.Collections.Generic.List[string]
foreach ($record in $pending) {
    $result = $resolution[$record.Identity]
    if (-not $result.Error) {
        foreach ($name in $ExtraFieldNames) {
            if ($result.Values.ContainsKey($name)) {
                $record.Values[$name] = Format-FieldValue $name $result.Values[$name]
            }
        }
    }

    $firmwareOk = $record.Values.Contains('ExpFirmwareTableResource') -and
        $record.Values.Contains('ExpFirmwareTableProviderListHead') -and
        $record.Values['ExpFirmwareTableResource'] -ne $record.Values['ExpFirmwareTableProviderListHead']
    if (-not $firmwareOk) {
        $record.Values.Remove('ExpFirmwareTableResource')
        $record.Values.Remove('ExpFirmwareTableProviderListHead')
        $reason = if ($result.Error) { $result.Error } else { 'firmware symbols not found' }
        $unsupported.Add("$($record.Identity) ($($record.Data.GetAttribute('version'))): $reason")
    }
}

# De-duplicate fields records and write the manifest.
$fieldsIds = @{}
$fieldsList = New-Object System.Collections.Generic.List[object]
foreach ($record in $records) {
    $key = ($record.Values.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
    if (-not $fieldsIds.ContainsKey($key)) {
        $fieldsIds[$key] = $fieldsList.Count + 1
        $fieldsList.Add($record.Values)
    }
    $record.FieldsId = $fieldsIds[$key]
}

$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.IndentChars = '    '
$settings.Encoding = New-Object System.Text.UTF8Encoding($false)
$temporaryOutput = "$OutputManifest.tmp"
$writer = [System.Xml.XmlWriter]::Create($temporaryOutput, $settings)
try {
    $writer.WriteStartDocument()
    $writer.WriteStartElement('dyn')
    foreach ($record in $records) {
        $writer.WriteStartElement('data')
        foreach ($attribute in $record.Data.Attributes) {
            $writer.WriteAttributeString($attribute.Name, $attribute.Value)
        }
        $writer.WriteString([string]$record.FieldsId)
        $writer.WriteEndElement()
    }
    for ($index = 0; $index -lt $fieldsList.Count; $index++) {
        $writer.WriteStartElement('fields')
        $writer.WriteAttributeString('id', [string]($index + 1))
        foreach ($pair in $fieldsList[$index].GetEnumerator()) {
            $writer.WriteStartElement('field')
            $writer.WriteAttributeString('value', $pair.Value)
            $writer.WriteAttributeString('name', $pair.Key)
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
    }
    $writer.WriteEndElement()
    $writer.WriteEndDocument()
}
finally {
    $writer.Dispose()
}
Move-Item -LiteralPath $temporaryOutput -Destination $OutputManifest -Force

Write-Host "Wrote $OutputManifest`: $($records.Count) records, $($fieldsList.Count) fields records."
if ($unsupported.Count -gt 0) {
    Write-Warning "$($unsupported.Count) kernel records have no firmware fields (VmLoader will report them unsupported):"
    $unsupported | ForEach-Object { Write-Warning "  $_" }
}
