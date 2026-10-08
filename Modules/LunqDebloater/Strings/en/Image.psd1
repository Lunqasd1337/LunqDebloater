# Strings for Private\Image.ps1.
@{
    'Image.CleanupFailed'      = 'Component store cleanup failed (dism.exe returned code {0}), the image will be larger. See the DISM log for details.'
    'Image.OscdimgNotFoundAt'  = 'oscdimg.exe was not found at {0}'
    'Image.OscdimgNotFound'    = 'oscdimg.exe was not found. Install the Windows ADK (the Deployment Tools component) or specify -OscdimgPath.'
    'Image.BootFileMissing'    = 'Boot file not found: {0}'
    'Image.FolderNameHasSpace' = 'The folder name {0} contains a space, oscdimg cannot build the ISO.'
    'Image.OscdimgFailed'      = 'oscdimg exited with code {0}'
}
