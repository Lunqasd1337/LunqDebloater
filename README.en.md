Русский: [README.md](README.md)

# LunqDebloater

A PowerShell script that preconfigures a Windows 11 ISO image before installation. It works offline, with DISM, on `install.wim`:

- removes preinstalled Appx apps;
- removes Windows components (Capabilities and Optional Features);
- optionally adds updates (`.msu`, `.cab`), so Windows is up to date right after installation;
- optionally adds drivers (`.inf`), so Windows installs with the drivers for your hardware right away;
- optionally updates Windows Setup and the recovery environment (WinRE) with the same updates and drivers, plus Safe OS and Setup Dynamic Update;
- optionally installs programs with winget and runs your scripts at the first sign-in to Windows;
- optionally puts an answer file in the ISO: Windows Setup asks fewer questions, and on older computers you can bypass the TPM and Secure Boot requirements;
- makes changes to the registry of the image (the `SOFTWARE` and `SYSTEM` hives and the `Default` profile that every new user is created from).

The result is a bootable ISO (BIOS + UEFI, UEFI only for ARM64) with one selected edition. A separate "What is in the image" mode builds nothing: it writes out the list of apps and components of an edition, so it is easier to make your own profile.

You can build in the console, step by step or with parameters, or in the `LunqDebloater.exe` window with all settings on one page (see "The window").

## Disclaimer

LunqDebloater changes the Windows installation image in ways that Microsoft does not officially support: it removes apps and components and edits the registry. **Everything you do with it, you do at your own risk.** The author is not responsible for lost data, a broken or unstable system, or problems with updates, activation, warranty or manufacturer support.

- Future cumulative updates of Windows may fail to install or bring back what was removed if they expect the removed components.
- Before installing on a computer you rely on, test the built ISO in a virtual machine and back up important data.

The program is provided "as is", without any warranty (see [LICENSE](LICENSE)).

## Requirements

- Windows 11 and Windows PowerShell 5.1 (built into Windows). If you start the script from PowerShell 7, it restarts itself in 5.1: in PowerShell 7 the DISM cmdlets for Appx fail with "Class not registered".
- Build on Windows 11 of the same version as the ISO or newer. The DISM module comes from the system, and DISM of an older system, especially Windows 10, may not cope with the latest updates of a newer image. The script warns you if the system is older than the image.
- [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install), the **Deployment Tools** component (only `oscdimg.exe` is needed).
- About 25 GB of free space on an NTFS drive for the working folder (`C:\LunqWork` by default), more with updates and drivers: three times the size of the updates and twice the size of the drivers on top. The check before the build shows the exact number.
- An original Windows 11 ISO.
- For the `LunqDebloater.exe` window: WebView2 Runtime (Windows 11 already has it).

Before the build starts, the script checks administrator rights, the ADK and free space, and tells you what to fix.

## The Config folder

All settings are in one `Config` folder next to the script. There is no need to look through different folders: whatever you put in `Config` goes into the image.

| What | What for |
|---|---|
| `Profile.json` | What to remove from Windows and which registry settings to change (see "Profile") |
| `Apps.txt` | Programs that winget installs at the first sign-in (see "After installation") |
| `Scripts\` | Your `*.ps1` scripts that run after installation |
| `Drivers\` | `.inf` drivers, subfolders are fine (see "Drivers") |
| `Updates\` | `.msu`/`.cab` updates, with updates for WinRE and Windows Setup in the `SafeOS\` and `Setup\` subfolders (see "Updates") |

A short guide to each item is in [Config/README.en.txt](Config/README.en.txt). Drivers and updates are not stored in git.

Before the build the script shows the "What goes into the image" summary: what it found in `Config`, with numbers. You can turn off anything you do not need by its number without deleting it from the folder. The same summary turns on component store cleanup, adding updates and drivers to Windows Setup and the recovery environment, and the answer file (see "Answer file"). Drivers and updates do not have to be put in `Config`: the items marked with an arrow in the summary open a folder picker (for example, Downloads or a USB stick with the vendor's drivers), and the "Take this computer's drivers" item exports the drivers of the current Windows. After that the summary is shown again and keeps the rest of your choices. In the window the same settings are under "More options", and the "Other folder…" button chooses the updates or drivers folder.

To keep several sets of settings, copy the folder (for example, to `Config-Office`) and run with `-ConfigPath .\Config-Office`.

## Quick start

The easiest way is one command. Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/Lunqasd1337/LunqDebloater/main/Install.ps1 | iex
```

The command downloads the latest release into the `LunqDebloater` folder in your profile (`C:\Users\<name>\LunqDebloater`) and starts the script in step-by-step mode, then continue from step 3. See "One-command start" for details.

