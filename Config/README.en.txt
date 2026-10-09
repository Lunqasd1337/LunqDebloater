LunqDebloater settings folder
=============================

Everything in this folder goes into the image. Before the build the script shows the
"What goes into the image" summary, and you can turn off anything by its number
without deleting it from here.

  Profile.json   What to remove from Windows and which registry settings to change. The
                 profile is split into categories that can be turned on and off before
                 the build. You can put more profiles (*.json) here, then the script asks
                 which one to use.

  Apps.txt       Programs that winget installs at the first sign-in to Windows.
                 One program per line, the winget Id (to find it: winget search <name>).
                 Lines starting with # are skipped.

  Scripts\       Your *.ps1 scripts. They run once at the first sign-in, after the
                 programs are installed, in name order (10-settings.ps1, 20-cleanup.ps1),
                 with administrator rights. The other files in this folder are copied
                 too, and the scripts can use them by a relative path.

  Drivers\       Drivers: extracted .inf files together with .sys, .cat and the other
                 files, any subfolders. Windows installs them during setup.
                 To export all drivers from a running computer:
                     Export-WindowsDriver -Online -Destination .\Config\Drivers
                 A driver that comes as an .exe must be extracted first (7-Zip or /extract).
                 Drivers from a Microsoft catalog .cab: expand -F:* file.cab folder

  Updates\       .msu or .cab updates from https://www.catalog.update.microsoft.com
                 (search, for example, for "Windows 11 Version 26H2 x64" and take the
                 latest cumulative update). If the catalog has several files for an
                 update, download all of them: they are installed in ascending KB order.
                 Put Safe OS and Setup Dynamic Update packages in the subfolders:
                     Updates\SafeOS   Safe OS Dynamic Update (.cab) for WinRE;
                     Updates\Setup    Setup Dynamic Update (.cab) for Windows Setup.
                 They are added together with the Windows Setup and WinRE update
                 (-UpdatesToSetup, or the item under the updates in the step-by-step mode).

Drivers and updates are not stored in git, everything else is.

Whatever you change in the image, you change at your own risk: Microsoft does not support
removing components from Windows. See the "Disclaimer" section in README.en.md.

How the programs and scripts work after installation
----------------------------------------------------
The programs and scripts are copied into the image, to C:\Windows\Setup\Scripts\Lunq\User,
and started through FirstLogonCommands in Windows\System32\Sysprep\unattend.xml.
At the first sign-in a window with the progress opens. The script waits for the internet
(up to 5 minutes) and winget (up to 10 minutes), installs the programs silently, runs the
scripts and closes the window.
If there is no internet, a program did not install, or the window was closed halfway, the
unfinished work is repeated at the next sign-in (the LunqFirstLogon scheduled task, up to
5 attempts). While the programs are not installed, the scripts wait: they run after the
programs or on the last attempt. A script that failed is not run again. Your scripts and
the log are accessible to administrators only. When everything is
done, the copies of the scripts and the files next to them are deleted from the disk (they
may contain passwords); Apps.txt and the log remain:
C:\Windows\Setup\Scripts\Lunq\FirstLogon.log

Scripts in UTF-8 without a BOM are saved again with a BOM during the build: otherwise
Windows PowerShell 5.1 reads them as ANSI, and non-English text in quotes breaks the script.
A script counts as failed if it threw an error or ended with an exit code other than 0
(including the one of the last program in it). If that is intended, add exit 0 at the end.

If you use your own autounattend.xml with an oobeSystem section, Windows uses it, and the
programs and scripts do not start. In that case add the command from unattend.xml to your
file. The same happens if you tick any Windows option in the Rufus window when writing the
USB drive, including the bypass of the TPM, Secure Boot and memory requirements. It is
better to turn on the bypass and the local account in the LunqDebloater answer file (items
in the "What goes into the image" summary). If you cannot do without the Rufus options,
after installation run everything by hand as administrator:
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Lunq\FirstLogon.ps1

Several sets of settings
------------------------
You can copy the folder, for example to Config-Office, and build with it:
    .\LunqDebloater.ps1 -ConfigPath .\Config-Office
