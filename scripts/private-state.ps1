function Write-PrivateJson {
    param([string]$Path, $Value)
    # Protect the directory before writing so transient secret files inherit its ACL.
    $directory = Split-Path -Parent $Path
    $null = [IO.Directory]::CreateDirectory($directory)
    if ($IsWindows) {
        $directoryInfo = [IO.DirectoryInfo]::new($directory)
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) { $acl.RemoveAccessRuleSpecific($rule) }
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $user, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $acl)
        if (Test-Path -LiteralPath $Path) {
            $fileInfo = [IO.FileInfo]::new($Path)
            $fileAcl = [IO.FileSystemAclExtensions]::GetAccessControl($fileInfo)
            $fileAcl.SetAccessRuleProtection($true, $false)
            foreach ($rule in $fileAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) { $fileAcl.RemoveAccessRuleSpecific($rule) }
            $fileAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', 'Allow'))
            [IO.FileSystemAclExtensions]::SetAccessControl($fileInfo, $fileAcl)
        }
    } else {
        [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 100))
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
}
