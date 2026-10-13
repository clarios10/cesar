<#
.SYNOPSIS
    Valida la VNet, las subredes y los NSG (reglas y asociaciones) contra la Guia de Actividades.
.DESCRIPTION
    Solo LEE (no modifica nada). Comprueba:
      - VNet y espacio de direcciones
      - Las 6 subredes (nombre, prefijo, tamano minimo de Bastion/Gateway)
      - NSG asociado a snet-app, snet-db y snet-mgmt
      - Reglas esperadas de cada NSG (se buscan por contenido, no por nombre)
      - Que ninguna regla exponga RDP/SSH/SQL a Internet
.PARAMETER NoSummary
    Omite el resumen final (lo usa 99-Validar-Todo.ps1).
#>
[CmdletBinding()]
param([switch]$NoSummary)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network

$ExpectedRules = $Cfg.NsgRules   # definidas en 00-Config.ps1

function Expand-Ports {
    param($Ranges)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in @($Ranges)) {
        if (-not $r) { continue }
        if ($r -match '^(\d+)-(\d+)$') { foreach ($i in ([int]$Matches[1])..([int]$Matches[2])) { [void]$set.Add("$i") } }
        else { [void]$set.Add($r) }
    }
    return , $set
}

function Find-NsgRule {
    param($Nsg, $Exp)
    foreach ($r in $Nsg.SecurityRules) {
        if ($r.Direction -ne $Exp.Dir -or $r.Access -ne $Exp.Access) { continue }
        if ($Exp.Proto -eq 'Tcp' -and $r.Protocol -notin 'Tcp', '*') { continue }
        if ($Exp.Proto -eq '*' -and $r.Protocol -ne '*') { continue }
        $ports = Expand-Ports $r.DestinationPortRange
        $okPorts = $ports.Contains('*') -or (@($Exp.Ports | Where-Object { -not $ports.Contains($_) }).Count -eq 0)
        $addr = if ($Exp.Dir -eq 'Inbound') { @($r.SourceAddressPrefix) } else { @($r.DestinationAddressPrefix) }
        if ($okPorts -and (@($Exp.Addr | Where-Object { $addr -notcontains $_ }).Count -eq 0)) { return $r }
    }
    return $null
}

# ----------------------------------------------------------------------------
Write-Section 'VNet'
$vnet = Get-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $Cfg.ResourceGroup -ErrorAction SilentlyContinue
if (-not $vnet) {
    Add-Check 'Red' "VNet '$($Cfg.VnetName)' existe" 'FAIL' 'No se encontro en el Resource Group'
    if (-not $NoSummary) { Show-CheckSummary -ReportName 'reporte-red-nsg' }
    return
}
Add-Check 'Red' "VNet '$($Cfg.VnetName)' existe" 'PASS' "Region: $($vnet.Location)"
Assert-Check 'Red' 'Espacio de direcciones de la VNet' ($vnet.AddressSpace.AddressPrefixes -contains $Cfg.VnetPrefix) "Esperado $($Cfg.VnetPrefix); actual: $($vnet.AddressSpace.AddressPrefixes -join ', ')"
Assert-Check 'Red' 'VNet en la misma region del Resource Group' ($vnet.Location -eq $Cfg.Location) "VNet: $($vnet.Location) / RG: $($Cfg.Location)"