If you prefer the window, download just `LunqDebloater.exe` from the [latest release](https://github.com/Lunqasd1337/LunqDebloater/releases/latest) and run it: it downloads the rest itself (see "The window"). The command above puts `LunqDebloater.exe` into the program folder too.

Or by hand:

1. Download the repository (Code > Download ZIP) and extract it.
2. Double-click `Start.cmd`. The script asks for administrator rights.
3. Then it asks for everything itself: choose whether to build an ISO or look at what is in the image, then pick the ISO in the file dialog, then the tweak categories, check the "What goes into the image" summary and choose the edition (each edition has a short explanation).
4. Check the build plan and confirm. A build usually takes 15-40 minutes. The console shows "Step N of M" with an explanation of what is happening.
5. At the end the script shows the result: what was removed, what was not found in the image, and where the finished ISO is.

## The window

`LunqDebloater.exe` builds the ISO without the console. It is a shell over the same script: the window runs `LunqDebloater.ps1` with parameters and shows what it reports, so the checks, the build and the log are the same as in the console.

1. Download `LunqDebloater.exe` from the [latest release](https://github.com/Lunqasd1337/LunqDebloater/releases/latest) and run it, for example straight from Downloads. The window asks for administrator rights right away: without them the script cannot mount the ISO.
2. On the first start there is no `LunqDebloater.ps1` next to the exe, and the window offers to download LunqDebloater into `C:\Users\<name>\LunqDebloater` ("Other folder…" changes the folder). It installs it with the same `Install.ps1` loader as the one-command start, puts `LunqDebloater.exe` there and opens from there. From then on, start the exe from that folder. The exe in Downloads works too: it opens the installed one right away, and if it is newer itself, it offers to update the folder. Your changes in `Config` stay on update.
3. **Windows image.** Click "Choose ISO…". The window reads the list of editions and picks Pro in advance if there is one. You cannot drag the ISO into the window: Windows does not allow dragging from regular windows into windows running as administrator.
4. **What to remove and turn off.** The categories of the `Config\Profile.json` profile with their descriptions. The ones the profile turns on are already ticked.
5. **Result.** Where to save the ISO (next to the source one by default) and the answer file: setup without extra questions, sign-in without a Microsoft account, bypassing the TPM 2.0 and Secure Boot checks (see "Answer file").
6. Click "Build ISO". If the file already exists, the window asks whether to replace it.

"More options" holds updates and drivers (from `Config\Updates` and `Config\Drivers` or another folder), component store cleanup, updating Windows Setup and WinRE, disk drivers for Setup, first sign-in apps and scripts, the volume label and the working folder.

During the build you see "Step N of M", a progress bar, the finished steps with their times and the number of warnings, and "Open log" opens the run log. At the end the window shows where the ISO is ("Show in folder"), what each step did and all warnings. If the build stops, you see the cause, the checks that failed with hints, and "Bug report" with the archive for an issue. If you close the window during the build, the script finishes in the background, and the result is in its log.

What the window does not have, the console is still there for it: the "What is in the image" mode, choosing one of several profiles (the window always uses `Config\Profile.json`), exporting this computer's drivers and rare parameters such as `-ConfigPath`, `-SkipAppx` or `-SkipVersionCheck`. The RU and EN buttons at the top switch the window language. The window needs WebView2, which Windows 11 already has.

## One-command start

`irm ... | iex` downloads and runs [Install.ps1](Install.ps1), which you can read before running it. The loader:

- finds the latest release on GitHub (not the current `main`) and puts it into `C:\Users\<name>\LunqDebloater`. A folder in the profile is used because the script runs from it as administrator, and files in the root of drive C: can be changed by other users of the computer too;
- puts the window `LunqDebloater.exe` from the same release next to it. If it is not attached to the release yet (GitHub Actions does that a few minutes after the release), the loader warns and downloads the window on the next run;
- starts `LunqDebloater.ps1` in Windows PowerShell 5.1, even if the command was typed in PowerShell 7. The script asks for administrator rights itself.

The same command updates the program together with the window. If the version is already the latest, the script just starts. On update the program folders are replaced as a whole. Files in `Config` that you changed stay, and the loader lists them. Your own files next to it (an ISO, `Logs`) are not touched. Without internet the version already downloaded starts.

To use another folder:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Lunqasd1337/LunqDebloater/main/Install.ps1))) -Path D:\LunqDebloater
```

The loader puts nothing into a non-empty folder that has no LunqDebloater in it. Only you, administrators and SYSTEM can change the files in the program folder: the loader sets these rights itself, so a folder in the root of a drive is safe too. A FAT32 or exFAT flash drive has no access rights, and the loader warns about it.

### Desktop shortcut

A shortcut with this command checks for updates and starts the latest version every time. Right-click the desktop, choose New > Shortcut and paste into "Type the location of the item":

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Lunqasd1337/LunqDebloater/main/Install.ps1 | iex"
```

