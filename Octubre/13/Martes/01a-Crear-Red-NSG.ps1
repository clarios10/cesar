<#
.SYNOPSIS
    Crea los 3 NSG (con sus reglas), la VNet y las 6 subredes, y asocia cada NSG a su subred.
.DESCRIPTION
    Valores tomados de 00-Config.ps1 (los mismos que valida 01-Validar-Red-NSG.ps1):
      - VNet contoso-vnet 10.10.0.0/16
      - snet-appgw 10.10.1.0/24 | snet-app 10.10.10.0/24 | snet-db 10.10.20.0/24 | snet-mgmt 10.10.30.0/24
      - GatewaySubnet 10.10.2.0/27 | AzureBastionSubnet 10.10.3.0/26
      - nsg-app -> snet-app, nsg-db -> snet-db, nsg-mgmt -> snet-mgmt
    Es seguro volver a ejecutarlo: SOLO crea lo que falta. No borra ni modifica reglas de NSG existentes, no cambia
    prefijos de subredes existentes y no reemplaza un NSG que ya este asociado a una subred.
    Al terminar ejecuta 01-Validar-Red-NSG.ps1 para confirmar el resultado.
.PARAMETER SkipGatewaySubnet
    No crea GatewaySubnet (solo se necesita si se desplegara VPN Gateway).
.PARAMETER SkipValidation
    No ejecuta la validacion final.
.PARAMETER Force
    No pide confirmacion.