# ----------------------------------------------------------------------------
Write-Section 'Subredes'
foreach ($name in $Cfg.Subnets.Keys) {
    $expected = $Cfg.Subnets[$name]
    $sn = $vnet.Subnets | Where-Object Name -eq $name
    if (-not $sn) {
        $optional = $Cfg.OptionalSubnets -contains $name
        Add-Check 'Red' "Subred $name" $(if ($optional) { 'WARN' } else { 'FAIL' }) $(if ($optional) { 'No existe (opcional: solo si se usara VPN)' } else { "No existe; debe crearse con $expected" })
        continue
    }
    $actual = @($sn.AddressPrefix)
    Assert-Check 'Red' "Subred $name prefijo" ($actual -contains $expected) "Esperado $expected; actual: $($actual -join ', ')"
    $len = [int](($actual[0] -split '/')[1])
    if ($name -eq 'AzureBastionSubnet') { Assert-Check 'Red' 'AzureBastionSubnet tamano minimo /26' ($len -le 26) "Actual /$len" }
    if ($name -eq 'GatewaySubnet')      { Assert-Check 'Red' 'GatewaySubnet tamano minimo /27' ($len -le 27) "Actual /$len" }
}
$extra = @($vnet.Subnets | Where-Object { $Cfg.Subnets.Keys -notcontains $_.Name } | ForEach-Object Name)
if ($extra.Count) { Add-Check 'Red' 'Subredes adicionales' 'INFO' ($extra -join ', ') }

# ----------------------------------------------------------------------------
Write-Section 'NSG: asociacion y reglas'
foreach ($subnetName in $ExpectedRules.Keys) {
    $sn = $vnet.Subnets | Where-Object Name -eq $subnetName
    if (-not $sn) { continue }
    if (-not $sn.NetworkSecurityGroup) {
        Add-Check 'NSG' "$subnetName tiene NSG asociado" 'FAIL' 'Sin NSG. Asocie el NSG correspondiente a la subred.'
        continue
    }
    $ref = Split-ResourceId $sn.NetworkSecurityGroup.Id
    $nsg = Get-AzNetworkSecurityGroup -Name $ref.Name -ResourceGroupName $ref.ResourceGroup
    Add-Check 'NSG' "$subnetName tiene NSG asociado" 'PASS' $nsg.Name
    foreach ($exp in $ExpectedRules[$subnetName]) {
        $found = Find-NsgRule -Nsg $nsg -Exp $exp
        $desc = '{0} {1} {2} puerto(s) {3} {4}' -f $exp.Dir, $exp.Access, $exp.Proto, ($exp.Ports -join ','), (@($exp.Addr) -join ',')
        if (-not $found) { Add-Check 'NSG' "[$($nsg.Name)] regla '$($exp.Name)'" 'FAIL' "No existe una regla equivalente: $desc" }
        elseif ($found.Priority -ne $exp.Priority) { Add-Check 'NSG' "[$($nsg.Name)] regla '$($exp.Name)'" 'WARN' "Existe como '$($found.Name)' con prioridad $($found.Priority) (esperada $($exp.Priority))" }
        else { Add-Check 'NSG' "[$($nsg.Name)] regla '$($exp.Name)'" 'PASS' "$($found.Name) (prioridad $($found.Priority))" }
    }
}

