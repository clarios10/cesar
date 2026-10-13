<#
.SYNOPSIS
    Valida TODO el ambiente contra la Guia de Actividades y la hoja de costos. Solo lee, no modifica nada.
.DESCRIPTION
    Revisa: Resource Group, red + NSG (llama a 01-Validar-Red-NSG.ps1), las dos VMs (tamano, imagen, discos, NIC sin
    IP publica, licencia, agente de monitoreo, SQL IaaS), IPs publicas, Application Gateway + WAF (incluye salud del
    backend y una prueba de bloqueo del WAF), Bastion, Log Analytics / alertas / diagnosticos / heartbeat y Backup.
    Genera un CSV con el resultado (PASS / WARN / FAIL / INFO) en la misma carpeta.
.PARAMETER Deep
    Ademas ejecuta comandos DENTRO de las VMs (Run Command) para comprobar discos formateados, version de Windows,
    servicio y edicion de SQL Server y puerto 1433. Tarda 1-2 minutos por VM.
.PARAMETER SkipWafTest
    Omite la prueba HTTP contra la IP publica del Application Gateway.
#>
[CmdletBinding()]
param(
    [switch]$Deep,
    [switch]$SkipWafTest
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

$rg  = $Cfg.ResourceGroup
$rgp = Get-RgPath

function Invoke-Safe {
    param([string]$Area, [scriptblock]$Block)
    try { & $Block } catch { Add-Check $Area 'Error al ejecutar la validacion' 'WARN' $_.Exception.Message }
}

function Get-HttpStatus {
    param([string]$Uri)
    try { return [int](Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 20).StatusCode }
    catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } else { return -1 } }
}

# ============================================================================
Write-Section 'Resource Group'
Invoke-Safe 'General' {
    $r = Get-AzResourceGroup -Name $rg
    Add-Check 'General' "Resource Group $rg" 'PASS' "Region $($r.Location)"
    Assert-Check 'General' 'Tags corporativos en el RG' (($r.Tags.Count -gt 0)) ($(if ($r.Tags) { ($r.Tags.Keys -join ', ') } else { 'sin tags' })) 'WARN'
}

# ============================================================================
& "$PSScriptRoot\01-Validar-Red-NSG.ps1" -NoSummary

