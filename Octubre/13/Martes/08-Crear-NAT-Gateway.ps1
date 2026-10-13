<#
.SYNOPSIS
    Crea un NAT Gateway con IP publica fija y lo asocia a las subredes que deben salir a Internet (snet-app y snet-db).
.DESCRIPTION
    Por que: la "salida predeterminada" de Azure (IP implicita que cambia y no controlas) se retira para VNets nuevas
    (nuevas subredes privadas por defecto). Un NAT Gateway da una IP de salida FIJA y propia: TeamViewer, TSplus y las
    actualizaciones salen por esa IP, que usted puede dar al proveedor de TSplus o usar en listas blancas.
    Es un cambio de subred sin reinicio de VMs (las conexiones salientes nuevas usan el NAT Gateway).
    Costo aproximado: tarifa por hora del recurso + IP publica + GB procesados (ver la calculadora de Azure).
#>
[CmdletBinding()]
param([switch]$Force)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network

$e   = $Cfg.Egress
$rg  = $Cfg.ResourceGroup
$loc = $Cfg.Location

$vnet = Get-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $rg
foreach ($k in $e.Subnets) { if (-not ($vnet.Subnets | Where-Object Name -eq $k)) { throw "No existe la subred $k." } }

Confirm-Plan -Title 'NAT Gateway (salida a Internet con IP fija)' -Force:$Force -Lines @(
    "NAT Gateway: $($e.NatGatewayName)  |  IP publica Standard estatica: $($e.NatPipName)  |  Inactividad: $($e.IdleTimeoutMin) min",
    "Subredes: $($e.Subnets -join ', ')",
    'Quedan sin efecto las IP de salida predeterminadas; la IP publica del NAT Gateway sera la IP de origen de TeamViewer/TSplus.'
)

$pip = Get-AzPublicIpAddress -Name $e.NatPipName -ResourceGroupName $rg -ErrorAction SilentlyContinue
if (-not $pip) {
    $pip = New-AzPublicIpAddress -Name $e.NatPipName -ResourceGroupName $rg -Location $loc -Sku Standard -Tier Regional -AllocationMethod Static -Tag $Cfg.Tags
    Write-Host "IP publica $($e.NatPipName) creada: $($pip.IpAddress)" -ForegroundColor Green
}
$nat = Get-AzNatGateway -Name $e.NatGatewayName -ResourceGroupName $rg -ErrorAction SilentlyContinue
if (-not $nat) {
    $nat = New-AzNatGateway -Name $e.NatGatewayName -ResourceGroupName $rg -Location $loc -Sku Standard -IdleTimeoutInMinutes $e.IdleTimeoutMin -PublicIpAddress $pip -Tag $Cfg.Tags
    Write-Host "NAT Gateway $($e.NatGatewayName) creado." -ForegroundColor Green
} else { Write-Host "NAT Gateway $($e.NatGatewayName) ya existe." -ForegroundColor Yellow }

$changed = $false
foreach ($k in $e.Subnets) {
    $sn = $vnet.Subnets | Where-Object Name -eq $k
    if ($sn.NatGateway -and $sn.NatGateway.Id -like "*$($e.NatGatewayName)") { Write-Host "Subred $k ya usa el NAT Gateway." -ForegroundColor Yellow; continue }
    $sn.NatGateway = $nat
    $changed = $true
    Write-Host "Subred $k -> NAT Gateway asociado." -ForegroundColor Green
}
if ($changed) { $vnet | Set-AzVirtualNetwork | Out-Null }

$pip = Get-AzPublicIpAddress -Name $e.NatPipName -ResourceGroupName $rg
Write-Host "`nIP publica de SALIDA de la VM App y la BD: $($pip.IpAddress)" -ForegroundColor Cyan
Write-Host 'Prueba desde la VM (PowerShell): (Invoke-RestMethod https://api.ipify.org)  -> debe mostrar esa IP.' -ForegroundColor Gray
