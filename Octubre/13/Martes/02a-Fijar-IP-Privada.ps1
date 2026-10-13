<#
.SYNOPSIS
    Fija (estatica) la IP privada de una VM YA creada, por defecto la VM App -> 10.10.10.4.
.DESCRIPTION
    Verifica que la IP pertenezca a la subred, que no sea una de las 5 reservadas por Azure y que este libre
    (Test-AzPrivateIPAddressAvailability). Cambiar la IP reinicia la red de la VM: se corta unos segundos la sesion RDP/Bastion.
    No hace falta apagar la VM.
.PARAMETER VmName
    Nombre de la VM en Azure (por defecto $Cfg.VmApp.Name; si en su entorno se llama SAGO-VM-App, indiquelo aqui o cambie 00-Config.ps1).
.PARAMETER IpAddress
    IP deseada (por defecto $Cfg.VmApp.PrivateIp).
#>
[CmdletBinding()]
param(
    [string]$VmName,
    [string]$IpAddress,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

if (-not $VmName)    { $VmName    = $Cfg.VmApp.Name }
if (-not $IpAddress) { $IpAddress = $Cfg.VmApp.PrivateIp }
$rg = $Cfg.ResourceGroup

$vm = Get-AzVM -Name $VmName -ResourceGroupName $rg -ErrorAction SilentlyContinue
if (-not $vm) { throw "No existe la VM '$VmName' en el Resource Group '$rg'. Use -VmName con el nombre exacto." }
$info = Get-VmSubnetName -Vm $vm
$nic  = $info.Nic
$ic   = $nic.IpConfigurations[0]

$vnet = Get-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $rg
$sn   = $vnet.Subnets | Where-Object Name -eq $info.Subnet
$prefix = @($sn.AddressPrefix)[0]

if ($ic.PrivateIpAddress -eq $IpAddress -and $ic.PrivateIpAllocationMethod -eq 'Static') {
    Write-Host "La VM $VmName ya tiene la IP fija $IpAddress. Nada que hacer." -ForegroundColor Green; return
}

# La IP debe estar dentro de la subred (se usa la comprobacion de disponibilidad de Azure, que tambien detecta las reservadas)
$avail = Test-AzPrivateIPAddressAvailability -VirtualNetwork $vnet -IPAddress $IpAddress
if ($ic.PrivateIpAddress -ne $IpAddress -and -not $avail.Available) {
    throw "La IP $IpAddress no esta disponible en $($Cfg.VnetName) ($($avail.AvailableIPAddresses -join ', ') sugeridas). Subred $($info.Subnet): $prefix"
}

Confirm-Plan -Title "Fijar IP privada de $VmName" -Force:$Force -Lines @(
    "Subred: $($info.Subnet) ($prefix)",
    "IP actual: $($ic.PrivateIpAddress) ($($ic.PrivateIpAllocationMethod))  ->  nueva: $IpAddress (Static)",
    'La red de la VM se reconfigura: la sesion RDP/Bastion puede cortarse unos segundos.',
    'Si cambia de IP, actualice el backend del Application Gateway (04) y cualquier cadena de conexion que use la IP anterior.'
)

$ic.PrivateIpAllocationMethod = 'Static'
$ic.PrivateIpAddress = $IpAddress
$nic | Set-AzNetworkInterface | Out-Null

$nic = Get-AzNetworkInterface -Name $nic.Name -ResourceGroupName $nic.ResourceGroupName
Write-Host "NIC $($nic.Name): $($nic.IpConfigurations[0].PrivateIpAddress) ($($nic.IpConfigurations[0].PrivateIpAllocationMethod))" -ForegroundColor Green
Write-Host 'Dentro de Windows la IP sigue en DHCP (correcto en Azure): NO la configure manualmente en el adaptador de red.' -ForegroundColor Gray