Name the shortcut, for example "LunqDebloater". The console window does not close by itself: at the end the script waits for Enter.

## Running with parameters

All parameters are described in the table below. `Get-Help .\LunqDebloater.ps1` lists them with links to this description. For repeated builds and automation you can set everything with parameters. Then the script asks nothing and takes everything that is in `Config`:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Get-ChildItem -Recurse | Unblock-File   # if the archive was downloaded from the internet

.\LunqDebloater.ps1 -IsoPath D:\Win11_26H2.iso -Edition "Windows 11 Pro"
```

Without `-Edition` or `-Index` the script shows the list of editions and asks for a number. Without `-IsoPath` it runs in step-by-step mode, as with `Start.cmd`. By default the finished ISO appears next to the original one (`Win11_26H2_Lunq.iso`), and the log of the run is in the `Logs` folder next to the script (see "Logs and version").

| Parameter | Purpose |
|---|---|
| `-IsoPath` | The original ISO. Without it the script runs in step-by-step mode |
| `-OutputIso` | Path to the finished ISO |
| `-ConfigPath` | Settings folder instead of `Config` next to the script |
| `-ProfilePath` | Your own JSON profile instead of `Config\Profile.json` |
| `-SkipCategory` | Ids of profile categories to skip, separated by commas |
| `-IncludeCategory` | Ids of categories to turn on even if the profile turns them off (for example, `drivers`), separated by commas |
| `-Index` / `-Edition` | Edition by number or name |
| `-WorkDir` | Working folder. The script clears it completely, so only a new or empty folder (or one it created before) will do, not a drive root and not the folder with the ISO. Only administrators can access it |
| `-OscdimgPath` | Path to `oscdimg.exe` or the folder that holds it, if the ADK is not in its standard folder |
| `-UpdatesPath` | Folder with `.msu`/`.cab` updates instead of `Config\Updates` (the `SafeOS` and `Setup` subfolders are looked up in it too) |
| `-DriversPath` | Folder with drivers (`.inf`, subfolders are fine) instead of `Config\Drivers` |
| `-DriversToSetup` | Also add disk controller drivers to Windows Setup (`boot.wim`) and the recovery environment (WinRE) if they do not see the disk |
| `-UpdatesToSetup` | Also add the Windows updates to Windows Setup and WinRE, plus Safe OS and Setup Dynamic Update (from the `SafeOS` and `Setup` subfolders or recognized in the folder itself) |
| `-SkipUpdates`, `-SkipDrivers` | Do not add the updates or drivers from `Config` |
| `-SkipApps`, `-SkipScripts` | Do not install the programs from `Apps.txt` or do not run the scripts from `Scripts` at the first sign-in |
| `-Unattend` | Put an answer file in the ISO: no questions about the license and privacy, language, region and time zone as on this computer |
| `-BypassRequirements` | Add a bypass of the TPM 2.0, Secure Boot and memory requirements to the answer file (turns on `-Unattend`) |
| `-LocalAccount` | Add sign-in without a Microsoft account to the answer file (turns on `-Unattend`) |
| `-SkipRegion` | Do not put this computer's language, region and time zone in the answer file: Setup asks for them itself |
| `-ListContents` | Do not build an ISO, save the list of apps and components of the edition to a file instead |
| `-SkipAppx`, `-SkipComponents`, `-SkipRegistry` | Skip the step |
| `-Label` | Volume label of the finished ISO: Latin letters, digits, `_` and `-`, up to 32 characters. `LUNQ_WIN11` by default |
| `-SkipVersionCheck` | Do not stop if the ISO build does not match the `Requirements` of the profile |
| `-CleanupComponents` | Clean up the component store (`/ResetBase`): the image is smaller, but the updates in it cannot be removed |
| `-KeepWorkDir` | Do not delete the working folder after the build |
| `-Force` | Overwrite an existing finished ISO |
| `-Language` | Interface language: `ru` or `en`. By default Russian on Russian Windows and English on any other |
| `-EventsPath` | File the script writes events to for your own programs, such as a window with a progress bar (see "Events for your own programs"). Only works together with `-IsoPath` |
| `-ListEditions` | Only show the editions in the ISO from `-IsoPath` (number and name) and exit. Checks and changes nothing. With `-EventsPath` the list arrives as the `editions` event |

## How the process works

1. The ISO is mounted and its contents are copied to the working folder.
2. The selected edition is exported to a separate `install.wim` (an ESD is converted to WIM on the way).
3. `install.wim` is mounted, the updates and drivers are added to it (if selected), WinRE is updated if you asked for it, and the first sign-in script is added. The answer file goes to the root of the ISO if it is turned on. Then the profile is applied: Appx, components, registry.
4. The image is saved. If selected, Windows Setup is updated: Setup Dynamic Update is expanded into `sources`, `boot.wim` is serviced, and `setup.exe`, `setuphost.exe` and the UEFI boot manager are copied out of it. If there are no updates or drivers for `boot.wim`, it is left as is. Then `install.wim` is recompressed and `oscdimg` builds the bootable ISO.

All steps in order and the conditions under which they run are described in [ARCHITECTURE.en.md](ARCHITECTURE.en.md#build-steps).

If an error occurs, the image is dismounted without saving and the registry hives are unloaded.

## Logs and version

Every run writes a log to the `Logs` folder next to the script, from the very start: it also contains errors that happen while choosing the ISO and profile and while checking the system. The first lines of the log show the LunqDebloater version, the Windows and PowerShell versions and the parameters of the run. Next to it is the detailed DISM log: when DISM reports an error, the real cause is usually visible only there. With updates it grows to hundreds of megabytes, so at the end of the run it is compressed into `LunqDebloater_<date>_dism.zip` (opens with a double click). The logs of the last 10 runs and the DISM logs of the last 3 runs are kept, older ones are deleted automatically. The path to the log is shown in the build plan, in the result and on an error, and in the `LunqDebloater.exe` window the "Open log" button opens it.

Every step header shows the time the step started, and the result lists the three longest steps. In the DISM log each step starts with a marker `===== LunqDebloater <time>: step N/M: <step> =====`, which makes the right place easy to find. When an external program (for example, robocopy or oscdimg) fails, the last lines of its output go into the log. On an error, the text below it shows where exactly it happened.

When a build stops with an error, an archive `LunqDebloater_<date>_report.zip` appears next to the log with the run log, the DISM log and the profile. The user folder path, the user name and the computer name in it are replaced, so this archive alone is enough for a bug report. A DISM log bigger than 20 MB is shortened in it: all errors, warnings and step markers and the last 20,000 lines. If there is no archive, send both files of the last run: `LunqDebloater_<date>.log` and `LunqDebloater_<date>_dism.zip`.

The LunqDebloater version is shown in the console window title, next to the name in the `LunqDebloater.exe` window, at the start of the log and in the build result. It is also written to the built image together with the build settings. On the installed system you can see them like this:

```powershell
reg query HKLM\SOFTWARE\LunqDebloater
```

It lists the version and date of the build, the original ISO and edition, the answer file, the profile, the enabled and skipped categories, the added updates (including Safe OS and Setup Dynamic Update), the number of drivers, whether Windows Setup and WinRE were updated, component store cleanup, skipped steps, and the programs and scripts after installation. If something does not work right after installation, this data shows what built the image and with which settings.

## Updates

1. Download the cumulative update for your version from the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com), for example by searching for `Windows 11 Version 26H2 x64`. If the catalog has several files for it, download all of them.
2. In step-by-step mode choose their folder in the summary with "Choose a folder with updates", for example Downloads. Or put the files in `Config\Updates`: then they appear in the summary right away, and with parameters they are added automatically (add `-SkipUpdates` if you do not want that). With parameters, `-UpdatesPath` sets another folder, and in the window the "Other folder…" button under "Add updates" in "More options".

The catalog shows Safe OS and Setup Dynamic Update packages in the same search as the cumulative update, but they are for the recovery environment and Windows Setup and do not install into the system itself. `Config\Updates` has subfolders for them:

- `Config\Updates\SafeOS`: Safe OS Dynamic Update (`.cab`), installed into WinRE after the cumulative update;
- `Config\Updates\Setup`: Setup Dynamic Update (`.cab`), expanded into the ISO's `sources` folder to update the Windows Setup files.

The same subfolders are used in a folder chosen in the summary or with `-UpdatesPath`. If there are none, for example in Downloads, the Dynamic Updates can stay next to the other updates: the script recognizes them by the contents of the `.cab`. A Setup Dynamic Update has no DISM package (`.mum` file) in it, and a Safe OS Dynamic Update is named `Package_for_SafeOSDU`. The summary marks such files. They are added only together with the Windows Setup and WinRE update (see "Windows Setup and recovery environment"). Take them for the same Windows version as the cumulative update.

Updates are installed right after the image is mounted, before apps and components are removed. The order follows Microsoft: first packages without a KB number (language packs and features on demand), then Windows updates in ascending KB order, and .NET updates (`ndp` in the name) last. A cumulative update takes a long time to install (10-30 minutes) and needs extra space. After updates it makes sense to turn on `-CleanupComponents` (in the summary it is the item under the updates): old versions of system files are deleted and the image gets smaller.

## Drivers

1. If the ISO is built for this same computer, choose "Take this computer's drivers" in the summary: the script exports the third-party drivers of the current Windows. For another computer choose a folder with extracted drivers (`.inf` files together with `.sys`, `.cat` and the rest, any subfolders) with "Choose a folder with drivers", for example a USB stick with the vendor's drivers. You can also put them in `Config\Drivers`, and with parameters set the folder with `-DriversPath`. How to extract drivers is described in [Config/README.en.txt](Config/README.en.txt). In the window the "Other folder…" button under "Add drivers" chooses the folder. The window cannot export this computer's drivers: export them into `Config\Drivers` with the command from [Config/README.en.txt](Config/README.en.txt) or use the summary in the console.
2. The drivers appear in the summary before the build, and with parameters they are added automatically (add `-SkipDrivers` if you do not want that).
3. If Windows Setup does not see the disk (Intel RST/VMD controllers, RAID), add the drivers to it as well: in the summary and in the window it is the item under the drivers, with parameters you need the `-DriversToSetup` switch. The drivers then also go into the recovery environment (WinRE), so it sees the disk too. Only disk controller drivers are added there (class `SCSIAdapter` or `HDC` in the `.inf`): Windows Setup is loaded into memory completely at boot, and all drivers would slow it down a lot.

The drivers go into the driver store of the image, and Windows installs the matching ones during setup. Each `.inf` is added separately, so an unsuitable driver does not break the build but shows up in the result as an error. A driver that comes as an `.exe` without an `.inf` cannot be added; extract it first.

This works well with the `drivers` category of the profile (off by default): it stops Windows Update from installing its own drivers, and you add the ones you need yourself.

## Windows Setup and recovery environment

Besides the system itself, the ISO contains two more images based on Windows PE:

- **Windows Setup** (`sources\boot.wim`, image 2), which the USB drive boots from;
- the **recovery environment** (WinRE, `Windows\System32\Recovery\Winre.wim` inside the system), which opens when Windows fails to start and from Settings > System > Recovery.

By default they stay as they are in the ISO. With `-UpdatesToSetup` they get the same Windows updates as the system, and with `-DriversToSetup` the disk controller drivers. In the summary before the build and under "More options" in the window these are the items under the updates and the drivers. If Safe OS or Setup Dynamic Updates were found, the Windows Setup update item in the summary is on from the start. With `-UpdatesToSetup` WinRE also gets the Safe OS Dynamic Update, and the Setup Dynamic Update is expanded into the ISO's `sources` folder. After Windows Setup is updated, `setup.exe` and `setuphost.exe` are copied from `boot.wim` to the ISO's `sources` folder: Microsoft's guidance says they must match the files in `boot.wim`, otherwise setup may fail to start. The UEFI boot manager on the ISO (`efi\boot\bootx64.efi` and `bootmgr.efi`) is taken from there too. .NET updates and other packages that do not install into Windows PE are skipped. After the updates both images are cleaned of old files and recompressed. A build with updates takes 10-20 minutes longer.

## After installation

You can have the programs you need installed and your scripts run at the first sign-in to the installed Windows:

1. `Config\Apps.txt` already has a ready-made list: 7-Zip, DirectX and all versions of the Visual C++ Redistributable that games and many programs need. Add your own programs (winget Ids, one per line) or comment out the ones you do not need with `#`. There are more examples at the end of the file.
2. If needed, put your own `*.ps1` scripts in `Config\Scripts`. They run after the programs, in name order, with administrator rights. The other files in this folder are copied too, and the scripts can use them.
3. The programs and scripts appear in the summary before the build and under "More options" in the window, and with parameters they are added automatically (add `-SkipApps` or `-SkipScripts` if you do not want that).

