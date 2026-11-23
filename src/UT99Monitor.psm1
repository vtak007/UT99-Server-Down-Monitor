# UT99 Server Down Monitor module: dot-sources every src\*.ps1 and exports all functions.
Set-StrictMode -Version 3.0
foreach ($file in Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' | Sort-Object Name) {
    . $file.FullName
}
Export-ModuleMember -Function *