# ============================================================================
function Test-VmConfig {
    param($VmCfg, [bool]$IsDb)
    $name = $VmCfg.Name
    Write-Section "VM $name"
    $vm = Get-AzVM -Name $name -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $vm) { Add-Check 'VM' "$name existe" 'FAIL' 'No se encontro en el Resource Group'; return }
    Add-Check 'VM' "$name existe" 'PASS'

    $st    = Get-AzVM -Name $name -ResourceGroupName $rg -Status
    $power = ($st.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus
    Assert-Check 'VM' "$name encendida" ($power -eq 'VM running') $power 'WARN'
    Assert-Check 'VM' "$name tamano" ($vm.HardwareProfile.VmSize -eq $VmCfg.Size) "Esperado $($VmCfg.Size); actual $($vm.HardwareProfile.VmSize)"

    # Imagen / edicion
    $ir = $vm.StorageProfile.ImageReference
    if ($ir) {
        $imgText = "$($ir.Publisher):$($ir.Offer):$($ir.Sku)"
        if ($IsDb) {
            Assert-Check 'VM' "$name imagen SQL sobre Windows Server 2025" ($ir.Publisher -eq 'MicrosoftSQLServer' -and $ir.Offer -match '-ws2025$') $imgText
            Assert-Check 'VM' "$name edicion SQL Standard" ($ir.Sku -like 'standard*') "Sku: $($ir.Sku) (Enterprise/Developer/Web no coinciden con la hoja de costos)"
        } else {
            Assert-Check 'VM' "$name imagen Windows Server 2025" ($ir.Offer -eq 'WindowsServer' -and $ir.Sku -like '2025*') $imgText
        }
        Add-Check 'VM' "$name edicion de Windows" 'INFO' 'Datacenter: Azure no publica imagen Standard; el precio con licencia incluida es el mismo'
    } else { Add-Check 'VM' "$name imagen" 'WARN' 'La VM no se creo desde una imagen de Marketplace (imagen personalizada o disco)' }

    # Licencia Windows
    if ($vm.LicenseType -eq 'Windows_Server') { Add-Check 'VM' "$name licencia Windows" 'INFO' 'Azure Hybrid Benefit (licencia propia)' }
    else { Add-Check 'VM' "$name licencia Windows" 'INFO' 'Incluida en el precio por hora (pago por uso)' }

    # Disco de SO
    $os = Get-AzDisk -ResourceGroupName $rg -DiskName $vm.StorageProfile.OsDisk.Name
    Assert-Check 'VM' "$name disco SO $($VmCfg.OsDiskGB) GB" ($os.DiskSizeGB -eq $VmCfg.OsDiskGB) "Actual $($os.DiskSizeGB) GB (si es menor: apague la VM, Update-AzDisk con -DiskSizeGB y extienda C: en Windows)"
    Assert-Check 'VM' "$name disco SO Premium SSD LRS" ($os.Sku.Name -eq 'Premium_LRS') "Actual $($os.Sku.Name)"

    # Discos de datos
    foreach ($d in $VmCfg.DataDisks) {
        $dd = $vm.StorageProfile.DataDisks | Where-Object Lun -eq $d.Lun
        if (-not $dd) { Add-Check 'VM' "$name disco LUN $($d.Lun) ($($d.Label))" 'FAIL' "No existe; debe ser de $($d.SizeGB) GB"; continue }
        $disk = Get-AzDisk -ResourceGroupName $rg -DiskName $dd.Name
        Assert-Check 'VM' "$name disco LUN $($d.Lun) ($($d.Label)) $($d.SizeGB) GB" ($disk.DiskSizeGB -eq $d.SizeGB -and $disk.Sku.Name -eq 'Premium_LRS') "Actual $($disk.DiskSizeGB) GB, $($disk.Sku.Name)"
        Assert-Check 'VM' "$name disco LUN $($d.Lun) cache $($d.Caching)" ("$($dd.Caching)" -eq $d.Caching) "Actual $($dd.Caching)" 'WARN'
    }
    $extraDisks = @($vm.StorageProfile.DataDisks | Where-Object { $VmCfg.DataDisks.Lun -notcontains $_.Lun })
    if ($extraDisks.Count) { Add-Check 'VM' "$name discos adicionales" 'INFO' (($extraDisks | ForEach-Object { "$($_.Name) ($($_.DiskSizeGB) GB)" }) -join ', ') }

    # Red
    $net = Get-VmSubnetName -Vm $vm
    Assert-Check 'VM' "$name en subred $($VmCfg.Subnet)" ($net.Subnet -eq $VmCfg.Subnet) "Actual $($net.Subnet); IP privada $($net.PrivateIp)"
    Assert-Check 'VM' "$name SIN IP publica" ($net.PublicIps.Count -eq 0) $(if ($net.PublicIps.Count) { "Tiene IP publica: $($net.PublicIps -join ', ') (quitarla: debe entrar por AppGW/Bastion)" } else { 'OK' })

    # Monitoreo
    $ext = Get-AzVMExtension -ResourceGroupName $rg -VMName $name -Name 'AzureMonitorWindowsAgent' -ErrorAction SilentlyContinue
    Assert-Check 'Monitoreo' "$name agente Azure Monitor" ([bool]$ext -and $ext.ProvisioningState -eq 'Succeeded') $(if ($ext) { $ext.ProvisioningState } else { 'No instalado (ejecute 06-Configurar-Monitoreo-Logs.ps1)' }) 'WARN'

    # SQL IaaS
    if ($IsDb) {
        $sqlVm = Invoke-ArmRest -Method GET -Path "$rgp/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/$($name)?api-version=2023-10-01" -AllowNotFound
        if (-not $sqlVm) { Add-Check 'SQL' "$name registrada en SQL IaaS" 'WARN' 'No hay recurso "SQL virtual machine" (parches/backup/licencia no administrables desde el portal)' }
        else {
            Add-Check 'SQL' "$name registrada en SQL IaaS" 'PASS' "Modo $($sqlVm.properties.sqlManagement)"
            Assert-Check 'SQL' "$name licencia SQL = $($VmCfg.SqlLicense)" ($sqlVm.properties.sqlServerLicenseType -eq $VmCfg.SqlLicense) "Actual $($sqlVm.properties.sqlServerLicenseType)"
            Assert-Check 'SQL' "$name edicion SQL Standard" ($sqlVm.properties.sqlImageSku -eq 'Standard') "Actual $($sqlVm.properties.sqlImageSku)"
        }
    }

    # Prueba profunda dentro de la VM
    if ($Deep) {
        if ($power -ne 'VM running') { Add-Check 'VM' "$name prueba interna" 'WARN' 'VM apagada; se omite'; return }
        Write-Host "  (ejecutando comprobaciones dentro de $name ...)" -ForegroundColor Gray
        $probe = @'
Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { "VOL|{0}|{1}|{2}" -f $_.DriveLetter, $_.FileSystemLabel, [math]::Round($_.Size / 1GB) }
$o = Get-CimInstance Win32_OperatingSystem; "OS|$($o.Caption)|$($o.Version)"
$svc = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
if ($svc) {
    "SQLSVC|$($svc.Status)"
    "PORT1433|$([bool](Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue))"
    $sc = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source
    if ($sc) { $r = & $sc -S localhost -E -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(100)) + ' / ' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50))" 2>&1 | Select-Object -First 1; "SQLINFO|$r" }
}
'@
        $lines = (Invoke-VmScript -VmName $name -Script $probe) -split "`r?`n" | Where-Object { $_ -match '\|' }
        $vols  = @($lines | Where-Object { $_ -like 'VOL|*' } | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ Letter = $p[1]; Label = $p[2]; SizeGB = [int]$p[3] } })
        $osl   = $lines | Where-Object { $_ -like 'OS|*' } | Select-Object -First 1
        if ($osl) { Assert-Check 'VM' "$name sistema operativo" ($osl -match '2025') (($osl -split '\|')[1]) }
        $c = $vols | Where-Object Letter -eq 'C'
        if ($c) { Assert-Check 'VM' "$name volumen C: ~$($VmCfg.OsDiskGB) GB" ($c.SizeGB -ge ($VmCfg.OsDiskGB - 5)) "Actual $($c.SizeGB) GB (si es ~127 GB, extender la particion C:)" 'WARN' }
        foreach ($d in $VmCfg.DataDisks) {
            $v = $vols | Where-Object Letter -eq $d.Letter
            if (-not $v) { Add-Check 'VM' "$name unidad $($d.Letter): ($($d.Label))" 'FAIL' 'No existe; el disco no esta inicializado/formateado'; continue }
            Assert-Check 'VM' "$name unidad $($d.Letter): ($($d.Label))" ([math]::Abs($v.SizeGB - $d.SizeGB) -le 3) "Etiqueta '$($v.Label)', $($v.SizeGB) GB"
        }
        if ($IsDb) {
            $svcL = $lines | Where-Object { $_ -like 'SQLSVC|*' } | Select-Object -First 1
            $portL = $lines | Where-Object { $_ -like 'PORT1433|*' } | Select-Object -First 1
            $infoL = $lines | Where-Object { $_ -like 'SQLINFO|*' } | Select-Object -First 1
            Assert-Check 'SQL' "$name servicio MSSQLSERVER en ejecucion" ($svcL -like '*Running') "$svcL"
            Assert-Check 'SQL' "$name escuchando en 1433" ($portL -like '*True') "$portL"
            if ($infoL) { Assert-Check 'SQL' "$name edicion (consulta SQL)" ($infoL -match 'Standard') (($infoL -split '\|', 2)[1]) 'WARN' }
            else { Add-Check 'SQL' "$name consulta SQL" 'WARN' 'No se pudo consultar la edicion con sqlcmd (revise permisos de SYSTEM en SQL)' }
        }
    }
}
Invoke-Safe 'VM' { Test-VmConfig -VmCfg $Cfg.VmApp -IsDb $false }
Invoke-Safe 'VM' { Test-VmConfig -VmCfg $Cfg.VmDb  -IsDb $true }

