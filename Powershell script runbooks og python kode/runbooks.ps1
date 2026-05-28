param(
    [string]$FirstName,
    [string]$LastName,
    [string]$Department,
    [string]$JobTitle,
    [string]$ResponsibleManager,
    [string]$Description
)

Import-Module ActiveDirectory

$ErrorActionPreference = "Stop"

$SamAccountName = $null
$PrimaryEmail = $null
$RemoteRoutingAddress = $null
$Warnings = @()

try {

    Write-Output "[INFO] Starter brugeroprettelse"
    Write-Output "[INFO] Navn: $FirstName $LastName"
    Write-Output "[INFO] Afdeling: $Department | Rolle: $JobTitle"

    # Credentials
    $cred = Get-AutomationPSCredential -Name "ad-automation-credentials"

    if (-not $cred) {
        throw "Credentials ikke fundet"
    }

    # Password
    $Password = ConvertTo-SecureString "XXXXXXXXXX" -AsPlainText -Force

    # Display name
    $DisplayName = "$FirstName $LastName"

    # Scandinavian character conversion
    function Convert-ScandinavianChars {
        param([string]$Text)

        $Text = $Text -replace 'æ', 'ae'
        $Text = $Text -replace 'Æ', 'AE'
        $Text = $Text -replace 'ø', 'oe'
        $Text = $Text -replace 'Ø', 'OE'
        $Text = $Text -replace 'å', 'aa'
        $Text = $Text -replace 'Å', 'AA'

        return $Text
    }

    Write-Output "[INFO] Genererer brugernavn..."

    $SafeFirstName = Convert-ScandinavianChars $FirstName
    $SafeLastName  = Convert-ScandinavianChars $LastName

    # Remove unsupported characters
    $SafeFirstName = $SafeFirstName -replace '[^a-zA-Z]', ''
    $SafeLastName  = $SafeLastName -replace '[^a-zA-Z]', ''

    # Username logic
    $fn1 = $SafeFirstName.Substring(0, [Math]::Min(1, $SafeFirstName.Length))
    $fn2 = $SafeFirstName.Substring(0, [Math]::Min(2, $SafeFirstName.Length))
    $ln2 = $SafeLastName.Substring(0, [Math]::Min(2, $SafeLastName.Length))

    $SamAccountName = ($fn1 + $ln2).ToLower()

    Write-Output "[INFO] Oprindeligt brugernavn: $SamAccountName"

    # Collision handling
    if (Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'") {

        Write-Output "[INFO] Brugernavn findes, prøver alternativ"

        $SamAccountName = ($fn2 + $ln2).ToLower()
    }

    if ($JobTitle -like "Ekstern konsulent*") {
        $SamAccountName = "$SamAccountName-local"
    }

    Write-Output "[INFO] Endeligt brugernavn: $SamAccountName"

    # Email
    $UserPrincipalName = "$SamAccountName@company.com"
    $PrimaryEmail = $UserPrincipalName
    $RemoteRoutingAddress = "$SamAccountName@company.com.mail.onmicrosoft.com"

    Write-Output "[INFO] UPN: $UserPrincipalName"

    # OU path
    $OUPath = "OU=Departments,OU=HQ,DC=company,DC=local"

    # CN uniqueness
    $CNName = $DisplayName
    $counter = 1

    while (Get-ADUser -Filter "Name -eq '$CNName'" -SearchBase $OUPath) {

        Write-Output "[INFO] CN findes, prøver næste..."

        $CNName = "$DisplayName $counter"
        $counter++
    }

    Write-Output "[INFO] Endelig CN: $CNName"

    # License mapping
    $RoleLicenseMap = @{
        "Finance"             = "LIC_M365_BusinessPremium"
        "IT"                  = "LIC_M365_BusinessPremium"
        "Payroll"             = "LIC_M365_BusinessPremium"
        "People"              = "LIC_M365_BusinessPremium"
        "CustomerService"     = "LIC_M365_BusinessPremium"
        "Marketing"           = "LIC_M365_BusinessPremium"
        "Procurement"         = "LIC_M365_BusinessPremium"
        "BI"                  = "LIC_M365_BusinessPremium"
        "Ekstern konsulent"   = "LIC_M365_APPS"
    }

    # Role group mapping
    $RoleGroupMap = @{
        "Finance"             = "SR_Role_Administration_DK_Finance"
        "IT"                  = "SR_Role_Administration_DK_IT"
        "Payroll"             = "SR_Role_Administration_DK_Payroll"
        "People"              = "SR_Role_Administration_DK_People"
        "CustomerService"     = "SR_Role_Administration_DK_CustomerService"
        "Marketing"           = "SR_Role_Administration_DK_Marketing"
        "Procurement"         = "SR_Role_Administration_DK_Procurement"
        "BI"                  = "SR_Role_Administration_DK_BI"
        "Ekstern konsulent"   = "SR_Role_Administration_DK_Consultant"
    }

    # Manager
    $ManagerDN = $null

    if ($ResponsibleManager) {

        try {

            $ManagerUser = Get-ADUser -Filter "Name -eq '$ResponsibleManager'" -Credential $cred

            if ($ManagerUser) {

                $ManagerDN = $ManagerUser.DistinguishedName

                Write-Output "[INFO] Manager fundet: $ResponsibleManager"

            }
            else {

                $Warnings += "Manager ikke fundet: $ResponsibleManager"

                Write-Warning "[WARN] Manager ikke fundet"
            }
        }
        catch {

            $Warnings += "Manager opslag fejlede"

            Write-Warning "[WARN] Manager opslag fejlede"
        }
    }

    $ManagerParam = if ($ManagerDN) {
        @{ Manager = $ManagerDN }
    }
    else {
        @{}
    }

    # Create user
    Write-Output "[INFO] Opretter bruger..."

    New-ADUser `
        -Name $CNName `
        -GivenName $FirstName `
        -Surname $LastName `
        -DisplayName $DisplayName `
        -SamAccountName $SamAccountName `
        -UserPrincipalName $UserPrincipalName `
        -EmailAddress $PrimaryEmail `
        -Department $Department `
        -Title $JobTitle `
        -Description $Description `
        -Path $OUPath `
        -AccountPassword $Password `
        -Enabled $true `
        -Credential $cred `
        -OtherAttributes @{ extensionAttribute1 = "automation-script" } `
        @ManagerParam

    Start-Sleep -Seconds 5

    # Verify user
    $user = Get-ADUser -Identity $SamAccountName -Credential $cred

    if (-not $user) {
        throw "Bruger ikke fundet efter oprettelse"
    }

    Write-Output "[INFO] Bruger oprettet"

    # Assign license group
    if ($RoleLicenseMap.ContainsKey($JobTitle)) {

        try {

            Write-Output "[INFO] Tildeler licens..."

            Add-ADGroupMember `
                -Identity $RoleLicenseMap[$JobTitle] `
                -Members $user `
                -Credential $cred
        }
        catch {

            $Warnings += "Licenstildeling mislykkedes"

            Write-Warning "[WARN] Licenstildeling mislykkedes"
        }
    }

    # Assign role group
    if ($RoleGroupMap.ContainsKey($JobTitle)) {

        try {

            Write-Output "[INFO] Tildeler rollegruppe..."

            Add-ADGroupMember `
                -Identity $RoleGroupMap[$JobTitle] `
                -Members $user `
                -Credential $cred
        }
        catch {

            $Warnings += "Tildeling af rollegruppe mislykkedes"

            Write-Warning "[WARN] Tildeling af rollegruppe mislykkedes"
        }
    }

    # Exchange session
    Write-Output "[INFO] Forbinder til Exchange..."

    $Session = New-PSSession `
        -ConfigurationName Microsoft.Exchange `
        -ConnectionUri http://EXCHANGE01/PowerShell/
        -Credential $cred `
        -Authentication Kerberos

    if (-not $Session) {
        throw "Exchange session mislykkedes"
    }

    Import-PSSession $Session -DisableNameChecking -AllowClobber

    Write-Output "[INFO] Aktiverer mailbox..."

    Enable-RemoteMailbox `
        -Identity $user.DistinguishedName `
        -RemoteRoutingAddress $RemoteRoutingAddress

    Set-RemoteMailbox `
        -Identity $user.DistinguishedName `
        -PrimarySmtpAddress $PrimaryEmail

    Remove-PSSession $Session

    Write-Output "[INFO] Brugerklargøring fuldført"

    # Success log
    $LogSummary = [PSCustomObject]@{
        Source      = "automation-script"
        Username    = $SamAccountName
        Email       = $PrimaryEmail
        Department  = $Department
        JobTitle    = $JobTitle
        Manager     = $ResponsibleManager
        Status      = "SUCCESS"
        Warnings    = $Warnings
        Timestamp   = Get-Date
    }

    $LogSummary | ConvertTo-Json -Compress | Write-Output
}
catch {

    Write-Error "[ERROR] $($_.Exception.Message)"

    # Failure log
    $LogSummary = [PSCustomObject]@{
        Source      = "automation-script"
        Username    = $SamAccountName
        Email       = $PrimaryEmail
        Department  = $Department
        JobTitle    = $JobTitle
        Manager     = $ResponsibleManager
        Status      = "FAILED"
        Error       = ($_ | Out-String)
        Warnings    = $Warnings
        Timestamp   = Get-Date
    }

    $LogSummary | ConvertTo-Json -Compress | Write-Output
}