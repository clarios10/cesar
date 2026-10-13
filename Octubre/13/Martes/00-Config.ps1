<#
.SYNOPSIS
    Configuracion central y funciones auxiliares para los scripts de la Arquitectura de 3 Niveles.
.DESCRIPTION
    No se ejecuta solo: los demas scripts lo cargan con ". `"$PSScriptRoot\00-Config.ps1`"".
    EDITE ESTE ARCHIVO una sola vez (nombres, correo de alertas, etc.) y todos los scripts
    usaran los mismos valores. Los valores por defecto coinciden con la Guia de Actividades
    y con la hoja de costos 0_1-Info_Infra_01.csv.
#>

$ErrorActionPreference = 'Stop'

# ============================================================================
# 1. CONFIGURACION  (ajustar a los nombres reales que ya creo en el portal)
# ============================================================================
$Cfg = [ordered]@{
    Prefix         = 'contoso'
    ResourceGroup  = 'rg-contoso-app-prod'
    SubscriptionId = ''          # opcional; vacio = usa la suscripcion activa
    Location       = ''          # vacio = se toma la region del Resource Group
    Tags           = @{ Proyecto = 'Solucion-Web-3Niveles'; Ambiente = 'Produccion'; CentroCosto = 'TI-Infraestructura' }

    # ---- Red ---------------------------------------------------------------
    VnetName   = 'contoso-vnet'
    VnetPrefix = '10.10.0.0/16'
    Subnets    = [ordered]@{
        'snet-appgw'         = '10.10.1.0/24'
        'snet-app'           = '10.10.10.0/24'
        'snet-db'            = '10.10.20.0/24'
        'snet-mgmt'          = '10.10.30.0/24'
        'GatewaySubnet'      = '10.10.2.0/27'
        'AzureBastionSubnet' = '10.10.3.0/26'
    }
    OptionalSubnets = @('GatewaySubnet')      # no se marca FAIL si faltan (VPN es opcional)

    # ---- VM Servidor de Aplicacion ----------------------------------------
    VmApp = @{
        Name         = 'contoso-vm-app'
        ComputerName = 'vm-app-01'
        Size         = 'Standard_DC16ds_v3'          # 16 vCPU / 128 GB (CSV)
        Subnet       = 'snet-app'
        PrivateIp    = '10.10.10.4'                  # IP privada FIJA (primera usable de snet-app; Azure reserva .0-.3)
        OsDiskGB     = 512                           # P20
        Image        = @{ Publisher = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Sku = '2025-datacenter-azure-edition' }
        DataDisks    = @(
            @{ Lun = 0; SizeGB = 1024; Letter = 'E'; Label = 'APP';  Caching = 'ReadOnly' }   # P30
            @{ Lun = 1; SizeGB = 512;  Letter = 'F'; Label = 'LOGS'; Caching = 'None'     }   # P20
        )
    }

    # ---- VM Servidor de Base de Datos (+ SQL Server Standard PAYG) --------
    VmDb = @{
        Name         = 'contoso-vm-db'
        ComputerName = 'vm-db-01'
        Size         = 'Standard_D8as_v5'            # 8 vCPU / 32 GB (CSV)
        PrivateIp    = '10.10.20.4'                  # IP privada FIJA de la BD (primera usable de snet-db)
        Subnet       = 'snet-db'
        OsDiskGB     = 512                           # P20
        SqlPublisher = 'MicrosoftSQLServer'
        SqlOffers    = @('sql2025-ws2025', 'sql2022-ws2025')   # se usa el primero que exista en la region
        SqlSku       = 'standard-gen2'                          # SQL Server Standard
        SqlLicense   = 'PAYG'                                   # CSV: "SQL Standard (Pay as you go)"
        DataDisks    = @(
            @{ Lun = 0; SizeGB = 2048; Letter = 'F'; Label = 'SQLDATA'; Caching = 'ReadOnly' }  # P40
            @{ Lun = 1; SizeGB = 512;  Letter = 'G'; Label = 'SQLLOGS'; Caching = 'None'     }  # P20
        )
        SqlDataPath  = 'F:\SQLData'
        SqlLogPath   = 'G:\SQLLog'
    }

    # ---- Application Gateway + WAF ----------------------------------------
    AppGw = @{
        Name            = 'contoso-appgw'
        PipName         = 'contoso-pip-appgw'
        DnsLabel        = 'contoso-app'          # <label>.<region>.cloudapp.azure.com (debe ser unico en la region)
        Zones           = @('1', '2', '3')       # usar @() si la region no tiene zonas de disponibilidad
        Tier            = 'WAF_v2'               # 'WAF_v2' (con WAF) o 'Standard_v2' (sin WAF)
        MinCapacity     = 1
        MaxCapacity     = 3
        WafPolicyName   = 'contoso-wafpolicy'
        WafMode         = 'Prevention'
        WafRuleSetType  = 'OWASP'                # alternativa recomendada por Microsoft: 'Microsoft_DefaultRuleSet' / '2.1'
        WafRuleSetVer   = '3.2'
        BackendProtocol = 'Https'
        BackendPort     = 443
        BackendHostName = ''                     # ej. 'app.midominio.com' (recomendado si el backend usa HTTPS)
    }

    # ---- Azure Bastion -----------------------------------------------------
    Bastion = @{ Name = 'contoso-bastion'; PipName = 'contoso-pip-bastion'; Sku = 'Basic' }

    # ---- Monitoreo / Logs --------------------------------------------------
    Monitor = @{
        WorkspaceName  = 'contoso-law'
        RetentionDays  = 30
        DailyQuotaGb   = 10                      # CSV: 10 GB/dia
        ActionGroup    = 'contoso-ag-infra'
        ActionShort    = 'infraAlert'
        AlertEmail     = 'ti@contoso.com'        # <-- CAMBIAR
        DcrName        = 'contoso-dcr-windows'
    }

    # ---- Backup ------------------------------------------------------------
    Backup = @{
        VaultName   = 'contoso-rsv'
        Redundancy  = 'LocallyRedundant'         # LRS (CSV)
        PolicyName  = 'contoso-backup-policy'
        TimeUtc     = '05:00'
    }
}

# ---- Salida a Internet y acceso (TeamViewer / TSplus) -----------------------
$Cfg.Egress = @{
    NatGatewayName = 'contoso-natgw'
    NatPipName     = 'contoso-pip-natgw'          # IP publica FIJA de salida (util para listas blancas de TSplus/TeamViewer)
    Subnets        = @('snet-app', 'snet-db')     # subredes que saldran a Internet por el NAT Gateway
    IdleTimeoutMin = 10
}
$Cfg.Access = @{
    # Origenes (IP publica o CIDR) autorizados a llegar DIRECTO por 443 a la VM App para TSplus Web.
    # Vacio = NO se abre 443 desde Internet (los clientes entran por el Application Gateway/WAF, que ya tiene regla).
    TsplusInboundSources = @()                    # ej. @('203.0.113.10/32')
    # $true = bloquea toda salida a Internet salvo 443/80 (actualizaciones, TSplus, TeamViewer) y 5938 (TeamViewer)
    RestrictOutbound     = $true
    RestrictDbOutbound   = $true                  # igual para nsg-db (la BD no debe navegar)
}

# ---- NSG: nombres y reglas esperadas ---------------------------------------
# Los usan 01a (crear), 01b (agregar reglas a NSG existentes) y 01 (validar).
# Addr = origen para reglas Inbound / destino para reglas Outbound (texto o lista de textos).
$KmsAzure = @('20.118.99.224', '40.83.235.53', '23.102.135.246')   # kms.core.windows.net (activacion de Windows en Azure)
$AzurePlatform = '168.63.129.16'                                    # DNS/DHCP/agente de Azure

$appRules = @(
    @{ Name = 'Allow-HTTPS-From-AppGW';   Priority = 100;  Dir = 'Inbound';  Access = 'Allow'; Proto = 'Tcp'; Ports = @('443', '80'); Addr = $Cfg.Subnets['snet-appgw'] }
    @{ Name = 'Allow-Bastion-RDP';        Priority = 110;  Dir = 'Inbound';  Access = 'Allow'; Proto = 'Tcp'; Ports = @('3389');      Addr = $Cfg.Subnets['AzureBastionSubnet'] }
)
if (@($Cfg.Access.TsplusInboundSources).Count) {
    $appRules += @{ Name = 'Allow-TSplus-HTTPS-In'; Priority = 120; Dir = 'Inbound'; Access = 'Allow'; Proto = 'Tcp'; Ports = @('443'); Addr = @($Cfg.Access.TsplusInboundSources) }
}
$appRules += @(
    @{ Name = 'Deny-Internet-Inbound';    Priority = 4096; Dir = 'Inbound';  Access = 'Deny';  Proto = '*';   Ports = @('*');         Addr = 'Internet' }
    @{ Name = 'Allow-Azure-Platform-Out'; Priority = 90;   Dir = 'Outbound'; Access = 'Allow'; Proto = '*';   Ports = @('*');         Addr = $AzurePlatform }
    @{ Name = 'Allow-SQL-Outbound-To-DB'; Priority = 100;  Dir = 'Outbound'; Access = 'Allow'; Proto = 'Tcp'; Ports = @('1433');      Addr = $Cfg.Subnets['snet-db'] }
    @{ Name = 'Allow-KMS-Activation-Out'; Priority = 110;  Dir = 'Outbound'; Access = 'Allow'; Proto = 'Tcp'; Ports = @('1688');      Addr = $KmsAzure }
    @{ Name = 'Allow-Web-Internet-Out';   Priority = 120;  Dir = 'Outbound'; Access = 'Allow'; Proto = 'Tcp'; Ports = @('443', '80'); Addr = 'Internet' }   # TSplus 443, TeamViewer 443/80, Windows Update, Defender
    @{ Name = 'Allow-TeamViewer-Out';     Priority = 130;  Dir = 'Outbound'; Access = 'Allow'; Proto = '*';   Ports = @('5938');      Addr = 'Internet' }   # puerto preferido de TeamViewer
)
if ($Cfg.Access.RestrictOutbound) {
    $appRules += @{ Name = 'Deny-Internet-Outbound'; Priority = 4000; Dir = 'Outbound'; Access = 'Deny'; Proto = '*'; Ports = @('*'); Addr = 'Internet' }
}

$dbRules = @(
    @{ Name = 'Allow-SQL-From-App';       Priority = 100;  Dir = 'Inbound';  Access = 'Allow'; Proto = 'Tcp'; Ports = @('1433');      Addr = $Cfg.Subnets['snet-app'] }
    @{ Name = 'Allow-Bastion-RDP';        Priority = 110;  Dir = 'Inbound';  Access = 'Allow'; Proto = 'Tcp'; Ports = @('3389');      Addr = $Cfg.Subnets['AzureBastionSubnet'] }
    @{ Name = 'Deny-All-Inbound';         Priority = 4096; Dir = 'Inbound';  Access = 'Deny';  Proto = '*';   Ports = @('*');         Addr = '*' }
)
if ($Cfg.Access.RestrictDbOutbound) {
    $dbRules += @(
        @{ Name = 'Allow-Azure-Platform-Out'; Priority = 90;   Dir = 'Outbound'; Access = 'Allow'; Proto = '*';   Ports = @('*');         Addr = $AzurePlatform }
        @{ Name = 'Allow-KMS-Activation-Out'; Priority = 110;  Dir = 'Outbound'; Access = 'Allow'; Proto = 'Tcp'; Ports = @('1688');      Addr = $KmsAzure }
        @{ Name = 'Allow-Web-Internet-Out';   Priority = 120;  Dir = 'Outbound'; Access = 'Allow'; Proto = 'Tcp'; Ports = @('443', '80'); Addr = 'Internet' }   # parches, Defender, extension SQL IaaS
        @{ Name = 'Deny-Internet-Outbound';   Priority = 4000; Dir = 'Outbound'; Access = 'Deny';  Proto = '*';   Ports = @('*');         Addr = 'Internet' }
    )
}

$Cfg.NsgNames = [ordered]@{ 'snet-app' = 'nsg-app'; 'snet-db' = 'nsg-db'; 'snet-mgmt' = 'nsg-mgmt' }
$Cfg.NsgRules = [ordered]@{
    'snet-app'  = $appRules
    'snet-db'   = $dbRules
    'snet-mgmt' = @(
        @{ Name = 'Allow-Bastion-RDP-SSH';    Priority = 100;  Dir = 'Inbound';  Access = 'Allow'; Proto = 'Tcp'; Ports = @('3389', '22'); Addr = $Cfg.Subnets['AzureBastionSubnet'] }
    )
}

# ============================================================================
# 2. FUNCIONES AUXILIARES
# ============================================================================
if (-not (Get-Variable -Name CheckResults -Scope Global -ErrorAction SilentlyContinue)) {
    $global:CheckResults = New-Object System.Collections.ArrayList
}

function Write-Section { param([string]$Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

function Add-Check {
    param(
        [string]$Area,
        [string]$Name,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [string]$Detail = ''
    )
    [void]$global:CheckResults.Add([pscustomobject]@{ Area = $Area; Check = $Name; Status = $Status; Detail = $Detail })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; INFO = 'Gray' }[$Status]
    Write-Host ('[{0}] {1}{2}' -f $Status.PadRight(4), $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor $color
}

function Assert-Check {
    param([string]$Area, [string]$Name, [bool]$Ok, [string]$Detail = '', [ValidateSet('FAIL', 'WARN')][string]$Else = 'FAIL')
    Add-Check -Area $Area -Name $Name -Status $(if ($Ok) { 'PASS' } else { $Else }) -Detail $Detail
}

function Show-CheckSummary {
    param([string]$ReportName = 'reporte-validacion')
    $rows = @($global:CheckResults)
    $count = { param($s) @($rows | Where-Object Status -eq $s).Count }
    Write-Host "`n================ RESUMEN ================" -ForegroundColor Cyan
    Write-Host ("PASS: {0}   WARN: {1}   FAIL: {2}   INFO: {3}" -f (& $count 'PASS'), (& $count 'WARN'), (& $count 'FAIL'), (& $count 'INFO'))
    $bad = @($rows | Where-Object { $_.Status -in 'FAIL', 'WARN' })
    if ($bad.Count) {
        Write-Host "`nPuntos a revisar:" -ForegroundColor Yellow
        foreach ($r in ($bad | Sort-Object @{ Expression = { $_.Status -ne 'FAIL' } }, Area)) {
            Write-Host ('  [{0}] {1} / {2}{3}' -f $r.Status, $r.Area, $r.Check, $(if ($r.Detail) { " - $($r.Detail)" } else { '' })) -ForegroundColor $(if ($r.Status -eq 'FAIL') { 'Red' } else { 'Yellow' })
        }
    }
    $file = Join-Path $PSScriptRoot ("{0}-{1}.csv" -f $ReportName, (Get-Date -Format 'yyyyMMdd-HHmm'))
    $rows | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    Write-Host "Reporte guardado en: $file" -ForegroundColor Gray
    if ((& $count 'FAIL') -eq 0) { Write-Host 'RESULTADO: sin fallas criticas.' -ForegroundColor Green }
    else { Write-Host 'RESULTADO: hay FALLAS que corregir.' -ForegroundColor Red }
}