# ============================================================================
Write-Section 'IPs publicas'
Invoke-Safe 'IP publica' {
    $pips = @(Get-AzPublicIpAddress -ResourceGroupName $rg)
    Add-Check 'IP publica' 'Cantidad de IPs publicas' 'INFO' "$($pips.Count) (esperadas: 1 AppGW + 1 Bastion$(if ($Cfg.Subnets.Contains('GatewaySubnet')) { ' [+1 VPN si se despliega]' }))"
    foreach ($p in $pips) {
        $attach = if ($p.IpConfiguration) { $p.IpConfiguration.Id } else { '' }
        $kind = if ($attach -match '/applicationGateways/') { 'AppGW' } elseif ($attach -match '/bastionHosts/') { 'Bastion' } elseif ($attach -match '/networkInterfaces/') { 'NIC de VM' } elseif ($attach -match '/virtualNetworkGateways/') { 'VPN' } else { 'sin asignar' }
        Assert-Check 'IP publica' "$($p.Name) Standard + estatica" ($p.Sku.Name -eq 'Standard' -and $p.PublicIpAllocationMethod -eq 'Static') "SKU $($p.Sku.Name), $($p.PublicIpAllocationMethod), asociada a: $kind, IP $($p.IpAddress)"
        if ($kind -eq 'NIC de VM') { Add-Check 'Seguridad' "$($p.Name) expone una VM a Internet" 'FAIL' 'Quite la IP publica de la NIC de la VM' }
        if ($kind -eq 'sin asignar') { Add-Check 'IP publica' "$($p.Name) sin asociar" 'WARN' 'Genera costo sin usarse' }
    }
}

