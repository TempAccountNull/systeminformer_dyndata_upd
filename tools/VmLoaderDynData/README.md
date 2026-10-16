# VmLoader dynamic data

The `vmloader-kph` branch carries the "firmware symbol support" patch (configuration version 20),
which extends `KPH_DYN_KERNEL_FIELDS` with:

- structure offsets: `OtTypeLock`, `OtCallbackList`, `EpProtection`, `EpCookie`,
  `EpBreakOnTermination` (bit offset = byte offset * 8 + bit), `KpDirectoryTableBase`
- global RVAs: `PspCreateProcessNotifyRoutine`, `PspLoadImageNotifyRoutine`,
  `PspCreateThreadNotifyRoutine`, `ExReferenceCallBackBlock`, `ExDereferenceCallBackBlock`,
  `PspEnumerateCallback`, `CmpEnumerateCallback`, `ExpFirmwareTableResource`,
  `ExpFirmwareTableProviderListHead`

[VmwareHardenedLoader](https://github.com/hzqst/VmwareHardenedLoader) downloads
`kphlib/kphdyn.xml` from this branch at build time, so refreshing that file adds support for new
Windows kernels without changing the loader.

## Automatic refresh

`.github/workflows/vmloader-dyndata.yml` runs daily (23:23 UTC) and on demand (**Actions → VmLoader
dyndata refresh → Run workflow**). It calls `Invoke-VmLoaderDynDataRefresh.ps1`, which:

1. fast-forwards `vmloader-kph`,
2. runs `Update-VmLoaderDynData.ps1` with
   [kphtools nightly](https://github.com/HLND2T/kphtools/releases/tag/nightly) as the first reference
   and the committed manifest as the second, resolving anything both lack from public PDBs,
3. exits without a commit when the manifest is unchanged,
4. otherwise regenerates `kphdyn.c`/`kphdyn.h`, commits the three files with a list of new kernels,
   and pushes.

Each run uploads its transcript as the `vmloader-dyndata-log` artifact.

One-time repository settings this needs:

- **Settings → General → Default branch** must be `vmloader-kph` (GitHub only runs scheduled
  workflows from the default branch).
- **Actions** must be enabled for the fork (forks start with workflows disabled).

The same script runs locally, for example
`.\tools\VmLoaderDynData\Invoke-VmLoaderDynDataRefresh.ps1 -NoPush` to review a refresh before pushing.

## Refreshing kphlib/kphdyn.xml manually

Requirements: Windows, Debugging Tools for Windows (`cdb.exe`), and internet access to
`raw.githubusercontent.com` and `msdl.microsoft.com`.

```powershell
.\tools\VmLoaderDynData\Update-VmLoaderDynData.ps1 `
    -ReferenceManifest .\kphlib\kphdyn.xml `
    -OutputManifest .\kphlib\kphdyn.xml `
    -VerifyCount 8
```

The script:

1. Downloads upstream System Informer `kphlib/kphdyn.xml` (the list of supported kernels and their
   upstream structure offsets).
2. Reuses the extra members for kernels already present in the reference manifest(s).
3. For new kernels, downloads the exact image from the Microsoft symbol server, checks its PE
   timestamp/size and the upstream SHA-256, and resolves the extra members from the public PDB.
4. With `-VerifyCount N`, first re-resolves N reused records from symbols and refuses to write the
   manifest if any value disagrees.
5. Writes a de-duplicated manifest and lists kernels that still lack firmware fields (for example
   when Microsoft does not publish the image).

Keep `-WorkDirectory` short (the default `%TEMP%\vmloader-dyndata` is fine): the symbol cache path
must stay below `MAX_PATH`.

Then regenerate the embedded C source with CustomBuildTool (`-dyndata`) and commit
`kphlib/kphdyn.xml`, `kphlib/kphdyn.c`, and `kphlib/include/kphdyn.h`.