function Initialize-AzSession {
    param([string[]]$Modules = @('Az.Accounts', 'Az.Resources', 'Az.Network', 'Az.Compute'))
    foreach ($m in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            throw "Falta el modulo '$m'. Instale con: Install-Module Az -Scope CurrentUser -Repository PSGallery -Force   (o use Azure Cloud Shell, que ya lo incluye)."
        }
    }
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) { Connect-AzAccount | Out-Null; $ctx = Get-AzContext }
    if ($Cfg.SubscriptionId) { Set-AzContext -SubscriptionId $Cfg.SubscriptionId | Out-Null; $ctx = Get-AzContext }
    $rg = Get-AzResourceGroup -Name $Cfg.ResourceGroup -ErrorAction SilentlyContinue
    if (-not $rg) { throw "No existe el Resource Group '$($Cfg.ResourceGroup)'. Revise `$Cfg.ResourceGroup en 00-Config.ps1." }
    if (-not $Cfg.Location) { $Cfg.Location = $rg.Location }
    Write-Host ("Suscripcion: {0} ({1})  |  RG: {2}  |  Region: {3}" -f $ctx.Subscription.Name, $ctx.Subscription.Id, $Cfg.ResourceGroup, $Cfg.Location) -ForegroundColor Gray
}

function Confirm-Plan {
    param([string]$Title, [string[]]$Lines, [switch]$Force)
    Write-Section $Title
    $Lines | ForEach-Object { Write-Host "  - $_" }
    if ($Force) { return }
    $ans = Read-Host "`nContinuar? (S/N)"
    if ($ans -notmatch '^[sSyY]') { throw 'Cancelado por el usuario.' }
}