# ============================================================================
Write-Section 'Application Gateway + WAF'
$a = $Cfg.AppGw
Invoke-Safe 'AppGW' {
    $agw = Get-AzApplicationGateway -Name $a.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $agw) { Add-Check 'AppGW' "$($a.Name) existe" 'FAIL' 'No existe (ejecute 04-Crear-AppGateway-WAF.ps1)'; return }
    Add-Check 'AppGW' "$($a.Name) existe" 'PASS'
    Assert-Check 'AppGW' 'Estado de aprovisionamiento' ($agw.ProvisioningState -eq 'Succeeded' -and $agw.OperationalState -eq 'Running') "$($agw.ProvisioningState) / $($agw.OperationalState)"
    Assert-Check 'AppGW' "SKU $($a.Tier)" ($agw.Sku.Tier -eq $a.Tier) "Actual $($agw.Sku.Tier)$(if ($agw.Sku.Tier -eq 'Standard_v2') { ' (sin WAF)' })"
    if ($agw.AutoscaleConfiguration) { Assert-Check 'AppGW' "Autoescalado $($a.MinCapacity)-$($a.MaxCapacity)" ($agw.AutoscaleConfiguration.MinCapacity -eq $a.MinCapacity -and $agw.AutoscaleConfiguration.MaxCapacity -eq $a.MaxCapacity) "Actual $($agw.AutoscaleConfiguration.MinCapacity)-$($agw.AutoscaleConfiguration.MaxCapacity)" 'WARN' }
    else { Add-Check 'AppGW' 'Autoescalado' 'WARN' "Capacidad fija: $($agw.Sku.Capacity)" }
    Assert-Check 'AppGW' 'En subred snet-appgw' ($agw.GatewayIPConfigurations[0].Subnet.Id -like '*/snet-appgw') $agw.GatewayIPConfigurations[0].Subnet.Id

    # WAF
    if ($agw.Sku.Tier -eq 'WAF_v2') {
        if ($agw.FirewallPolicy) {
            $ref = Split-ResourceId $agw.FirewallPolicy.Id
            $pol = Get-AzApplicationGatewayFirewallPolicy -Name $ref.Name -ResourceGroupName $ref.ResourceGroup
            Assert-Check 'WAF' 'Politica WAF habilitada' ("$($pol.PolicySettings.State)" -eq 'Enabled') "$($pol.Name): $($pol.PolicySettings.State)"
            Assert-Check 'WAF' "Modo $($a.WafMode) (bloquea ataques)" ("$($pol.PolicySettings.Mode)" -eq $a.WafMode) "Actual $($pol.PolicySettings.Mode) (en 'Detection' solo registra, no bloquea)"
            $rs = $pol.ManagedRules.ManagedRuleSets | Select-Object -First 1
            Add-Check 'WAF' 'Conjunto de reglas administradas' 'INFO' "$($rs.RuleSetType) $($rs.RuleSetVersion)"
        } elseif ($agw.WebApplicationFirewallConfiguration) {
            $w = $agw.WebApplicationFirewallConfiguration
            Assert-Check 'WAF' "WAF (configuracion clasica) modo $($a.WafMode)" ($w.Enabled -and "$($w.FirewallMode)" -eq $a.WafMode) "Habilitado=$($w.Enabled), modo=$($w.FirewallMode), reglas $($w.RuleSetType) $($w.RuleSetVersion)"
        } else { Add-Check 'WAF' 'Politica WAF' 'FAIL' 'WAF_v2 sin politica ni configuracion de firewall' }
    }

    # Listener / backend
    $lis = $agw.HttpListeners | Select-Object -First 1
    Assert-Check 'AppGW' 'Listener HTTPS' ("$($lis.Protocol)" -eq 'Https') "Protocolo actual: $($lis.Protocol)$(if ("$($lis.Protocol)" -ne 'Https') { ' (HTTP solo es valido para pruebas)' })" 'WARN'
    $appIp = (Get-VmSubnetName -Vm (Get-AzVM -Name $Cfg.VmApp.Name -ResourceGroupName $rg -ErrorAction Stop)).PrivateIp
    $addrs = @($agw.BackendAddressPools.BackendAddresses | ForEach-Object { if ($_.IpAddress) { $_.IpAddress } else { $_.Fqdn } })
    Assert-Check 'AppGW' 'Backend apunta a la VM de aplicacion' ($addrs -contains $appIp) "Pool: $($addrs -join ', '); VM app: $appIp"

    # Salud del backend
    Write-Host '  (consultando salud del backend, puede tardar un minuto...)' -ForegroundColor Gray
    $h = Get-AzApplicationGatewayBackendHealth -Name $a.Name -ResourceGroupName $rg
    foreach ($pool in $h.BackendAddressPools) { foreach ($s in $pool.BackendHttpSettingsCollection) { foreach ($srv in $s.Servers) {
        Assert-Check 'AppGW' "Salud del backend $($srv.Address)" ("$($srv.Health)" -eq 'Healthy') "$($srv.Health) $($srv.HealthProbeLog)" 'WARN'
    } } }

    # Prueba HTTP / WAF
    if (-not $SkipWafTest) {
        $fe = $agw.FrontendIPConfigurations[0].PublicIPAddress
        if ($fe) {
            $pr = Split-ResourceId $fe.Id
            $pip = Get-AzPublicIpAddress -Name $pr.Name -ResourceGroupName $pr.ResourceGroup
            $target = if ($pip.DnsSettings.Fqdn) { $pip.DnsSettings.Fqdn } else { $pip.IpAddress }
            $scheme = if ("$($lis.Protocol)" -eq 'Https') { 'https' } else { 'http' }
            $base = "${scheme}://${target}"
            $normal = Get-HttpStatus "$base/"
            $attack = Get-HttpStatus "$base/?id=1%27%20OR%20%271%27=%271&q=%3Cscript%3Ealert(1)%3C/script%3E"
            if ($normal -eq -1) { Add-Check 'WAF' "Conexion a $base" 'WARN' 'Sin respuesta (certificado no confiable, NSG, o aun aprovisionando)' }
            else { Assert-Check 'AppGW' "Peticion normal a $base" ($normal -lt 500) "HTTP $normal$(if ($normal -ge 500) { ' (backend no responde: revise salud del backend)' })" 'WARN' }
            if ($agw.Sku.Tier -eq 'WAF_v2' -and $attack -ne -1) {
                Assert-Check 'WAF' 'Prueba de ataque (SQLi + XSS) es bloqueada' ($attack -eq 403) "HTTP $attack (esperado 403 en modo Prevention)"
            } elseif ($attack -eq -1) { Add-Check 'WAF' 'Prueba de ataque' 'WARN' 'Sin respuesta' }
        }
    }
}

