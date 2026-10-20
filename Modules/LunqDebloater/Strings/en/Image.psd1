# Strings for Private\Image.ps1.
@{
    'Image.CleanupFailed'      = 'Component store cleanup failed (dism.exe returned code {0}), the image will be larger. See the DISM log for details.'
    'Image.OscdimgNotFoundAt'  = 'oscdimg.exe was not found at {0}'
    'Image.OscdimgNotFound'    = 'oscdimg.exe was not found. Install the Windows ADK (the Deployment Tools component) or specify -OscdimgPath.'
    'Image.BootFileMissing'    = 'Boot file not found: {0}'
    'Image.FolderNameHasSpace' = 'The folder name {0} contains a space, oscdimg cannot build the ISO.'
    'Image.OscdimgFailed'      = 'oscdimg exited with code {0}'
    'Image.IsoReplaceFailed'   = 'The image is built, but {0} could not be replaced: {1} The finished image is in {2}.'
    'Image.SplitTitle'         = 'Splitting install.wim'
    'Image.SplitDone'          = '{0} split into parts of {2} MB: {1} of them (install.swm), the USB drive can be FAT32'
    'Image.SplitNoParts'       = 'Split-WindowsImage did not create {0}'
    'Image.WimSizeTitle'       = 'install.wim size'
    'Image.WimTooBig'          = 'install.wim takes {0}, and a FAT32 USB drive only holds files up to 4 GB. Write the ISO with Rufus (it splits the image itself or formats the drive as NTFS) or build with -SplitWim.'
    'Image.WimTooBigSummary'   = '{0}, over 4 GB: a FAT32 USB drive needs Rufus or -SplitWim'
}
