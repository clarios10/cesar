<#
.SYNOPSIS
    Crea Azure Bastion (SKU Basic) con su IP publica Standard dedicada.
.DESCRIPTION
    Requiere la subred AzureBastionSubnet (/26 o mayor). SKU Basic segun la hoja de costos (CSV).
    Basic no soporta "native client"/tunel ni escalado de instancias; para eso se necesita Standard.
#>
[CmdletBinding()]
param([switch]$Force)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network

$b   = $Cfg.Bastion
$rg  = $Cfg.ResourceGroup
$loc = $Cfg.Location

$existing = Get-AzBastion -Name $b.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Azure Bastion '$($b.Name)' YA existe (SKU $($existing.Sku.Name), estado $($existing.ProvisioningState)). No se modifica." -ForegroundColor Yellow
    return
}

$vnet = Get-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $rg
$sn   = $vnet.Subnets | Where-Object Name -eq 'AzureBastionSubnet'
if (-not $sn) { throw "No existe la subred 'AzureBastionSubnet' en $($Cfg.VnetName). Crearla con prefijo $($Cfg.Subnets['AzureBastionSubnet'])." }
$len = [int](($sn.AddressPrefix[0] -split '/')[1])
if ($len -gt 26) { throw "AzureBastionSubnet debe ser /26 o mayor (actual /$len)." }

Confirm-Plan -Title "Se creara Azure Bastion $($b.Name)" -Force:$Force -Lines @(
    "Region: $loc   |   SKU: $($b.Sku)   |   Subred: AzureBastionSubnet ($($sn.AddressPrefix))",
    "IP publica: $($b.PipName) (Standard, estatica)"
)

$pip = Get-AzPublicIpAddress -Name $b.PipName -ResourceGroupName $rg -ErrorAction SilentlyContinue
if (-not $pip) {
    Write-Host "Creando IP publica $($b.PipName) ..." -ForegroundColor Cyan
    $pip = New-AzPublicIpAddress -Name $b.PipName -ResourceGroupName $rg -Location $loc -Sku Standard -Tier Regional -AllocationMethod Static -Tag $Cfg.Tags
}

Write-Host "Creando Azure Bastion $($b.Name) (10-15 minutos)..." -ForegroundColor Cyan
New-AzBastion -Name $b.Name -ResourceGroupName $rg -PublicIpAddress $pip -VirtualNetwork $vnet -Sku $b.Sku -Tag $Cfg.Tags | Out-Null

Write-Host "`nAzure Bastion creado. Para conectarse: Portal > VM > Conectar > Bastion (RDP, usuario/contrasena de administrador)." -ForegroundColor Green
Write-Host 'Siguiente paso: .\06-Configurar-Monitoreo-Logs.ps1' -ForegroundColor Green