# ============================================================================
Write-Section 'Azure Bastion'
Invoke-Safe 'Bastion' {
    $b = Get-AzBastion -Name $Cfg.Bastion.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $b) { Add-Check 'Bastion' "$($Cfg.Bastion.Name) existe" 'FAIL' 'No existe (ejecute 05-Crear-Bastion.ps1)'; return }
    Add-Check 'Bastion' "$($Cfg.Bastion.Name) existe" 'PASS'
    Assert-Check 'Bastion' 'Estado de aprovisionamiento' ($b.ProvisioningState -eq 'Succeeded') $b.ProvisioningState
    Assert-Check 'Bastion' "SKU $($Cfg.Bastion.Sku)" ("$($b.Sku.Name)" -eq $Cfg.Bastion.Sku) "Actual $($b.Sku.Name)" 'WARN'
    Assert-Check 'Bastion' 'En AzureBastionSubnet' ($b.IpConfigurations[0].Subnet.Id -like '*/AzureBastionSubnet') $b.IpConfigurations[0].Subnet.Id
    Assert-Check 'Bastion' 'Tiene IP publica' ([bool]$b.IpConfigurations[0].PublicIpAddress) ''
}

# ============================================================================
Write-Section 'Log Analytics y alertas'
$law = $null
Invoke-Safe 'Monitoreo' {
    $m = $Cfg.Monitor
    $script:law = Get-AzOperationalInsightsWorkspace -ResourceGroupName $rg -Name $m.WorkspaceName -ErrorAction SilentlyContinue
    if (-not $script:law) { Add-Check 'Monitoreo' "Workspace $($m.WorkspaceName)" 'FAIL' 'No existe (ejecute 06-Configurar-Monitoreo-Logs.ps1)'; return }
    $l = $script:law
    Add-Check 'Monitoreo' "Workspace $($m.WorkspaceName)" 'PASS' "SKU $($l.Sku), retencion $($l.RetentionInDays) dias"
    Assert-Check 'Monitoreo' "Retencion $($m.RetentionDays) dias" ($l.RetentionInDays -eq $m.RetentionDays) "Actual $($l.RetentionInDays)" 'WARN'
    $w = Invoke-ArmRest -Method GET -Path "$rgp/providers/Microsoft.OperationalInsights/workspaces/$($m.WorkspaceName)?api-version=2023-09-01"
    $q = $w.properties.workspaceCapping.dailyQuotaGb
    Assert-Check 'Monitoreo' "Tope diario $($m.DailyQuotaGb) GB" ($q -eq $m.DailyQuotaGb) "Actual: $(if ($q -and $q -gt 0) { "$q GB" } else { 'sin tope' })" 'WARN'

    $ag = Invoke-ArmRest -Method GET -Path "$rgp/providers/Microsoft.Insights/actionGroups/$($m.ActionGroup)?api-version=2023-01-01" -AllowNotFound
    if (-not $ag) { Add-Check 'Monitoreo' "Grupo de acciones $($m.ActionGroup)" 'FAIL' 'No existe' }
    else {
        $mails = @($ag.properties.emailReceivers | ForEach-Object emailAddress)
        Assert-Check 'Monitoreo' 'Grupo de acciones con correo' ($mails.Count -gt 0) ($mails -join ', ')
        if ($mails -like '*@contoso.com') { Add-Check 'Monitoreo' 'Correo de alertas' 'WARN' 'Es el correo de ejemplo (contoso.com); cambielo' }
    }

    $dcr = Invoke-ArmRest -Method GET -Path "$rgp/providers/Microsoft.Insights/dataCollectionRules/$($m.DcrName)?api-version=2022-06-01" -AllowNotFound
    Assert-Check 'Monitoreo' "DCR $($m.DcrName)" ([bool]$dcr) $(if ($dcr) { 'OK' } else { 'No existe' })

    $alerts = @((Invoke-ArmRest -Method GET -Path "$rgp/providers/Microsoft.Insights/metricAlerts?api-version=2018-03-01").value)
    foreach ($v in @($Cfg.VmApp, $Cfg.VmDb)) {
        $vm = Get-AzVM -Name $v.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
        if (-not $vm) { continue }
        $assoc = Invoke-ArmRest -Method GET -Path "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2022-06-01" -AllowNotFound
        $linked = @($assoc.value | Where-Object { $_.properties.dataCollectionRuleId -like "*/$($m.DcrName)" })
        Assert-Check 'Monitoreo' "$($v.Name) asociada a la DCR" ($linked.Count -gt 0) $(if ($linked.Count) { 'OK' } else { 'Sin asociacion: no se envian datos a Log Analytics' })
        $mine = @($alerts | Where-Object { $_.properties.scopes -contains $vm.Id -or ($_.properties.scopes | Where-Object { $_ -ieq $vm.Id }) })
        $cpu  = $mine | Where-Object { $_.properties.criteria.allOf.metricName -contains 'Percentage CPU' -and $_.properties.enabled }
        $av   = $mine | Where-Object { $_.properties.criteria.allOf.metricName -contains 'VmAvailabilityMetric' -and $_.properties.enabled }
        Assert-Check 'Monitoreo' "$($v.Name) alerta de CPU > 85%" ([bool]$cpu) $(if ($cpu) { 'OK' } else { 'No existe' })
        Assert-Check 'Monitoreo' "$($v.Name) alerta de disponibilidad" ([bool]$av) $(if ($av) { 'OK' } else { 'No existe' })
    }

    # Diagnosticos hacia el workspace
    $targets = @()
    $agw = Get-AzApplicationGateway -Name $Cfg.AppGw.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue; if ($agw) { $targets += @{ N = $agw.Name; Id = $agw.Id } }
    $bas = Get-AzBastion -Name $Cfg.Bastion.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue;       if ($bas) { $targets += @{ N = $bas.Name; Id = $bas.Id } }
    foreach ($n in (Get-AzNetworkSecurityGroup -ResourceGroupName $rg)) { $targets += @{ N = $n.Name; Id = $n.Id } }
    foreach ($t in $targets) {
        $ds = Invoke-ArmRest -Method GET -Path "$($t.Id)/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" -AllowNotFound
        $ok = @($ds.value | Where-Object { $_.properties.workspaceId -ieq $l.ResourceId }).Count -gt 0
        Assert-Check 'Monitoreo' "Diagnosticos de $($t.N) hacia Log Analytics" $ok $(if ($ok) { 'OK' } else { 'No configurados' }) 'WARN'
    }

    # Heartbeat (datos recientes)
    if (Get-Command Invoke-AzOperationalInsightsQuery -ErrorAction SilentlyContinue) {
        try {
            $res = (Invoke-AzOperationalInsightsQuery -WorkspaceId $l.CustomerId -Query 'Heartbeat | where TimeGenerated > ago(15m) | summarize Last=max(TimeGenerated) by Computer').Results
            foreach ($v in @($Cfg.VmApp, $Cfg.VmDb)) {
                $hit = @($res | Where-Object { $_.Computer -like "$($v.ComputerName)*" })
                Assert-Check 'Monitoreo' "Heartbeat reciente de $($v.ComputerName)" ($hit.Count -gt 0) $(if ($hit.Count) { "Ultimo: $($hit[0].Last)" } else { 'Sin datos en 15 min (normal si el agente se instalo hace menos de 10 min)' }) 'WARN'
            }
        } catch { Add-Check 'Monitoreo' 'Consulta de Heartbeat' 'WARN' $_.Exception.Message }
    }
}