At the first sign-in a window with the progress opens. The script waits for the internet and winget, installs the programs silently, runs the scripts and closes the window. If there is no internet, a program did not install, or the window was closed halfway, the unfinished work is repeated at the next sign-in (up to 5 attempts). While the programs are not installed, the scripts wait: they run after the programs or on the last attempt. A script that failed is not run again. Your scripts and the log are accessible to administrators only, and if setting these rights failed, the log says so. In the ISO itself and on the flash drive they are not protected inside `install.wim`: anyone who gets the ISO can read them, so do not give others an ISO with passwords in its scripts. When everything is done, the copies of your scripts and everything next to them are deleted from the disk: they may contain passwords and keys. Only `Apps.txt` and the log `C:\Windows\Setup\Scripts\Lunq\FirstLogon.log` remain. Details are in [Config/README.en.txt](Config/README.en.txt).

You can save scripts in any editor. Windows PowerShell 5.1 reads a UTF-8 file without a BOM as ANSI, and non-English text in quotes (for example, Russian) breaks the whole script. That is why such files are saved again as UTF-8 with BOM during the build; you can see this in the output of the step.

A script counts as failed if it threw an error or ended with an exit code other than 0. The exit code is also taken from the last external program in the script: for example, robocopy returns 1 even on success. If that is intended, add `exit 0` at the end of the script.

