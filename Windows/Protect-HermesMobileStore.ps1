# Private state for the companion contains signing keys, grants and admission receipts.
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
$full = [IO.Path]::GetFullPath($Path)
if ($full -eq [IO.Path]::GetPathRoot($full)) { throw 'Specify a dedicated companion state directory.' }
if ([IO.Directory]::Exists($full) -and ((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Use the physical path of the private directory.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
$security = New-Object Security.AccessControl.DirectorySecurity
$security.SetOwner($identity)
$security.SetAccessRuleProtection($true,$false)
foreach ($sid in @($identity, [Security.Principal.SecurityIdentifier]'S-1-5-18', [Security.Principal.SecurityIdentifier]'S-1-5-32-544')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $security.AddAccessRule($rule)
}
if ([IO.Directory]::Exists($full)) { [IO.Directory]::SetAccessControl($full,$security) }
else { [void][IO.Directory]::CreateDirectory($full,$security) }
