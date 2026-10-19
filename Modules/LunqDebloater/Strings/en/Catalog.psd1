# Strings for Private\Catalog.ps1.
@{
    'Catalog.KindUpdate'       = 'cumulative update'
    'Catalog.KindDotNet'       = '.NET Framework update'
    'Catalog.KindSafeOS'       = 'Safe OS Dynamic Update'
    'Catalog.KindSetup'        = 'Setup Dynamic Update'
    'Catalog.Searching'        = 'Searching the Microsoft Update Catalog: {0}'
    'Catalog.Unreachable'      = 'The Microsoft Update Catalog (catalog.update.microsoft.com) did not respond: {0}. Check the internet connection or download the updates into Config\Updates manually.'
    'Catalog.NothingFound'     = 'Nothing found in the catalog: {0} for Windows 11 {1} {2}. If the catalog page has changed, download the update into Config\Updates manually.'
    'Catalog.NotFoundOptional' = 'Not found in the catalog: {0}. The build continues without it.'
    'Catalog.Found'            = '{0} of {1}'
    'Catalog.NoLinks'          = 'The catalog has no file links for {0}.'
    'Catalog.AlreadyHere'      = 'already downloaded: {0}'
    'Catalog.Downloading'      = 'downloading {0}'
    'Catalog.DownloadFailed'   = 'Could not download {0}: {1}'
    'Catalog.BadHash'          = 'The downloaded file {0} does not match the catalog checksum and was deleted. Run the build again.'
}
