<#
.SYNOPSIS
    Crea la VM del Servidor de Aplicacion: Windows Server 2025, Standard_DC16ds_v3, discos Premium SSD, sin IP publica.
.DESCRIPTION
    - Azure NO publica una imagen "Windows Server 2025 Standard": todas son Datacenter. El precio de la VM con
      licencia incluida es el MISMO (la licencia va en la tarifa por hora y no cambia por edicion), asi que usar la
      imagen Datacenter no encarece la solucion. Si el cliente tiene licencias con Software Assurance use
      -UseAzureHybridBenefit para pagar solo el computo.
    - Si la VM ya existe, el script NO la modifica (es seguro volver a ejecutarlo).
.PARAMETER AdminCredential
    Usuario/contrasena del administrador local. Si se omite se solicitan por pantalla (no se guardan).
.PARAMETER UseAzureHybridBenefit
    Marca la VM con LicenseType 'Windows_Server' (requiere licencias Windows Server con Software Assurance).
.PARAMETER Force
    No pide confirmacion.
#>
[CmdletBinding()]
param(
    [pscredential]$AdminCredential,
    [switch]$UseAzureHybridBenefit,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

$vmCfg = $Cfg.VmApp
$rg    = $Cfg.ResourceGroup
$loc   = $Cfg.Location

# --- 1. Idempotencia ---------------------------------------------------------
$existing = Get-AzVM -Name $vmCfg.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "La VM '$($vmCfg.Name)' YA existe (tamano $($existing.HardwareProfile.VmSize)). No se modifica." -ForegroundColor Yellow
    Write-Host 'Ejecute .\99-Validar-Todo.ps1 para comparar su configuracion contra lo esperado.' -ForegroundColor Yellow
    return
}

# --- 2. Prerrequisitos -------------------------------------------------------
$vnet   = Get-AzVirtualNetwork -Name $Cfg.VnetName -ResourceGroupName $rg
$subnet = $vnet.Subnets | Where-Object Name -eq $vmCfg.Subnet
if (-not $subnet) { throw "No existe la subred '$($vmCfg.Subnet)' en la VNet '$($Cfg.VnetName)'." }

Write-Host 'Verificando tamano de VM, region y cuota (puede tardar ~30 s)...' -ForegroundColor Gray
Test-VmSkuAvailable -Size $vmCfg.Size

$img = Get-LatestImage -Publisher $vmCfg.Image.Publisher -Offer $vmCfg.Image.Offer -Sku $vmCfg.Image.Sku
if (-not $img) { throw "No se encontro la imagen $($vmCfg.Image.Publisher):$($vmCfg.Image.Offer):$($vmCfg.Image.Sku) en $loc. Liste las disponibles con: Get-AzVMImageSku -Location $loc -PublisherName MicrosoftWindowsServer -Offer WindowsServer | ? Skus -like '2025*'" }

$cred = Get-AdminCredentialChecked -Credential $AdminCredential

$plan = @(
    "Region: $loc   |   Subred: $($vmCfg.Subnet) ($($subnet.AddressPrefix))",
    "Tamano: $($vmCfg.Size)",
    "Imagen: $($img.PublisherName):$($img.Offer):$($img.Skus):$($img.Version)  (Windows Server 2025 Datacenter; Azure no ofrece Standard)",
    "Licencia Windows: $(if ($UseAzureHybridBenefit) { 'Azure Hybrid Benefit (licencia propia)' } else { 'Incluida en el precio por hora (pago por uso)' })",
    "IP privada: $(if ($vmCfg.PrivateIp) { "$($vmCfg.PrivateIp) (fija)" } else { 'dinamica' })",
    "Disco SO: $($vmCfg.OsDiskGB) GB Premium SSD LRS"
)
foreach ($d in $vmCfg.DataDisks) { $plan += "Disco de datos LUN $($d.Lun): $($d.SizeGB) GB Premium SSD LRS -> $($d.Letter): $($d.Label)" }
$plan += 'Sin IP publica (acceso por Application Gateway y Azure Bastion)'
Confirm-Plan -Title "Se creara la VM $($vmCfg.Name)" -Lines $plan -Force:$Force

# --- 3. NIC (sin IP publica) -------------------------------------------------
$nicName = "$($vmCfg.Name)-nic"
$nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $rg -ErrorAction SilentlyContinue
if (-not $nic) {
    Write-Host "Creando NIC $nicName ..." -ForegroundColor Cyan
    $nicArgs = @{ Name = $nicName; ResourceGroupName = $rg; Location = $loc; SubnetId = $subnet.Id; EnableAcceleratedNetworking = $true; Tag = $Cfg.Tags }
    if ($vmCfg.PrivateIp) { $nicArgs.PrivateIpAddress = $vmCfg.PrivateIp }   # IP privada fija
    $nic = New-AzNetworkInterface @nicArgs
}

# --- 4. Configuracion de la VM ----------------------------------------------
$vm = New-AzVMConfig -VMName $vmCfg.Name -VMSize $vmCfg.Size -IdentityType SystemAssigned -Tags ($Cfg.Tags + @{ Rol = 'ServidorAplicacion'; RequiereConfigPost = 'MSOffice+TerminalServices' })
$vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $vmCfg.ComputerName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate -PatchMode 'AutomaticByOS'
$vm = Set-AzVMSourceImage -VM $vm -PublisherName $img.PublisherName -Offer $img.Offer -Skus $img.Skus -Version $img.Version
$vm = Set-AzVMOSDisk -VM $vm -Name "$($vmCfg.Name)-osdisk" -CreateOption FromImage -DiskSizeInGB $vmCfg.OsDiskGB -StorageAccountType Premium_LRS -Caching ReadWrite
foreach ($d in $vmCfg.DataDisks) {
    $vm = Add-AzVMDataDisk -VM $vm -Name ("{0}-datadisk-{1}" -f $vmCfg.Name, $d.Label.ToLower()) -Lun $d.Lun -CreateOption Empty -DiskSizeInGB $d.SizeGB -StorageAccountType Premium_LRS -Caching $d.Caching
}
$vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
$vm = Set-AzVMBootDiagnostic -VM $vm -Enable
if ($UseAzureHybridBenefit) { $vm.LicenseType = 'Windows_Server' }

# --- 5. Crear ---------------------------------------------------------------
Write-Host "Creando VM $($vmCfg.Name) (5-10 minutos)..." -ForegroundColor Cyan
New-AzVM -ResourceGroupName $rg -Location $loc -VM $vm | Out-Null

# --- 6. Inicializar discos dentro de la VM ----------------------------------
Write-Host 'Inicializando y formateando los discos de datos dentro de la VM...' -ForegroundColor Cyan
Invoke-VmScript -VmName $vmCfg.Name -Script (Get-DiskInitScript -Disks $vmCfg.DataDisks) | Write-Host

$info = Get-VmSubnetName -Vm (Get-AzVM -Name $vmCfg.Name -ResourceGroupName $rg)
Write-Host "`nVM creada. IP privada: $($info.PrivateIp)" -ForegroundColor Green
Write-Host 'Siguiente paso: .\03-Crear-VM-DB-SQL.ps1  (despues, 04-Crear-AppGateway-WAF.ps1 usara esta IP privada como backend).' -ForegroundColor Green
Write-Host 'Pendiente fuera de estos scripts: instalar MS Office y Terminal Services/RDS en la VM.' -ForegroundColor Gray
