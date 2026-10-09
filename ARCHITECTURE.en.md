# How LunqDebloater is built

Русский: [ARCHITECTURE.md](ARCHITECTURE.md)

This file is for people who change the code: where things are, in which order a build runs and how to add something without breaking it. How to use the script is in [README.en.md](README.en.md), the PR rules are in [CONTRIBUTING.md](CONTRIBUTING.md#contributing-in-english).

## Repository layout

```text
LunqDebloater.ps1            Entry point: parameters, step-by-step mode, plan and the list of build steps
Start.cmd                    Double-click launcher (step-by-step mode)
Config\                      Everything the user adjusts
  Profile.json               Profile: what to remove and what to write to the registry
  Apps.txt                   winget programs for the first sign-in
  Scripts\                   Own *.ps1 scripts for the first sign-in
  Drivers\                   .inf drivers (not stored in git)
  Updates\                   .msu/.cab updates (not stored in git)
    SafeOS\                  Safe OS Dynamic Update for WinRE
    Setup\                   Setup Dynamic Update for Windows Setup
  README.txt, README.en.txt  Guide to the Config folder
Modules\
  LunqDebloater\
    LunqDebloater.psd1       Manifest: version and exported functions
    LunqDebloater.psm1       Loads Private\*.ps1 and picks the language
    Private\*.ps1            Functions by topic (table below)
    Strings\ru\*.psd1        Interface texts in Russian
    Strings\en\*.psd1        The same keys in English
  FirstLogon\FirstLogon.ps1  First sign-in script that goes into the image
Schemas\Profile.schema.json  JSON schema of the profile for VS Code
Tests\                       Pester tests and stubs
.github\                     GitHub Actions, issue and PR templates
```

## The LunqDebloater module

`LunqDebloater.psm1` loads every `Private\*.ps1` in alphabetical order and picks the language from the system right away. Only the functions in the manifest's `FunctionsToExport` are visible outside. Tests reach the rest through `& (Get-Module LunqDebloater) { ... }`.

| File | Responsible for |
|---|---|
| `Console.ps1` | Output: `Write-Step` ("Step N of M"), `Write-Section`, `Write-Info`, `Write-Check`, `Read-YesNo`, `Format-Size` |
| `Language.ps1` | String tables and language: `Set-LunqLanguage`, `Get-LunqText`, `Get-LunqLocalized` for profile texts |
| `System.ps1` | Administrator rights, the log (`Start-LunqLog`), version, `Invoke-Native` for external programs, passing parameters on relaunch |
| `Profile.ps1` | Reading and validating the profile, choosing the profile and categories, merging the enabled categories into common lists (`Get-LunqEffectiveConfig`) |
| `Options.ps1` | The "What goes into the image" summary in step-by-step mode: items, their dependencies and toggling by number |
| `Iso.ps1` | Mounting the ISO, the list of editions, the image version and the profile requirements check, copying the ISO contents |
| `Checks.ps1` | Checks before the build: working folder, output ISO, disk space, leftovers of a previous run, Windows version on this computer |
| `Image.ps1` | Exporting the edition, recompressing a WIM (`Optimize-LunqWim`), component store cleanup, finding `oscdimg` and building the ISO |
| `Servicing.ps1` | Updates and drivers: into the system, into WinRE (`Update-LunqRecovery`) and into Windows Setup (`Update-LunqSetup`), Safe OS and Setup Dynamic Update |
| `Removal.ps1` | Removing Appx and capabilities, turning off features and removing CBS packages |
| `Registry.ps1` | Offline registry hives, setting and deleting values and keys, the build stamp in `HKLM\SOFTWARE\LunqDebloater` |
| `PostInstall.ps1` | First sign-in programs and scripts: copying them into the image, `unattend.xml` in Sysprep |
| `Unattend.ps1` | `autounattend.xml` in the ISO root: region, requirements bypass, local account |
| `Inventory.ps1` | "What is in the image" mode: the list of Appx, capabilities and features marked with profile categories |
| `Report.ps1` | Common step result format (`New-LunqResult`) and the build result (`Write-LunqReport`) |

## How a run goes

1. **Environment** (`LunqDebloater.ps1`). Outside Windows the script stops at once. In PowerShell 7 it relaunches itself in Windows PowerShell 5.1, because some DISM cmdlets do not work in 7. Without administrator rights it offers an elevated relaunch in step-by-step mode and simply stops when run with parameters. Paths are made absolute, since the new window may open in another folder.
2. **Log.** `Start-LunqLog` starts the log in `Logs` next to the script and a separate DISM log. Everything after that, including errors while choosing the ISO, goes into the log.
3. **Choices.** In step-by-step mode the user picks the action (build or "What is in the image"), the ISO, the profile and the categories. With parameters all of this comes from the parameters.
4. **Config contents.** Updates (`Get-LunqUpdateFiles`, with the `SafeOS` and `Setup` subfolders separately), drivers, programs and scripts are found. In step-by-step mode the `Select-LunqBuildOptions` summary lets the user turn them on and off.
5. **Checks** (`Test-LunqPrerequisites`): working folder, output ISO, space, `oscdimg`. An error stops the run before the long work starts.
6. **Edition and version.** The ISO is mounted once: list of editions, choice, version of the chosen one. `Test-LunqImageRequirements` compares the build with the profile's `Requirements`.
7. **"What is in the image" mode** (`-ListContents`) ends here: the edition is mounted read-only, `Write-LunqInventory` saves the list and the image is unmounted without saving.
8. **Plan.** The script shows what will be done and asks for confirmation in step-by-step mode.
9. **Build** by the list of steps (below), then the result from `Write-LunqReport`.
10. **On error** the registry hives are unloaded and the image is unmounted without saving. The working folder is deleted only if nothing is mounted in it, otherwise DISM would lose the image.

## Build steps

The steps are the `$buildSteps` list in `LunqDebloater.ps1`. Each one has `Title`, `Hint`, `When` (whether to run it) and `Run` (what to do). "Step N of M" is counted from `When`, so the numbers always go in a row. `Run` executes in the script scope and appends its result to `$results`.

| Step | What it does | When |
|---|---|---|
| Prepare | Clears the working folder (`Reset-LunqWorkDir`) | always |
| CopyIso | Copies the ISO contents to `WorkDir\iso` | always |
| Export | Exports the chosen edition to its own `install.wim` (ESD becomes WIM) | always |
| Mount | Mounts `install.wim` in `WorkDir\mount` | always |
| Updates | Installs updates in ascending KB order | there are updates |
| Drivers | Adds drivers one `.inf` at a time | there are drivers |
| Recovery | Services `Winre.wim` inside the system: updates, Safe OS DU, disk drivers | `-UpdatesToSetup` or `-DriversToSetup`, and there is something for WinRE |
| FirstLogon | Puts programs, scripts and `FirstLogon.ps1` into `Windows\Setup\Scripts\Lunq` | there are programs or scripts |
| Unattend | Puts `autounattend.xml` into the ISO root | answer file is on |
| Appx | Removes the profile's Appx | without `-SkipAppx` |
| Capabilities | Removes capabilities | without `-SkipComponents` |
| Features | Turns off features and removes CBS packages | without `-SkipComponents` |
| Registry | Applies the profile's registry entries | without `-SkipRegistry` |
| Cleanup | Cleans the component store (`dism /StartComponentCleanup /ResetBase`) | `-CleanupComponents` |
| Save | Writes the build stamp into the image registry and saves `install.wim` | always |
| Setup | Expands Setup DU into `sources`, services `boot.wim` (image 2), copies `setup.exe` and `setuphost.exe` out of it | there is something for Windows Setup |
| Recompress | Recompresses `install.wim` | always |
| Iso | Builds the bootable ISO with `oscdimg` | always |

The order matters: updates go in before components are removed, the answer file and the build stamp are written before the image is saved, and Windows Setup is serviced afterwards, because it lives in `WorkDir\iso` and not inside `install.wim`.

## Step results and the summary

Every step function returns a `New-LunqResult` object: `Title`, `Kind`, the lists `Done`, `Failed`, `Skipped`, `NotMatched`, a `Summary` line and `ByCategory` counters. `Write-LunqReport` prints them the same way for all steps: removals and the registry by profile category, everything else as "installed/added N, errors M". A failure of one package or driver goes into `Failed` and does not stop the build. A failure that makes it impossible to continue is thrown as an exception.

## Profile

`Read-LunqProfile` reads the JSON, validates the fields and the registry entries (type, number, action) and turns texts into the interface language with `Get-LunqLocalized`. `Get-LunqEffectiveConfig` merges the enabled categories into the common lists `Appx`, `Capabilities`, `Features`, `Packages` and `Registry`. Every registry entry keeps `LunqCategory`, so the summary is counted by category. Names are compared with `-like` patterns (`Test-NamePattern`), and patterns that found nothing go into `NotMatched`.

## Image registry

`Mount-OfflineHives` loads the hives of the mounted image under its own names and always unloads them in `finally`:

| Hive in the profile | Loaded as | File in the image |
|---|---|---|
| `SOFTWARE` | `HKLM\LUNQ_SOFTWARE` | `Windows\System32\config\SOFTWARE` |
| `SYSTEM` | `HKLM\LUNQ_SYSTEM` | `Windows\System32\config\SYSTEM` |
| `DefaultUser` | `HKLM\LUNQ_NTUSER` | `Users\Default\NTUSER.DAT` |

Loading and unloading go through `reg.exe`, while values are written through .NET (`Set-LunqRegistryValue`), so quotes and a trailing `\` are not mangled. Entry actions: set a value (the default), `DeleteValue`, `DeleteKey`.

## Interface texts

Everything the user sees comes from `Get-LunqText 'Area.Name' arguments...` and `Strings\<language>\<Area>.psd1`. The area matches the file name in `Private` (`Main` for the script itself). The string always goes through `-f`, so literal braces are doubled. The language is chosen with `-Language`, by default Russian on Russian Windows and English everywhere else.

`FirstLogon.ps1` runs in the installed system without the module, so its strings live in the `$texts` table inside the file. It reads the language from `Language.txt`, which `Install-LunqFirstLogon` writes.

## Tests

| File | What it checks |
|---|---|
| `Tests\Unit.Tests.ps1` | Single functions: profile, registry, checks, answer file, strings. It also makes sure the `ru` and `en` keys match, every key used in the code exists in the tables, and every parameter is documented in both READMEs |
| `Tests\Build.Tests.ps1` | End-to-end runs of `LunqDebloater.ps1` with parameters and in step-by-step mode, in Russian and English |
| `Tests\FirstLogon.Tests.ps1` | The first sign-in script in a separate process with a fake winget, network and task scheduler |
| `Tests\Registry.Tests.ps1` | Real registry writes (Windows only) |
| `Tests\TestHelpers.ps1` | A copy of the script in `TestDrive`, environment variables for the stubs, running it and parsing the steps |
| `Tests\Mocks\Dism\Dism.psm1` | Stub of the DISM module: mounts nothing and creates placeholder files where the script looks for them later |
| `Tests\Mocks\TestMocks.ps1` | Stubs of the module functions that touch the system: administrator rights, ISO mounting, disk space, `Invoke-Native` (robocopy, reg.exe, oscdimg, expand.exe) and registry writes. It is copied into the module of the script copy as `Private\ZZ.TestMocks.ps1` so it loads last |

The stubs are configured with `LUNQ_TEST_*` variables, for example `LUNQ_TEST_DISM_EXIT` (dism.exe exit code), `LUNQ_TEST_FAIL_APPX` (a failure in the middle of the build), `LUNQ_TEST_IMAGE_VERSION`, `LUNQ_TEST_HOST_BUILD`, `LUNQ_TEST_NOT_ADMIN`. Calls to external programs are written to `LUNQ_TEST_NATIVE_LOG`, registry writes to `LUNQ_TEST_REG_LOG`, and the tests check them. End-to-end tests run in Russian by default and compare the Russian output; the English tests check that the output has no Cyrillic.

## How to add

**A parameter.** Add it to `param()` in `LunqDebloater.ps1` and to the parameter table in `README.md` and `README.en.md` (a test checks this). If it is a path, add its name to `$pathParams` so it is passed as an absolute path on relaunch.

**A build step.** Add an entry to `$buildSteps` in the right place, the strings `Main.Step<Name>` and `Main.Step<Name>Hint` to both tables, and let `Run` append a `New-LunqResult` to `$results`. Update the expected step counts in `Tests\Build.Tests.ps1`.

**An interface string.** Add the key to `Strings\ru\<Area>.psd1` and `Strings\en\<Area>.psd1` with the same `{0}`, `{1}`. Keys in a table are aligned to the longest one.

**A profile entry.** Add the name to the right list of a category in `Config\Profile.json` (the lists are sorted), or add a new category with `Name` and `Description` in both languages. If the default profile behaves differently, update the category description and the "Profile" section in both READMEs.

**An external program.** Call it through `Invoke-Native`: that way stderr does not turn into an exception in 5.1, and tests can replace the call. Add a branch to the `Invoke-Native` stub in `Tests\Mocks\TestMocks.ps1` if the script later looks for that program's output.

## Versions and releases

The version is set only in the manifest's `ModuleVersion`. It shows in the window title, the log, the summary and the build stamp. A change users notice goes into [CHANGELOG.md](CHANGELOG.md) under a new version: a new feature raises the second number, a fix or a small profile tweak the third. After the merge into `main`, a `vX.Y.Z` tag and a release with the CHANGELOG text are created on GitHub.
