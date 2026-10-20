# Strings for Private\Unattend.ps1.
@{
    'Unattend.Title'             = 'Answer file'
    'Unattend.Oobe'              = 'no license and privacy questions'
    'Unattend.Region'            = 'region {0}, time zone {1}'
    'Unattend.Bypass'            = 'TPM, Secure Boot and RAM requirements bypassed'
    'Unattend.LocalAccount'      = 'local account'
    'Unattend.WithFirstLogon'    = '{0}, apps and scripts run after installation'
    'Unattend.Exists'            = 'The ISO already has autounattend.xml, so our own answer file cannot be added.'
    'Unattend.NoImageLanguage'   = 'Could not find out the image language: Windows Setup will ask for the language itself.'
    'Unattend.LocalAccountNamed' = 'local account {0} without a password'
    'Unattend.NameEmpty'         = 'The local account name is empty.'
    'Unattend.NameTooLong'       = 'The account name {0} is longer than 20 characters.'
    'Unattend.NameBadChars'      = 'The account name {0} contains characters that are not allowed: " / \ [ ] : ; | = , + * ? < > @ '' %'
    'Unattend.NameBadForm'       = 'The account name {0} cannot start or end with a space, end with a dot, or consist of dots and spaces only.'
    'Unattend.NameReserved'      = 'The name {0} is taken by Windows itself, choose another one.'
    'Unattend.AskName'           = 'Local account name (Enter: {0}, "-": ask during setup)'
}