function Get-AdminCredentialChecked {
    param([pscredential]$Credential)
    if (-not $Credential) { $Credential = Get-Credential -Message 'Usuario y contrasena de administrador LOCAL de la VM (no se guardan en ningun archivo)' }
    $reserved = 'administrator', 'admin', 'user', 'user1', 'test', 'test1', 'guest', 'root', 'sql', 'server', 'owner', 'backup', 'console', 'support', 'sys'
    if ($reserved -contains $Credential.UserName.ToLower()) { throw "El usuario '$($Credential.UserName)' esta reservado por Azure. Use otro (ej. azadmin)." }
    $p = $Credential.GetNetworkCredential().Password
    $classes = @(($p -cmatch '[a-z]'), ($p -cmatch '[A-Z]'), ($p -match '\d'), ($p -match '[^a-zA-Z0-9]')) | Where-Object { $_ }
    if ($p.Length -lt 12 -or $p.Length -gt 123 -or $classes.Count -lt 3) {
        throw 'La contrasena debe tener 12-123 caracteres y 3 de 4 tipos (mayuscula, minuscula, numero, simbolo).'
    }
    return $Credential
}

function Invoke-ArmRest {
    param(
        [ValidateSet('GET', 'PUT', 'PATCH', 'POST', 'DELETE')][string]$Method,
        [string]$Path,
        [object]$Body,
        [switch]$AllowNotFound
    )
    $p = @{ Method = $Method; Path = $Path }
    if ($null -ne $Body) { $p.Payload = ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
    $r = Invoke-AzRestMethod @p
    if ($AllowNotFound -and $r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -ge 300) { throw "ARM $Method $Path -> HTTP $($r.StatusCode): $($r.Content)" }
    if ($r.Content) { return ($r.Content | ConvertFrom-Json) }
}

function Get-RgPath {
    # Devuelve /subscriptions/<id>/resourceGroups/<rg>
    "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$($Cfg.ResourceGroup)"
}

function Test-VmSkuAvailable {
    # Verifica que el tamano exista en la region, no este restringido y que haya cuota de vCPU.
    param([string]$Size)
    $sku = Get-AzComputeResourceSku -Location $Cfg.Location | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $Size } | Select-Object -First 1
    if (-not $sku) { throw "El tamano $Size NO existe en la region $($Cfg.Location). Elija otra region o tamano." }
    $blocked = @($sku.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' })
    if ($blocked.Count) { throw "El tamano $Size esta restringido para su suscripcion en $($Cfg.Location). Solicite acceso/cuota en el portal (Ayuda + soporte)." }
    $vcpus = [int](($sku.Capabilities | Where-Object Name -eq 'vCPUs').Value)
    $usage = Get-AzVMUsage -Location $Cfg.Location | Where-Object { $_.Name.Value -eq $sku.Family } | Select-Object -First 1
    if ($usage) {
        $free = $usage.Limit - $usage.CurrentValue
        Write-Host ("Cuota {0}: usado {1} de {2} vCPU (requiere {3})" -f $usage.Name.LocalizedValue, $usage.CurrentValue, $usage.Limit, $vcpus) -ForegroundColor Gray
        if ($free -lt $vcpus) { throw "Cuota de vCPU insuficiente para la familia $($sku.Family): libres $free, requiere $vcpus. Solicite aumento de cuota." }
    }
}

function Get-LatestImage {
    param([string]$Publisher, [string]$Offer, [string]$Sku)
    $versions = Get-AzVMImage -Location $Cfg.Location -PublisherName $Publisher -Offer $Offer -Skus $Sku -ErrorAction SilentlyContinue
    if (-not $versions) { return $null }
    $latest = ($versions | Sort-Object { [version]($_.Version -replace '[^0-9.]', '') } -Descending | Select-Object -First 1).Version
    return Get-AzVMImage -Location $Cfg.Location -PublisherName $Publisher -Offer $Offer -Skus $Sku -Version $latest
}

function Get-DiskInitScript {
    # Genera el script que se ejecuta DENTRO de la VM para inicializar/formatear los discos de datos
    # (NTFS, bloques de 64 KB) y extender C: si el disco de SO es mas grande que la imagen.
    param([object[]]$Disks)
    $out = New-Object System.Text.StringBuilder
    [void]$out.AppendLine('$ErrorActionPreference = ''Continue''')
    [void]$out.AppendLine('try { $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax; if ((Get-Partition -DriveLetter C).Size -lt $max) { Resize-Partition -DriveLetter C -Size $max; Write-Output ''C: extendido al tamano del disco'' } } catch { Write-Output "C: sin cambios ($($_.Exception.Message))" }')
    foreach ($d in $Disks) {
        $blk = @"
`$raw = Get-Disk | Where-Object { `$_.PartitionStyle -eq 'RAW' -and [math]::Round(`$_.Size / 1GB) -eq $($d.SizeGB) } | Select-Object -First 1
if (`$raw) {
    Initialize-Disk -Number `$raw.Number -PartitionStyle GPT -PassThru |
        New-Partition -DriveLetter $($d.Letter) -UseMaximumSize |
        Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel '$($d.Label)' -Confirm:`$false | Out-Null
    Write-Output 'Disco $($d.Label) ($($d.SizeGB) GB) inicializado como $($d.Letter):'
} elseif (Test-Path '$($d.Letter):\') { Write-Output 'Unidad $($d.Letter): ya existe (sin cambios)' }
else { Write-Output 'ADVERTENCIA: no se encontro disco RAW de $($d.SizeGB) GB para $($d.Label)' }
"@
        [void]$out.AppendLine($blk)
    }
    return $out.ToString()
}

function Invoke-VmScript {
    param([string]$VmName, [string]$Script)
    $r = Invoke-AzVMRunCommand -ResourceGroupName $Cfg.ResourceGroup -VMName $VmName -CommandId 'RunPowerShellScript' -ScriptString $Script
    $msg = ($r.Value | ForEach-Object { $_.Message }) -join "`n"
    return $msg
}

function Split-ResourceId {
    param([string]$Id)
    $seg = $Id -split '/'
    [pscustomobject]@{ Name = $seg[-1]; ResourceGroup = $seg[4] }
}

function Get-VmSubnetName {
    # Nombre de la subred en la que esta la primera NIC de la VM (independiente de como se llame la NIC)
    param($Vm)
    $n = Split-ResourceId $Vm.NetworkProfile.NetworkInterfaces[0].Id
    $nic = Get-AzNetworkInterface -Name $n.Name -ResourceGroupName $n.ResourceGroup
    return [pscustomobject]@{
        Nic       = $nic
        Subnet    = ($nic.IpConfigurations[0].Subnet.Id -split '/')[-1]
        PrivateIp = $nic.IpConfigurations[0].PrivateIpAddress
        PublicIps = @($nic.IpConfigurations | Where-Object { $_.PublicIpAddress } | ForEach-Object { $_.PublicIpAddress.Id })
    }
}
