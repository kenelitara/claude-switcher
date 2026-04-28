$PesterPreference = [PesterConfiguration]::Default
$PesterPreference.Run.Path = 'tests'
$PesterPreference.Output.Verbosity = 'Detailed'
$PesterPreference.Run.Exit = $true
