# Strings for Private\Schedule.ps1.
@{
    'Schedule.Description'  = 'LunqDebloater: rebuilds the ISO with fresh updates from the recipe {0}'
    'Schedule.CreateFailed' = 'Could not create the scheduled task (schtasks, code {0}).'
    'Schedule.Created'      = 'Task {0} created: the ISO will be rebuilt on the 15th of every month, first run {1}.'
    'Schedule.Removed'      = 'Task {0} removed.'
    'Schedule.NotFound'     = 'There is no task {0}, nothing to remove.'
    'Schedule.LegacyRemoved' = 'Removed the old-format task {0}: it ran the program folder, which the user can change. If it belonged to another recipe with the same name, create it again with -Schedule Monthly.'
    'Schedule.Copy'         = 'The task runs a copy of LunqDebloater, its settings and the recipe in {0}: only administrators can change it. After updating LunqDebloater or changing the settings, run -Schedule Monthly again.'
}