# Subredes especiales
$agw = $vnet.Subnets | Where-Object Name -eq 'snet-appgw'
if ($agw) {
    if (-not $agw.NetworkSecurityGroup) { Add-Check 'NSG' 'snet-appgw sin NSG' 'INFO' 'Correcto segun la guia (si agrega uno, debe permitir GatewayManager 65200-65535 y AzureLoadBalancer)' }
    else {
        $ref = Split-ResourceId $agw.NetworkSecurityGroup.Id
        $n = Get-AzNetworkSecurityGroup -Name $ref.Name -ResourceGroupName $ref.ResourceGroup
        $gm = $n.SecurityRules | Where-Object { $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' -and (@($_.SourceAddressPrefix) -contains 'GatewayManager') }
        Assert-Check 'NSG' 'snet-appgw: NSG permite GatewayManager 65200-65535' ([bool]$gm) 'Sin esa regla el Application Gateway v2 no se aprovisiona' 'FAIL'
    }
}
$gw = $vnet.Subnets | Where-Object Name -eq 'GatewaySubnet'
if ($gw -and $gw.NetworkSecurityGroup) { Add-Check 'NSG' 'GatewaySubnet con NSG' 'WARN' 'Microsoft no recomienda NSG en GatewaySubnet' }
$bas = $vnet.Subnets | Where-Object Name -eq 'AzureBastionSubnet'
if ($bas -and $bas.NetworkSecurityGroup) { Add-Check 'NSG' 'AzureBastionSubnet con NSG' 'WARN' 'Si lo usa, debe contener las reglas obligatorias de Bastion (443 desde Internet/GatewayManager, etc.)' }

# ----------------------------------------------------------------------------
Write-Section 'IP fija y salida a Internet'
foreach ($v in @($Cfg.VmApp, $Cfg.VmDb)) {
    if (-not $v.PrivateIp) { continue }
    $vmObj = Get-AzVM -Name $v.Name -ResourceGroupName $Cfg.ResourceGroup -ErrorAction SilentlyContinue
    if (-not $vmObj) { Add-Check 'Red' "IP fija de $($v.Name)" 'INFO' 'La VM aun no existe (se creara con la IP fija al ejecutar 02/03)'; continue }
    $nic = (Get-VmSubnetName -Vm $vmObj).Nic
    $ic = $nic.IpConfigurations[0]
    Assert-Check 'Red' "$($v.Name): IP privada $($v.PrivateIp)" ($ic.PrivateIpAddress -eq $v.PrivateIp) "Actual: $($ic.PrivateIpAddress). Corrija con .\02a-Fijar-IP-Privada.ps1"
    Assert-Check 'Red' "$($v.Name): IP asignada como ESTATICA" ($ic.PrivateIpAllocationMethod -eq 'Static') "Metodo actual: $($ic.PrivateIpAllocationMethod)" 'WARN'
}
$natInfo = Get-AzNatGateway -Name $Cfg.Egress.NatGatewayName -ResourceGroupName $Cfg.ResourceGroup -ErrorAction SilentlyContinue
if (-not $natInfo) {
    Add-Check 'Red' "NAT Gateway '$($Cfg.Egress.NatGatewayName)'" 'WARN' 'No existe. Sin salida explicita, Azure usa la IP de salida predeterminada (se retira para VNets nuevas). Ejecute .\08-Crear-NAT-Gateway.ps1'
} else {
    Add-Check 'Red' "NAT Gateway '$($Cfg.Egress.NatGatewayName)'" 'PASS' 'Existe'
    foreach ($k in $Cfg.Egress.Subnets) {
        $sn = $vnet.Subnets | Where-Object Name -eq $k
        Assert-Check 'Red' "Subred $k usa el NAT Gateway" ($sn -and $sn.NatGateway -and $sn.NatGateway.Id -like "*$($Cfg.Egress.NatGatewayName)") 'Asocielo con .\08-Crear-NAT-Gateway.ps1' 'WARN'
    }
}

# ----------------------------------------------------------------------------
Write-Section 'Seguridad: exposicion a Internet'
$risky = @()
foreach ($nsg in (Get-AzNetworkSecurityGroup -ResourceGroupName $Cfg.ResourceGroup)) {
    foreach ($r in $nsg.SecurityRules) {
        if ($r.Direction -ne 'Inbound' -or $r.Access -ne 'Allow') { continue }
        $openSrc = @($r.SourceAddressPrefix) | Where-Object { $_ -in '*', 'Internet', '0.0.0.0/0', 'Any' }
        if (-not $openSrc) { continue }
        $ports = Expand-Ports $r.DestinationPortRange
        $hit = @('3389', '22', '1433', '*') | Where-Object { $ports.Contains($_) }
        if ($hit) { $risky += "$($nsg.Name)/$($r.Name) (puertos $($hit -join ','))" }
    }
}
Assert-Check 'Seguridad' 'Ningun NSG expone RDP/SSH/SQL a Internet' ($risky.Count -eq 0) $(if ($risky.Count) { $risky -join '; ' } else { 'OK' })

if (-not $NoSummary) { Show-CheckSummary -ReportName 'reporte-red-nsg' }
