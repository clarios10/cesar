<#
.SYNOPSIS
    Crea la IP publica Standard y el Application Gateway WAF_v2 (politica WAF en modo Prevention) con backend = VM de Aplicacion.
.DESCRIPTION
    Listener:
      - Con certificado PFX (-PfxPath + -PfxPassword): HTTPS 443.
      - Sin certificado: crea un listener HTTP 80 TEMPORAL para poder probar el WAF (se advierte en pantalla).
      - Certificado desde Key Vault: PowerShell NO permite combinar identidad administrada y politica WAF en la
        misma operacion de creacion. Cree el gateway con este script (HTTP temporal) y luego, en el portal:
        Application Gateway > Listeners > appListener > Protocolo HTTPS > "Elegir un certificado de Key Vault".
    Backend:
      - Protocolo/puerto segun $Cfg.AppGw (por defecto HTTPS 443). Si el backend usa un certificado
        autofirmado/interno, indique -BackendRootCertPath (.cer del certificado raiz) o el probe quedara
        "Unhealthy". El Application Gateway v2 solo confia por defecto en CAs publicas.
    Nota de costos: el CSV estima "Estandar V2"; WAF_v2 (con WAF) tiene una tarifa fija por hora mayor.
    Si solo necesita enrutar sin WAF cambie $Cfg.AppGw.Tier a 'Standard_v2'.
#>
[CmdletBinding()]
param(
    [string]$PfxPath,
    [securestring]$PfxPassword,
    [string]$BackendRootCertPath,
    [ValidateSet('Https', 'Http')][string]$BackendProtocol,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

$a    = $Cfg.AppGw
$rg   = $Cfg.ResourceGroup
$loc  = $Cfg.Location
$proto = if ($BackendProtocol) { $BackendProtocol } else { $a.BackendProtocol }
$port  = if ($BackendProtocol -eq 'Http' -and $a.BackendProtocol -ne 'Http') { 80 } else { $a.BackendPort }

# --- 1. Idempotencia ---------------------------------------------------------
$existing = Get-AzApplicationGateway -Name $a.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "El Application Gateway '$($a.Name)' YA existe (estado $($existing.ProvisioningState), SKU $($existing.Sku.Tier)). No se modifica." -ForegroundColor Yellow
    return
}

# --- 2. Prerrequisitos -------------------------------------------------------
$vnet   = Get-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $rg
$subnet = $vnet.Subnets | Where-Object Name -eq 'snet-appgw'
if (-not $subnet) { throw "No existe la subred 'snet-appgw'." }

$vmApp = Get-AzVM -Name $Cfg.VmApp.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
if (-not $vmApp) { throw "No existe la VM de aplicacion '$($Cfg.VmApp.Name)'. Ejecute primero 02-Crear-VM-App.ps1." }
$backendIp = (Get-VmSubnetName -Vm $vmApp).PrivateIp

$useTls = [bool]$PfxPath
if ($PfxPath -and -not $PfxPassword) { throw 'Con -PfxPath debe indicar -PfxPassword (SecureString).' }
if ($PfxPath -and -not (Test-Path $PfxPath)) { throw "No se encontro el archivo $PfxPath" }
if ($BackendRootCertPath -and -not (Test-Path $BackendRootCertPath)) { throw "No se encontro el archivo $BackendRootCertPath" }

if ($a.DnsLabel -and -not (Test-AzDnsAvailability -DomainNameLabel $a.DnsLabel -Location $loc)) {
    throw "La etiqueta DNS '$($a.DnsLabel)' ya esta en uso en $loc. Cambie `$Cfg.AppGw.DnsLabel en 00-Config.ps1."
}

$plan = @(
    "Region: $loc   |   Subred: snet-appgw ($($subnet.AddressPrefix))",
    "SKU: $($a.Tier)   |   Autoescalado: $($a.MinCapacity)-$($a.MaxCapacity)",
    "IP publica: $($a.PipName) (Standard, estatica, zonas: $(if ($a.Zones.Count) { $a.Zones -join ',' } else { 'sin zonas' }))  DNS: $($a.DnsLabel).$loc.cloudapp.azure.com",
    "Listener: $(if ($useTls) { 'HTTPS 443 con certificado' } else { 'HTTP 80 TEMPORAL (sin certificado) - solo para pruebas' })",
    "Backend: $($Cfg.VmApp.Name) -> $backendIp  ($proto $port)"
)
if ($a.Tier -eq 'WAF_v2') { $plan += "WAF: politica $($a.WafPolicyName), modo $($a.WafMode), reglas $($a.WafRuleSetType) $($a.WafRuleSetVer)" }
Confirm-Plan -Title "Se creara el Application Gateway $($a.Name)" -Lines $plan -Force:$Force
if (-not $useTls) { Write-Warning 'Sin certificado: se crea HTTP 80. Para produccion cambie el listener a HTTPS (certificado de Key Vault en el portal, o ejecute este script con -PfxPath/-PfxPassword).' }

# --- 3. IP publica -----------------------------------------------------------
$pip = Get-AzPublicIpAddress -Name $a.PipName -ResourceGroupName $rg -ErrorAction SilentlyContinue
if (-not $pip) {
    Write-Host "Creando IP publica $($a.PipName) ..." -ForegroundColor Cyan
    $pipArgs = @{
        Name = $a.PipName; ResourceGroupName = $rg; Location = $loc
        Sku = 'Standard'; Tier = 'Regional'; AllocationMethod = 'Static'; Tag = $Cfg.Tags
    }
    if ($a.DnsLabel)     { $pipArgs.DomainNameLabel = $a.DnsLabel }
    if ($a.Zones.Count)  { $pipArgs.Zone = $a.Zones }
    $pip = New-AzPublicIpAddress @pipArgs
}