If you write the USB drive with Rufus, do not tick any of the Windows options in its window, including the bypass of the TPM, Secure Boot and memory requirements. For them Rufus adds its own answer file, Windows uses it instead of the LunqDebloater one, and the programs and scripts do not start by themselves after installation. It is better to turn on the requirements bypass and the local account in the LunqDebloater answer file (see "Answer file"). If you cannot do without the Rufus options or your own `autounattend.xml`, after installation run everything by hand from PowerShell as administrator:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Lunq\FirstLogon.ps1
```

## Answer file

The answer file (`autounattend.xml` in the root of the ISO) answers some of the Windows Setup questions for you. Windows Setup finds it on the USB drive by itself. In step-by-step mode it is on by default (the items under "Answer file" in the summary); with parameters you turn it on with the `-Unattend` switch. In the window it is on by default too: the "Setup without extra questions" switch under "Result" covers the first row of the table, and the switches under it cover the language and region, `-LocalAccount` and `-BypassRequirements`.

| Summary item | Switch | What it does |
|---|---|---|
| Do not ask about the license and privacy | `-Unattend` | The license is accepted automatically, all privacy settings (diagnostics, ads, location) are off, and their page is not shown |
| Language, region and time zone as on this computer | `-Unattend` without `-SkipRegion` | The language of Setup and Windows is taken from the image, and the format, keyboard layouts and time zone from the computer that builds the ISO |
| Bypass the Windows 11 requirements | `-BypassRequirements` | Setup does not check TPM 2.0, Secure Boot and the amount of memory. For computers that Windows 11 does not install on otherwise |
| Local account | `-LocalAccount` | Windows does not ask you to sign in with a Microsoft account and asks for the name and password of a local account right away |

The installation disk, the product key (you can click "I don't have a product key") and the network are still chosen by hand: the answer file never erases anything by itself. It stores no passwords; the account name and password are entered during setup. If the image has programs or scripts for after installation, their command is written to this file too.

With Rufus, do not tick the Windows options in its window: it would add its own answer file instead of this one. It is worth testing the answer file on a real installation in a virtual machine: the build was tested only with stubs.

## What is in the image

To make your own profile, it helps to know the exact names of apps and components in your edition. In step-by-step mode choose "See what is in the image" at the start, or with parameters add `-ListContents`:

```powershell
.\LunqDebloater.ps1 -IsoPath D:\Win11.iso -Edition "Windows 11 Pro" -ListContents
```

The script builds and changes nothing. It copies the edition to the working folder, opens it read-only and saves the file `<ISO name>_<edition number>_contents.txt` next to the ISO. The file lists the Appx apps, the installed components (Capabilities) and the Windows features (enabled and disabled). On the right of each item are the profile categories that already remove it. At the end of the file are the profile entries that are not in the image. Windows ADK is not needed for this mode. The `LunqDebloater.exe` window does not have this mode.

## Events for your own programs

To run a build from your own program (for example, a window with a progress bar), pass `-EventsPath` with a file path. The script works as usual and the log and console output stay the same, but everything it reports is also written to that file as events: one line is one JSON object in UTF-8. Lines are written immediately, and the file can be read while the build runs. With `-EventsPath` the script asks no questions, so it needs `-IsoPath` and, if the ISO has more than one edition, `-Index` or `-Edition`.

```powershell
.\LunqDebloater.ps1 -IsoPath D:\Win11.iso -Edition "Windows 11 Pro" -Force -EventsPath C:\Temp\lunq.jsonl
```

```
{"type":"start","time":"2026-10-17T19:02:11.5+03:00","language":"en","mode":"build","pid":4120,"version":"1.10.0"}
{"type":"step","time":"...","hint":null,"id":"Updates","index":5,"text":"Adding updates","total":17}
{"type":"info","time":"...","text":"windows11.0-kb2-x64.cab does not apply to this image, skipping."}
{"type":"done","time":"...","bugReport":null,"contents":null,"dismLog":"...","iso":"D:\\Win11_Lunq.iso","log":"...","ok":true,"seconds":1834.2,"warnings":0}
```

Every event has `type` and `time`. The other fields:

| `type` | When | Fields |
|---|---|---|
| `start` | Right after start | `version`, `language`, `mode` (`build`, `list` or `editions`), `pid` |
| `log` | The log has started | `path`, `dismLog` |
| `section` | A new output section | `text` |
| `editions` | The ISO edition list was read | `items`: `index` and `name` of each |
| `step` | A build step started | `index`, `total`, `id` (step name, the same in every language), `text`, `hint` |
| `stepEnd` | A step finished | `index`, `id`, `ok`, `seconds` |
| `check` | A check line | `status` (`ok`, `warn`, `fail`), `text`, `hint` |
| `info` | A regular output line | `text` |
| `warning` | A warning | `text` |
| `result` | A step summary after the build | `kind`, `title`, `done`, `failed`, `skipped`, `notMatched`, `summary` |
| `error` | The build stopped with an error | `text`, `where` (where it happened) |
| `done` | The last event of the run | `ok`, `iso`, `contents` (the `-ListContents` file), `log`, `dismLog`, `bugReport`, `warnings`, `seconds` |

Texts in events are in the interface language set by `-Language`. The last event is always `done`, and the `powershell.exe` exit code is not 0 on failure. The script needs administrator rights, so your program starts it with them itself, for example with `Start-Process -Verb RunAs`, and reads the events file rather than the process output: the output of a process with different rights is not available.

This is how the `LunqDebloater.exe` window (the `Gui` folder) works: it starts with administrator rights itself, runs the script with `-EventsPath`, reads the file and draws the steps and the result. Its code can serve as an example, and it gets the list of editions to choose from with a `-ListEditions` run.

## Profile

Everything that is removed and changed is described in `Config\Profile.json`. Edit it to your needs or put more profiles (`*.json`) next to it: the script then asks which one to use (the window always uses `Profile.json`). A profile is made of categories: each one holds everything about one topic (apps, components, features and registry), and it can be turned on or off as a whole.

```jsonc
{
  "$schema": "../Schemas/Profile.schema.json",   // completion and checks in VS Code
  "Name": "Default",
  "Description": "What the profile does",
  "Options": { "RemoveFeaturePayload": false },   // whether to delete the files of turned off features
  "Categories": [
    {
      "Id": "ai",                                 // short name for -SkipCategory and -IncludeCategory
      "Name": { "ru": "Copilot и ИИ", "en": "Copilot and AI" },
      "Enabled": true,                            // false: the category is skipped
      "Description": "What the category does",
      "Appx":         ["Microsoft.Copilot"],      // DisplayName, * allowed
      "Capabilities": [],                         // Get-WindowsCapability, * allowed
      "Features":     ["Recall"],                 // Get-WindowsOptionalFeature
      "Packages":     [],                         // CBS packages, be careful
      "Registry": [
        { "Hive": "SOFTWARE", "Path": "Policies\\Microsoft\\Windows\\WindowsCopilot", "Name": "TurnOffWindowsCopilot", "Type": "REG_DWORD", "Value": 1 },
        { "Hive": "DefaultUser", "Path": "Software\\Microsoft\\Windows\\CurrentVersion\\Run", "Name": "OneDriveSetup", "Action": "DeleteValue" },
        { "Hive": "SOFTWARE", "Path": "Microsoft\\WindowsUpdate\\Orchestrator\\UScheduler_Oobe\\OutlookUpdate", "Action": "DeleteKey" }
      ]
    }
  ]
}
```

Empty lists in a category can be left out.

The texts `Name` and `Description` (of the profile, the categories and the registry entries) can be a plain string or translations: `{ "ru": "...", "en": "..." }`. The script takes the interface language, then English. The `"$schema"` line connects the schema [Schemas/Profile.schema.json](Schemas/Profile.schema.json): VS Code uses it to suggest fields and underline mistakes.

### Windows version requirements

A profile can say which Windows build it is made for:

```json
"Requirements": { "Build": 26300, "MinRevision": 9457, "Architecture": "amd64" }
```

- `Build`: the build number must match exactly (26300 is 26H2, 26200 is 25H2, 26100 is 24H2).
- `MinRevision`: the lowest revision, that is the number after the dot in `26300.9457`. Anything newer is fine, so the profile does not need editing after every monthly update.
- `Architecture`: `amd64` or `arm64`.

The script checks this against the selected edition right after reading the ISO, before copying any files. If the build does not match, it stops and tells you where to download a fresh ISO. If only the revision is too low and the updates folder has a cumulative Windows update, the script only warns: the update raises the revision. To build on a different build on purpose, run the script with `-SkipVersionCheck`. If the profile has no `Requirements` block, no check is made. A profile in the old format (with `Appx`, `Registry` and so on at the top level, without `Categories`) works too: it counts as one category.

Categories in `Profile.json`:

| Id | Category |
|---|---|
| `apps` | Built-in apps |
| `legacy` | Legacy components |
| `telemetry` | Telemetry and diagnostics |
| `ai` | Copilot and AI |
| `ads` | Ads and suggestions |
| `search` | Search and Bing |
| `store` | Microsoft Store |
| `drivers` | Drivers from Windows Update |
| `onedrive` | OneDrive |

To skip categories without editing the profile: `-SkipCategory store,onedrive`; to turn on one that is off: `-IncludeCategory drivers`. In step-by-step mode the script shows the list of categories, and you can turn them on and off by number; in the window they are switches under "What to remove and turn off".

Registry entries:

- `Hive`: `SOFTWARE` (HKLM\SOFTWARE), `SYSTEM` (HKLM\SYSTEM, use `ControlSet001` instead of `CurrentControlSet`) or `DefaultUser` (HKCU for all new users).
- `Name`: the value name. If you leave it out, the entry applies to the default value of the key.
- `Action`: `Set` (the default), `DeleteValue` or `DeleteKey`.
- `Type`: `REG_DWORD`, `REG_QWORD` (a number or a `"0x..."` string), `REG_SZ`, `REG_EXPAND_SZ`, `REG_MULTI_SZ` (an array of strings), `REG_BINARY` (a hex string, for example `"de ad be ef"`).
- `Value`: the value. Strings are written as they are, with quotes and a trailing `\`.
- `Description`: an optional note. The script and the window do not show it; it is for people who read the profile.

The script reports a mistake in an entry (an unknown type or action, not a number in `REG_DWORD`) right when it reads the profile, before the build.

The easiest way to find the exact names in your image is the "What is in the image" mode (see above). By hand you can do it like this (after `Mount-WindowsImage`):

```powershell
Get-AppxProvisionedPackage -Path C:\LunqWork\mount | Select DisplayName
Get-WindowsCapability     -Path C:\LunqWork\mount | Where State -eq Installed | Select Name
Get-WindowsOptionalFeature -Path C:\LunqWork\mount | Where State -eq Enabled | Select FeatureName
```

The `drivers` category turns off driver downloads from Windows Update and is off by default. If the system has no built-in driver for the network card or Wi-Fi, there is no internet after installation and you have to install the driver by hand. Turn it on (`"Enabled": true` in the profile, `-IncludeCategory drivers`, by number in step-by-step mode or with its switch in the window) only if you add the drivers you need to the image yourself (see "Drivers").

The default profile does not touch Microsoft Store, App Installer (winget), Terminal, Photos, Calculator, Notepad and Windows Security. The `Packages` lists are empty on purpose: removing CBS packages can break the installation of updates.

## Development

The code is laid out like this:

| Path | What is there |
|---|---|
| `LunqDebloater.ps1` | The script itself: parameters, step-by-step mode, checks and the build plan |
| `Install.ps1` | Loader for the one-command start (`irm ... \| iex`) |
| `Modules\LunqDebloater\` | The module with the functions. The version is set in the `LunqDebloater.psd1` manifest |
| `Modules\LunqDebloater\Private\` | Functions by topic: `Console`, `Language`, `Profile`, `Iso`, `Checks`, `Image`, `Servicing`, `Removal`, `Registry`, `PostInstall`, `Unattend`, `Inventory`, `Options` (the "What goes into the image" summary), `Build` (build steps), `Report`, `System` |
| `Modules\LunqDebloater\Strings\` | Interface texts: `ru\*.psd1` and `en\*.psd1` |
| `Modules\FirstLogon\FirstLogon.ps1` | The first sign-in script that is put into the image |
| `Schemas\Profile.schema.json` | JSON schema of the profile |
| `Gui\` | The Tauri window: `src-tauri` (Rust: runs the script and reads its events) and `ui` (HTML, CSS and JS without a bundler) |
| `Tests\` | Pester tests and a stub of the DISM module (`Tests\Gui.Tests.ps1` checks the window) |

The tests do not touch the system: stubs replace DISM, reg.exe, oscdimg and winget, and the build runs in the test folder. To run them and the analyzer (Pester 5 and PSScriptAnalyzer are needed):

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -MinimumVersion 1.23.0 -Scope CurrentUser -Force
Invoke-Pester -Path .\Tests
Invoke-ScriptAnalyzer -Path .\LunqDebloater.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\Install.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\Modules -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The window is built like this (you need [Rust](https://rustup.rs) and Visual Studio Build Tools with the "Desktop development with C++" workload):

```powershell
cd Gui\src-tauri
cargo build --release
```

The resulting `target\release\LunqDebloater.exe` finds the script in the folders above it, so you can run it right from there. Before a PR that changes the window, also run `cargo clippy -- -D warnings` in the same folder.

GitHub Actions runs the same for every PR and attaches the built window to the run as the `LunqDebloater-window` artifact. `LunqDebloater.exe` is attached to every published release automatically (`.github\workflows\window-release.yml`). What changed in each version is in [CHANGELOG.md](CHANGELOG.md).

The code layout, the order of build steps and the tests are described in detail in [ARCHITECTURE.en.md](ARCHITECTURE.en.md). How to propose a change and report a bug is described in [CONTRIBUTING.md](.github/CONTRIBUTING.md), how to report a vulnerability in [SECURITY.md](.github/SECURITY.md). Rules for AI assistants (Claude Code, Codex, Copilot) are in [AGENTS.md](AGENTS.md). The profile schema is in `Schemas\Profile.schema.json`; `.vscode\settings.json` maps it to the profiles in `Config*` folders, so VS Code suggests profile fields and checks them even without internet.

## License

[MIT](LICENSE).
