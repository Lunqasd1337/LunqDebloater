# How LunqDebloater is built

Русский: [ARCHITECTURE.md](ARCHITECTURE.md)

This file is for people who change the code: where things are, in which order a build runs and how to add something without breaking it. How to use the script is in [README.en.md](README.en.md), the PR rules are in [CONTRIBUTING.md](.github/CONTRIBUTING.md#contributing-in-english).

## Repository layout

```text
LunqDebloater.ps1            Entry point: parameters, step-by-step mode, checks, plan and the build context
Start.cmd                    Double-click launcher (step-by-step mode)
Install.ps1                  Loader for the one-command start (irm | iex)
Config\                      Everything the user adjusts
  Profile.json               Profile: what to remove and what to write to the registry
  Apps.txt                   winget programs for the first sign-in
  Scripts\                   Own *.ps1 scripts for the first sign-in
  Drivers\                   .inf drivers (not stored in git)
  Updates\                   .msu/.cab updates (not stored in git)
    SafeOS\                  Safe OS Dynamic Update for WinRE
    Setup\                   Setup Dynamic Update for Windows Setup
    Catalog\                 Downloaded from the Microsoft catalog (-DownloadUpdates)
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
.github\                     GitHub Actions, issue and PR templates, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT
```

## The LunqDebloater module

`LunqDebloater.psm1` loads every `Private\*.ps1` in alphabetical order and picks the language from the system right away. Only the functions in the manifest's `FunctionsToExport` are visible outside, and these are exactly the ones `LunqDebloater.ps1` calls: a test in `Tests\Module.Tests.ps1` makes sure there are no extra ones. Add a new function that the script calls there too. Tests reach the rest through `& (Get-Module LunqDebloater) { ... }`.

| File | Responsible for |
|---|---|
| `Console.ps1` | Output: `Write-Step` ("Step N of M"), `Write-Section`, `Write-Info`, `Write-Check`, `Read-YesNo`, `Format-Size` |
| `Language.ps1` | String tables and language: `Set-LunqLanguage`, `Get-LunqText`, `Get-LunqLocalized` for profile texts |
| `System.ps1` | Administrator rights, one run at a time (`Enter-LunqRunLock`), the log (`Start-LunqLog`), step markers in the DISM log and its compression at the end of the run (`Compress-LunqDismLog`), the bug report archive (`New-LunqBugReport`), version, `Invoke-Native` for external programs (their output goes to the log on failure), passing parameters on relaunch |
| `Profile.ps1` | Reading and validating the profile, choosing the profile and categories, merging the enabled categories into common lists (`Get-LunqEffectiveConfig`) |
| `Options.ps1` | The "What goes into the image" summary in step-by-step mode: finding updates and drivers (`Find-LunqBuildInputs`), items for what was found (`New-LunqContentOptions`), their dependencies, toggling by number, action items (`Invoke-LunqContentAction`) and the folder picker (`Select-LunqFolder`) |
| `Iso.ps1` | Mounting the ISO, the list of editions, the image version and the profile requirements check, copying the ISO contents |
| `Checks.ps1` | Checks before the build: working folder, output ISO, disk space, leftovers of a previous run, Windows version on this computer |
| `Image.ps1` | Exporting the edition, recompressing a WIM (`Optimize-LunqWim`), component store cleanup, finding `oscdimg` and building the ISO |
| `Servicing.ps1` | Updates and drivers: into the system, into WinRE (`Update-LunqRecovery`) and into Windows Setup (`Update-LunqSetup`), Safe OS and Setup Dynamic Update and recognizing them by the contents of a `.cab` (`Split-LunqDynamicUpdates`), exporting this computer's drivers (`Export-LunqHostDrivers`) |
| `Removal.ps1` | Removing Appx and capabilities, turning off features and removing CBS packages |
| `Registry.ps1` | Offline registry hives, setting and deleting values and keys, the build stamp in `HKLM\SOFTWARE\LunqDebloater` |
| `PostInstall.ps1` | First sign-in programs and scripts: copying them into the image, `unattend.xml` in Sysprep |
| `Unattend.ps1` | `autounattend.xml` in the ISO root: region, requirements bypass, local account |
| `Inventory.ps1` | "What is in the image" mode: the list of Appx, capabilities and features marked with profile categories |
| `Build.ps1` | Build steps (`Get-LunqBuildSteps`) and the "What is in the image" steps (`Get-LunqInventorySteps`), running them in order (`Invoke-LunqBuild`) and the build stamp values |
| `Report.ps1` | Common step result format (`New-LunqResult`) and the build result (`Write-LunqReport`) |
| `Catalog.ps1` | Fresh updates from the Microsoft Update Catalog: parsing the search page and the download dialog, picking the newest, downloading with a SHA-1 check and a cache (`Save-LunqCatalogUpdates`). Network access only through `Invoke-LunqWebRequest`, which the tests replace |
| `Schedule.ps1` | The scheduled task that rebuilds from a recipe every month (`Register-LunqSchedule`, `Unregister-LunqSchedule`, through `schtasks.exe /XML`) |
| `Recipe.ps1` | The build recipe `<ISO name>.lunq.json`: writing (`New-LunqRecipe`), reading and checking, parameters for a repeat (`Get-LunqRecipeParameters`), comparing updates, the before-and-after HTML report (`Write-LunqHtmlReport`) |
| `Restore.ps1` | Restore data: what was removed and what the registry held, by profile category (`New-LunqRestoreData`, `Add-LunqRestoreItem`), the file `Windows\LunqDebloater\Restore.json` and restoring on this Windows (`Invoke-LunqRestore`) |
| `Host.ps1` | A copy of this computer: apps from `winget export` (`Export-LunqHostApps`, `Merge-LunqAppsList`) and Wi-Fi networks (`Export-LunqHostWifi`) |

## How a run goes

1. **Environment** (`LunqDebloater.ps1`). Outside Windows the script stops at once. In PowerShell 7 it relaunches itself in Windows PowerShell 5.1, because some DISM cmdlets do not work in 7. Without administrator rights it offers an elevated relaunch in step-by-step mode and simply stops when run with parameters. Paths are made absolute, since the new window may open in another folder.
2. **Log.** `Start-LunqLog` starts the log in `Logs` next to the script and a separate DISM log. Everything after that, including errors while choosing the ISO, goes into the log.
3. **Choices.** In step-by-step mode the user picks the action (build or "What is in the image"), the ISO, the profile and the categories. With parameters all of this comes from the parameters.
4. **Config contents.** Updates (`Get-LunqUpdateFiles`), drivers, programs and scripts are found: `Find-LunqBuildInputs` finds the updates and drivers. Safe OS and Setup Dynamic Updates come from the `SafeOS` and `Setup` subfolders, and `Split-LunqDynamicUpdates` checks every `.cab` in the root of the updates folder: only the `.mum` files are extracted from it, no `.mum` means a Setup Dynamic Update, `Package_for_SafeOSDU` means Safe OS. In step-by-step mode the `Select-LunqBuildOptions` summary with the items from `New-LunqContentOptions` lets the user turn them on and off. Items made with `-Action` are not toggles: they return their Key, `Invoke-LunqContentAction` performs the action (choosing a folder with `Select-LunqFolder`, exporting drivers with `Export-LunqHostDrivers`), and the script searches for files again and shows the summary once more. The user's choices between showings are kept in `$choices`.
5. **Checks** (`Test-LunqPrerequisites`): working folder, output ISO, space, `oscdimg`. An error stops the run before the long work starts.
6. **Edition and version.** The ISO is mounted once for the list of editions, the choice and the version of the chosen one, and once more while the build works with it: the CopyIso and Export steps (or "What is in the image") keep it mounted in `Context.State.Iso`, and `Dismount-LunqStateIso` dismounts it after Export or on an error. `Test-LunqImageRequirements` compares the build with the profile's `Requirements`.
7. **"What is in the image" mode** (`-ListContents`) ends here: `Invoke-LunqBuild -Inventory` runs the `Get-LunqInventorySteps` steps, the edition is mounted read-only (straight from the ISO when it has `install.wim`, with no export; `install.esd` is exported to the working folder first), the list is saved next to the ISO or, if that folder is not writable, to the `Logs` folder (`Get-LunqContentsDir`), `Write-LunqInventory` saves the list and the image is unmounted without saving.
8. **Plan.** The script shows what will be done and asks for confirmation in step-by-step mode.
9. **Build** by the list of steps (below), then the result from `Write-LunqReport`. After the result, not as a step, the recipe and the HTML report are written next to the ISO: a failure there does not spoil the finished ISO.
10. **On error** the registry hives are unloaded and the image is unmounted without saving. The working folder is deleted only if this run created it (the Prepare step) and nothing is mounted in it, otherwise DISM would lose the image.

Other modes branch off earlier. `-Schedule` (with `-Recipe`) only creates or removes the task. `-Recipe` first puts the recipe values into every parameter not given on the command line, and then a normal build runs without questions. `-Restore` reads `Restore.json`, lets the user pick categories and calls `Invoke-LunqRestore`. `-Online` goes through profile and category selection like a build and runs `Invoke-LunqBuild -Online`: the `Get-LunqOnlineSteps` steps call the same removal and registry functions with `-Online` instead of `-MountPath`. `-DownloadUpdates` downloads updates after reading the edition, when the release and architecture are known, and before the version check.

Before every change the removal functions and `Set-LunqRegistry` record in `Context.Restore` what was removed and what was there (for `DeleteKey` the key is exported with `reg export`). In a build this is saved into the image at the Save step; with `-Online` it is appended to `%SystemRoot%\LunqDebloater\Restore.json` as the last step (and on error too).

## Build steps

The steps are the list that `Get-LunqBuildSteps` returns in `Private\Build.ps1`. Each one has `Name`, `Title`, `Hint`, `When` (whether to run it) and `Run` (what to do). "Step N of M" is counted from `When`, so the numbers always go in a row.

`LunqDebloater.ps1` puts everything the steps need into one hashtable, the build context, and passes it to `Invoke-LunqBuild`. Each `Run` gets the context as a parameter and returns its results; `Invoke-LunqBuild` collects them for the summary. In `Context.State` the steps record what matters on error: whether the image is mounted (`Mounted`) and whether this run created the working folder (`WorkDirOwned`). The script reads the same table in `catch` and `finally`. The module runs under `StrictMode`, so the context must contain every key, even empty ones.

| Step | What it does | When |
|---|---|---|
| Prepare | Clears the working folder (`Reset-LunqWorkDir`) | always |
| CopyIso | Mounts the ISO (until the end of the Export step) and copies its contents to `WorkDir\iso`, except `install.wim` and `install.esd` | always |
| Export | Exports the chosen edition straight from the mounted ISO to its own `install.wim` (ESD becomes WIM) with fast compression and dismounts the ISO: the Recompress step applies maximum compression | always |
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
| Save | Writes the build stamp into the image registry and the restore data into `Windows\LunqDebloater\Restore.json`, saves `install.wim` | always |
| Setup | Expands Setup DU into `sources`; if there are updates or drivers for `boot.wim` (image 2), services it and copies `setup.exe`, `setuphost.exe` and the UEFI boot manager out of it | there is something for Windows Setup |
| Recompress | Recompresses `install.wim` | always |
| Iso | Builds the bootable ISO with `oscdimg` | always |

The order matters: updates go in before components are removed, the answer file and the build stamp are written before the image is saved, and Windows Setup is serviced afterwards, because it lives in `WorkDir\iso` and not inside `install.wim`.

## Step results and the summary

Every step function returns a `New-LunqResult` object: `Title`, `Kind`, the lists `Done`, `Failed`, `Skipped`, `NotMatched`, a `Summary` line and `ByCategory` counters. `Write-LunqReport` prints them the same way for all steps: removals and the registry by profile category, everything else as "installed/added N, errors M". A failure of one package or driver goes into `Failed` and does not stop the build. A package that DISM rejects as not applicable to the image (`0x800f081e`, `Test-LunqNotApplicable`) goes into `Skipped`, and the result shows it on a separate line. A failure that makes it impossible to continue is thrown as an exception.

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
| `Tests\Module.Tests.ps1` | The module as a whole: version from the manifest, exports, help, relaunch arguments, the bug report archive. It makes sure the `ru` and `en` keys match, every key used in the code exists in the tables, every key in the tables is used in the code, and every parameter is documented in both READMEs |
| `Tests\Profile.Tests.ps1` | Reading the profile, entry checks, categories, sorted lists, name patterns |
| `Tests\Checks.Tests.ps1` | Working folder, output ISO, UEFI-only ISO, image and host versions, leftovers of an earlier run, the folder for the contents list, edition hints and choice |
| `Tests\Options.Tests.ps1` | The "What goes into the image" summary: items with a parent, toggling by number, actions |
| `Tests\Console.Tests.ps1` | Console questions, including closed input |
| `Tests\Image.Tests.ps1` | Exporting and recompressing `install.wim`: the file is replaced in one operation, a source on the ISO is not deleted |
| `Tests\Servicing.Tests.ps1` | Update order, picking updates and drivers for Windows Setup and WinRE, recognizing Dynamic Updates by their `.cab`, skipping packages that do not apply |
| `Tests\PostInstall.Tests.ps1` | Re-saving scripts as UTF-8 with BOM, the answer file |
| `Tests\Build.Tests.ps1` | End-to-end runs of `LunqDebloater.ps1` with parameters and in step-by-step mode (including choosing folders and this computer's drivers), in Russian and English |
| `Tests\Steps.Tests.ps1` | Build steps on their own: which ones run with which settings, a single step with a stub, the build stamp |
| `Tests\Install.Tests.ps1` | The loader: unpacking a release, updating while keeping changes in `Config`, working offline |
| `Tests\FirstLogon.Tests.ps1` | The first sign-in script in a separate process with a fake winget, network and task scheduler |
| `Tests\Registry.Tests.ps1` | Parsing registry values from the profile and real registry writes (writes on Windows only) |
| `Tests\Removal.Tests.ps1` | Removing CBS packages: only installed packages that match the profile patterns, failures and unmatched patterns in the result |
| `Tests\TestHelpers.ps1` | A copy of the script in `TestDrive`, environment variables for the stubs, running it and parsing the steps |
| `Tests\Mocks\Dism\Dism.psm1` | Stub of the DISM module: mounts nothing and creates placeholder files where the script looks for them later, including drivers for `Export-WindowsDriver` |
| `Tests\Mocks\TestMocks.ps1` | Stubs of the module functions that touch the system: administrator rights, ISO mounting, disk space, `Invoke-Native` (robocopy, reg.exe, oscdimg, expand.exe), the folder picker and registry writes. It is copied into the module of the script copy as `Private\ZZ.TestMocks.ps1` so it loads last |

The stubs are configured with `LUNQ_TEST_*` variables, for example `LUNQ_TEST_DISM_EXIT` (dism.exe exit code), `LUNQ_TEST_FAIL_APPX` (a failure in the middle of the build), `LUNQ_TEST_IMAGE_VERSION`, `LUNQ_TEST_HOST_BUILD`, `LUNQ_TEST_NOT_ADMIN`, `LUNQ_TEST_FOLDER` (what is "chosen" in the folder picker), `LUNQ_TEST_NO_HOST_DRIVERS`, `LUNQ_TEST_ISO_WIM` (the ISO has `install.wim` instead of `install.esd`). Calls to external programs are written to `LUNQ_TEST_NATIVE_LOG`, registry writes to `LUNQ_TEST_REG_LOG`, and the tests check them. End-to-end tests run in Russian by default and compare the Russian output; the English tests check that the output has no Cyrillic.

## How to add

**A parameter.** Add it to `param()` in `LunqDebloater.ps1` and to the parameter table in `README.md` and `README.en.md` (a test checks this). If it is a path, add its name to `$pathParams` so it is passed as an absolute path on relaunch.

**A build step.** Add an entry to `Get-LunqBuildSteps` (`Private\Build.ps1`) in the right place, and the strings `Main.Step<Name>` and `Main.Step<Name>Hint` to both tables. `Run` gets the context as a parameter and returns a `New-LunqResult`. If the step needs a new value, add the key to the context in `LunqDebloater.ps1` and to `New-TestContext` in `Tests\Steps.Tests.ps1`. Update the step lists in `Tests\Steps.Tests.ps1` and the expected step counts in `Tests\Build.Tests.ps1`.

**An interface string.** Add the key to `Strings\ru\<Area>.psd1` and `Strings\en\<Area>.psd1` with the same `{0}`, `{1}`. Keys in a table are aligned to the longest one.

**A profile entry.** Add the name to the right list of a category in `Config\Profile.json` (the lists are sorted), or add a new category with `Name` and `Description` in both languages. If the default profile behaves differently, update the category description and the "Profile" section in both READMEs.

**An external program.** Call it through `Invoke-Native`: that way stderr does not turn into an exception in 5.1, and tests can replace the call. Add a branch to the `Invoke-Native` stub in `Tests\Mocks\TestMocks.ps1` if the script later looks for that program's output.

## The Install.ps1 loader

`Install.ps1` does not depend on the module. The user gets it with `irm <raw link to main> | iex`, and the loader then downloads the archive of the latest release. So the loader itself comes from `main`, while the program comes only from a released version.

Unlike the other scripts it is stored as ASCII without a BOM, which is why its messages and comments are in English. `irm` hands the file to `iex` as a string, and how Windows PowerShell 5.1 decodes it depends on the response headers. A BOM could end up at the start of the code, and Russian letters decoded with the wrong encoding can turn into "smart" quotes and break parsing. `Tests\Install.Tests.ps1` checks that the file is ASCII only.

Next to the program the loader keeps `.lunq-install.json` with the installed release tag and the hashes of the `Config` files it put there. A `Config` file whose hash has changed since then counts as the user's edit and is not replaced on update.

## Versions and releases

The version is set only in the manifest's `ModuleVersion`. It shows in the window title, the log, the summary and the build stamp. A change users notice goes into [CHANGELOG.md](CHANGELOG.md) under a new version: a new feature raises the second number, a fix or a small profile tweak the third. After the merge into `main`, a `vX.Y.Z` tag and a release with the CHANGELOG text are created on GitHub.