#>
[CmdletBinding()]
param(
    [switch]$SkipGatewaySubnet,
    [switch]$SkipValidation,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network

$rg  = $Cfg.ResourceGroup
$loc = $Cfg.Location

function ConvertTo-IpRange {
    param([string]$Cidr)
    $ip, $len = $Cidr -split '/'
    $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    [array]::Reverse($b)
    $start = [uint64][BitConverter]::ToUInt32($b, 0)
    [pscustomobject]@{ Start = $start; End = $start + [uint64]([math]::Pow(2, 32 - [int]$len)) - 1 }
}

# --- 1. Subredes a manejar + verificacion de direccionamiento ----------------
$subnets = [ordered]@{}
foreach ($k in $Cfg.Subnets.Keys) {
    if ($k -eq 'GatewaySubnet' -and $SkipGatewaySubnet) { continue }
    $subnets[$k] = $Cfg.Subnets[$k]
}
$vn = ConvertTo-IpRange $Cfg.VnetPrefix
$names = @($subnets.Keys)
foreach ($k in $names) {
    $r = ConvertTo-IpRange $subnets[$k]
    if ($r.Start -lt $vn.Start -or $r.End -gt $vn.End) { throw "La subred $k ($($subnets[$k])) queda fuera del espacio de la VNet ($($Cfg.VnetPrefix))." }
}
for ($i = 0; $i -lt $names.Count; $i++) { for ($j = $i + 1; $j -lt $names.Count; $j++) {
    $a = ConvertTo-IpRange $subnets[$names[$i]]; $b = ConvertTo-IpRange $subnets[$names[$j]]
    if ($a.Start -le $b.End -and $b.Start -le $a.End) { throw "Las subredes $($names[$i]) y $($names[$j]) se traslapan." }
} }
if ([int](($subnets['AzureBastionSubnet'] -split '/')[1]) -gt 26) { throw 'AzureBastionSubnet debe ser /26 o mayor.' }

# --- 2. Estado actual y plan -------------------------------------------------
$vnet = Get-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $rg -ErrorAction SilentlyContinue
$nsgs = @{}      # subred -> objeto NSG existente (o $null si hay que crearlo)
$plan = @()
foreach ($sn in $Cfg.NsgNames.Keys) {
    $n = $Cfg.NsgNames[$sn]
    $obj = Get-AzNetworkSecurityGroup -Name $n -ResourceGroupName $rg -ErrorAction SilentlyContinue
    $nsgs[$sn] = $obj
    if ($obj) { $plan += "NSG $n : YA EXISTE ($(@($obj.SecurityRules).Count) reglas) - no se modifica; use 01-Validar-Red-NSG.ps1 para comparar sus reglas" }
    else      { $plan += "NSG $n : CREAR con $(@($Cfg.NsgRules[$sn]).Count) reglas -> se asocia a $sn" }
}
if (-not $vnet) {
    $plan += "VNet $($Cfg.VnetName) ($($Cfg.VnetPrefix)) : CREAR con subredes: $($names -join ', ')"
} else {
    $plan += "VNet $($Cfg.VnetName) : YA EXISTE (espacio: $($vnet.AddressSpace.AddressPrefixes -join ', '))"
    if ($vnet.AddressSpace.AddressPrefixes -notcontains $Cfg.VnetPrefix) { throw "La VNet existente no incluye $($Cfg.VnetPrefix); agreguelo en el portal o corrija `$Cfg.VnetPrefix." }
    foreach ($k in $names) {
        $sn = $vnet.Subnets | Where-Object Name -eq $k
        if (-not $sn) { $plan += "  subred $k ($($subnets[$k])) : AGREGAR" }
        elseif (@($sn.AddressPrefix) -notcontains $subnets[$k]) { $plan += "  subred $k : existe con prefijo $(@($sn.AddressPrefix) -join ',') (esperado $($subnets[$k])) - NO se cambia" }
        elseif ($Cfg.NsgNames.Contains($k) -and -not $sn.NetworkSecurityGroup) { $plan += "  subred $k : ASOCIAR $($Cfg.NsgNames[$k])" }
        else { $plan += "  subred $k : OK" }
    }
}
Confirm-Plan -Title 'Red y NSG' -Lines $plan -Force:$Force

# --- 3. NSG ------------------------------------------------------------------
Write-Section 'NSG'
foreach ($sn in $Cfg.NsgNames.Keys) {
    if ($nsgs[$sn]) { continue }
    $n = $Cfg.NsgNames[$sn]
    $rules = @(foreach ($r in $Cfg.NsgRules[$sn]) {
        $src = if ($r.Dir -eq 'Inbound') { $r.Addr } else { '*' }
        $dst = if ($r.Dir -eq 'Inbound') { '*' } else { $r.Addr }
        New-AzNetworkSecurityRuleConfig -Name $r.Name -Description "$($r.Access) $($r.Dir) $($r.Ports -join ',') ($($r.Addr))" `
            -Access $r.Access -Protocol $r.Proto -Direction $r.Dir -Priority $r.Priority `
            -SourceAddressPrefix $src -SourcePortRange '*' -DestinationAddressPrefix $dst -DestinationPortRange $r.Ports
    })
    $nsgs[$sn] = New-AzNetworkSecurityGroup -Name $n -ResourceGroupName $rg -Location $loc -SecurityRules $rules -Tag $Cfg.Tags
    Write-Host "NSG $n creado con $($rules.Count) reglas." -ForegroundColor Green
}

# --- 4. VNet y subredes ------------------------------------------------------
Write-Section 'VNet y subredes'
if (-not $vnet) {
    $cfgs = @(foreach ($k in $names) {
        $p = @{ Name = $k; AddressPrefix = $subnets[$k] }
        if ($nsgs.ContainsKey($k)) { $p.NetworkSecurityGroup = $nsgs[$k] }
        New-AzVirtualNetworkSubnetConfig @p
    })
    $vnet = New-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $rg -Location $loc -AddressPrefix $Cfg.VnetPrefix -Subnet $cfgs -Tag $Cfg.Tags
    Write-Host "VNet $($Cfg.VnetName) creada con $($cfgs.Count) subredes." -ForegroundColor Green
} else {
    $changed = $false
    foreach ($k in $names) {
        $sn = $vnet.Subnets | Where-Object Name -eq $k
        if (-not $sn) {
            $p = @{ VirtualNetwork = $vnet; Name = $k; AddressPrefix = $subnets[$k] }
            if ($nsgs.ContainsKey($k)) { $p.NetworkSecurityGroup = $nsgs[$k] }
            Add-AzVirtualNetworkSubnetConfig @p | Out-Null
            Write-Host "Subred $k agregada." -ForegroundColor Green; $changed = $true
        } elseif ($nsgs.ContainsKey($k) -and -not $sn.NetworkSecurityGroup) {
            $sn.NetworkSecurityGroup = $nsgs[$k]
            Write-Host "NSG $($Cfg.NsgNames[$k]) asociado a $k." -ForegroundColor Green; $changed = $true
        }
    }
    if ($changed) { $vnet = $vnet | Set-AzVirtualNetwork } else { Write-Host 'La VNet ya estaba completa; sin cambios.' -ForegroundColor Yellow }
}

# --- 5. Resultado ------------------------------------------------------------
Write-Section 'Resultado'
$vnet = Get-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $rg
$vnet.Subnets | ForEach-Object {
    $nsgName = if ($_.NetworkSecurityGroup) { (Split-ResourceId $_.NetworkSecurityGroup.Id).Name } else { '(sin NSG)' }
    Write-Host ('  {0,-20} {1,-16} {2}' -f $_.Name, ($_.AddressPrefix -join ','), $nsgName)
}
if (-not $SkipValidation) {
    Write-Host "`nEjecutando validacion..." -ForegroundColor Cyan
    & "$PSScriptRoot\01-Validar-Red-NSG.ps1"
} else { Write-Host "`nSiguiente paso: .\01-Validar-Red-NSG.ps1" -ForegroundColor Green }