# ============================================================================
Write-Section 'Backup'
Invoke-Safe 'Backup' {
    if (-not (Get-Module -ListAvailable -Name Az.RecoveryServices)) { Add-Check 'Backup' 'Modulo Az.RecoveryServices' 'WARN' 'No instalado; se omite la validacion de backup'; return }
    $bk = $Cfg.Backup
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $rg -Name $bk.VaultName -ErrorAction SilentlyContinue
    if (-not $vault) { Add-Check 'Backup' "Vault $($bk.VaultName)" 'FAIL' 'No existe (ejecute 07-Configurar-Backup.ps1)'; return }
    Add-Check 'Backup' "Vault $($bk.VaultName)" 'PASS'
    $prop = Get-AzRecoveryServicesBackupProperty -Vault $vault
    Assert-Check 'Backup' "Redundancia $($bk.Redundancy)" ("$($prop.BackupStorageRedundancy)" -eq $bk.Redundancy) "Actual $($prop.BackupStorageRedundancy)" 'WARN'
    $pol = Get-AzRecoveryServicesBackupProtectionPolicy -Name $bk.PolicyName -VaultId $vault.ID -ErrorAction SilentlyContinue
    Assert-Check 'Backup' "Politica $($bk.PolicyName)" ([bool]$pol) $(if ($pol) { 'OK' } else { 'No existe' })
    $items = @(Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $vault.ID)
    foreach ($v in @($Cfg.VmApp, $Cfg.VmDb)) {
        $it = $items | Where-Object { $_.Name -like "*;$($v.Name)" } | Select-Object -First 1
        if (-not $it) { Add-Check 'Backup' "$($v.Name) protegida" 'FAIL' 'No esta protegida'; continue }
        Assert-Check 'Backup' "$($v.Name) protegida" ("$($it.ProtectionStatus)" -in 'Healthy', 'IRPending') "Estado $($it.ProtectionStatus); ultimo respaldo: $(if ($it.LastBackupTime) { "$($it.LastBackupTime) ($($it.LastBackupStatus))" } else { 'aun ninguno' })"
        if (-not $it.LastBackupTime) { Add-Check 'Backup' "$($v.Name) primer respaldo" 'WARN' 'Aun no se ejecuta; use 07-Configurar-Backup.ps1 -RunInitialBackup o espere al horario programado' }
    }
}

Show-CheckSummary -ReportName 'reporte-validacion'