# --- 4. Politica WAF ---------------------------------------------------------
$policy = $null
if ($a.Tier -eq 'WAF_v2') {
    Write-Host "Creando politica WAF $($a.WafPolicyName) ..." -ForegroundColor Cyan
    $policy = Get-AzApplicationGatewayFirewallPolicy -Name $a.WafPolicyName -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $policy) {
        $ps   = New-AzApplicationGatewayFirewallPolicySetting -Mode $a.WafMode -State Enabled -MaxFileUploadInMb 100 -MaxRequestBodySizeInKb 128
        $rs   = New-AzApplicationGatewayFirewallPolicyManagedRuleSet -RuleSetType $a.WafRuleSetType -RuleSetVersion $a.WafRuleSetVer
        $mr   = New-AzApplicationGatewayFirewallPolicyManagedRule -ManagedRuleSet $rs
        $policy = New-AzApplicationGatewayFirewallPolicy -Name $a.WafPolicyName -ResourceGroupName $rg -Location $loc -PolicySetting $ps -ManagedRule $mr -Tag $Cfg.Tags
    }
}

# --- 5. Componentes del Application Gateway ---------------------------------
$gwIp     = New-AzApplicationGatewayIPConfiguration -Name 'gatewayIpConfig' -Subnet $subnet
$fip      = New-AzApplicationGatewayFrontendIPConfig -Name 'frontendIpPublic' -PublicIPAddress $pip
$fePort   = New-AzApplicationGatewayFrontendPort -Name $(if ($useTls) { 'port443' } else { 'port80' }) -Port $(if ($useTls) { 443 } else { 80 })
$pool     = New-AzApplicationGatewayBackendAddressPool -Name 'appServerPool' -BackendIPAddresses $backendIp

$probeArgs = @{ Name = 'appHealthProbe'; Protocol = $proto; Path = '/'; Interval = 30; Timeout = 30; UnhealthyThreshold = 3 }
if ($a.BackendHostName) { $probeArgs.HostName = $a.BackendHostName } else { $probeArgs.PickHostNameFromBackendHttpSettings = $true }
$probe = New-AzApplicationGatewayProbeConfig @probeArgs

$rootCerts = @()
$httpArgs = @{ Name = 'appServerHttpSettings'; Port = $port; Protocol = $proto; CookieBasedAffinity = 'Disabled'; RequestTimeout = 30; Probe = $probe }
if ($a.BackendHostName) { $httpArgs.HostName = $a.BackendHostName } else { $httpArgs.PickHostNameFromBackendAddress = $true }
if ($proto -eq 'Https' -and $BackendRootCertPath) {
    $root = New-AzApplicationGatewayTrustedRootCertificate -Name 'backendRootCert' -CertificateFile $BackendRootCertPath
    $rootCerts += $root
    $httpArgs.TrustedRootCertificate = $root
}
$httpSettings = New-AzApplicationGatewayBackendHttpSetting @httpArgs

$sslCerts = @(); $listenerArgs = @{ Name = 'appListener'; FrontendIPConfiguration = $fip; FrontendPort = $fePort }
if ($useTls) {
    $ssl = New-AzApplicationGatewaySslCertificate -Name 'appSslCert' -CertificateFile $PfxPath -Password $PfxPassword
    $sslCerts += $ssl
    $listenerArgs.Protocol = 'Https'; $listenerArgs.SslCertificate = $ssl
} else { $listenerArgs.Protocol = 'Http' }
$listener = New-AzApplicationGatewayHttpListener @listenerArgs

$rule = New-AzApplicationGatewayRequestRoutingRule -Name 'appRoutingRule' -RuleType Basic -Priority 100 -HttpListener $listener -BackendAddressPool $pool -BackendHttpSettings $httpSettings
$sku  = New-AzApplicationGatewaySku -Name $a.Tier -Tier $a.Tier
$auto = New-AzApplicationGatewayAutoscaleConfiguration -MinCapacity $a.MinCapacity -MaxCapacity $a.MaxCapacity

$gwArgs = @{
    Name = $a.Name; ResourceGroupName = $rg; Location = $loc
    BackendAddressPools = $pool; BackendHttpSettingsCollection = $httpSettings
    FrontendIpConfigurations = $fip; GatewayIpConfigurations = $gwIp; FrontendPorts = $fePort
    HttpListeners = $listener; RequestRoutingRules = $rule; Probes = $probe
    Sku = $sku; AutoscaleConfiguration = $auto; Tag = $Cfg.Tags
}
if ($policy)           { $gwArgs.FirewallPolicy = $policy }
if ($sslCerts.Count)   { $gwArgs.SslCertificates = $sslCerts }
if ($rootCerts.Count)  { $gwArgs.TrustedRootCertificate = $rootCerts }

Write-Host "Creando Application Gateway $($a.Name) (20-30 minutos, no cierre la ventana)..." -ForegroundColor Cyan
New-AzApplicationGateway @gwArgs | Out-Null

$pip = Get-AzPublicIpAddress -Name $a.PipName -ResourceGroupName $rg
Write-Host "`nApplication Gateway creado." -ForegroundColor Green
Write-Host "  IP publica : $($pip.IpAddress)"
Write-Host "  FQDN       : $($pip.DnsSettings.Fqdn)"
Write-Host "  Backend    : $backendIp ($proto $port) - aparecera 'Unhealthy' hasta que la aplicacion escuche en ese puerto." -ForegroundColor Gray
Write-Host 'Siguiente paso: .\05-Crear-Bastion.ps1  y  .\06-Configurar-Monitoreo-Logs.ps1' -ForegroundColor Green
