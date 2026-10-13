<#
.SYNOPSIS
    Crea la VM del Servidor de Base de Datos: Windows Server 2025 + SQL Server Standard (PAYG), Standard_D8as_v5.
.DESCRIPTION
    - Usa la imagen de Marketplace de Microsoft "SQL Server <version> on Windows Server 2025", edicion Standard
      (sku standard-gen2). Esa imagen YA incluye Windows Server y SQL Server con licencia incluida (PAYG): no hay
      que agregar nada aparte. Windows viene como Datacenter (Azure no ofrece Standard; el precio es el mismo).
    - Busca automaticamente la oferta disponible en su region (sql2025-ws2025, y si no sql2022-ws2025).
    - Inicializa los discos (F: datos 2 TB, G: logs 512 GB), crea F:\SQLData y G:\SQLLog, abre el puerto 1433
      en Windows Firewall solo para la subred de aplicacion y registra la VM en el proveedor SQL IaaS (Full)
      con parches automaticos los domingos 02:00.
    - Si la VM ya existe, no la modifica.
.PARAMETER AdminCredential
    Administrador local (se pide por pantalla si se omite).
.PARAMETER UseAzureHybridBenefit
    Windows Server con Azure Hybrid Benefit (licencia propia con Software Assurance). Para SQL se mantiene PAYG
    salvo que cambie $Cfg.VmDb.SqlLicense a 'AHUB'.
#>
[CmdletBinding()]
param(
    [pscredential]$AdminCredential,
    [switch]$UseAzureHybridBenefit,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

$vmCfg = $Cfg.VmDb
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

Write-Host 'Buscando la imagen de SQL Server sobre Windows Server 2025 disponible en la region...' -ForegroundColor Gray
$img = $null
foreach ($offer in $vmCfg.SqlOffers) {
    $img = Get-LatestImage -Publisher $vmCfg.SqlPublisher -Offer $offer -Sku $vmCfg.SqlSku
    if ($img) { break }
}
if (-not $img) {
    $avail = Get-AzVMImageOffer -Location $loc -PublisherName $vmCfg.SqlPublisher | Where-Object Offer -like '*ws2025*' | ForEach-Object Offer
    throw ("No hay imagen SQL Standard sobre Windows Server 2025 en $loc con las ofertas configuradas ($($vmCfg.SqlOffers -join ', ')). " +
           "Ofertas ws2025 disponibles: $(if ($avail) { $avail -join ', ' } else { '(ninguna)' }). Ajuste `$Cfg.VmDb.SqlOffers en 00-Config.ps1.")
}

$cred = Get-AdminCredentialChecked -Credential $AdminCredential

$plan = @(
    "Region: $loc   |   Subred: $($vmCfg.Subnet) ($($subnet.AddressPrefix))",
    "Tamano: $($vmCfg.Size)",
    "Imagen: $($img.PublisherName):$($img.Offer):$($img.Skus):$($img.Version)  (Windows Server 2025 + SQL Server Standard)",
    "Licencia SQL: $($vmCfg.SqlLicense)   |   Licencia Windows: $(if ($UseAzureHybridBenefit) { 'Azure Hybrid Benefit' } else { 'incluida (pago por uso)' })",
    "Disco SO: $($vmCfg.OsDiskGB) GB Premium SSD LRS"
)
foreach ($d in $vmCfg.DataDisks) { $plan += "Disco de datos LUN $($d.Lun): $($d.SizeGB) GB Premium SSD LRS -> $($d.Letter): $($d.Label)" }
$plan += 'Sin IP publica; 1433 abierto solo desde snet-app'
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
$vm = New-AzVMConfig -VMName $vmCfg.Name -VMSize $vmCfg.Size -IdentityType SystemAssigned -Tags ($Cfg.Tags + @{ Rol = 'ServidorBaseDeDatos' })
$vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $vmCfg.ComputerName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate -PatchMode 'AutomaticByOS'
$vm = Set-AzVMSourceImage -VM $vm -PublisherName $img.PublisherName -Offer $img.Offer -Skus $img.Skus -Version $img.Version
if ($img.PurchasePlan) {
    # Algunas imagenes de Marketplace requieren plan/terminos; se aceptan automaticamente.
    $pp = $img.PurchasePlan
    $vm = Set-AzVMPlan -VM $vm -Name $pp.Name -Publisher $pp.Publisher -Product $pp.Product
    $terms = Get-AzMarketplaceTerms -Publisher $pp.Publisher -Product $pp.Product -Name $pp.Name
    if (-not $terms.Accepted) { Set-AzMarketplaceTerms -Publisher $pp.Publisher -Product $pp.Product -Name $pp.Name -Accept | Out-Null }
}
$vm = Set-AzVMOSDisk -VM $vm -Name "$($vmCfg.Name)-osdisk" -CreateOption FromImage -DiskSizeInGB $vmCfg.OsDiskGB -StorageAccountType Premium_LRS -Caching ReadWrite
foreach ($d in $vmCfg.DataDisks) {
    $vm = Add-AzVMDataDisk -VM $vm -Name ("{0}-datadisk-{1}" -f $vmCfg.Name, $d.Label.ToLower()) -Lun $d.Lun -CreateOption Empty -DiskSizeInGB $d.SizeGB -StorageAccountType Premium_LRS -Caching $d.Caching
}
$vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
$vm = Set-AzVMBootDiagnostic -VM $vm -Enable
if ($UseAzureHybridBenefit) { $vm.LicenseType = 'Windows_Server' }

# --- 5. Crear ---------------------------------------------------------------
Write-Host "Creando VM $($vmCfg.Name) (8-15 minutos)..." -ForegroundColor Cyan
New-AzVM -ResourceGroupName $rg -Location $loc -VM $vm | Out-Null

# --- 6. Discos + configuracion de SQL dentro de la VM -----------------------
Write-Host 'Inicializando discos de datos dentro de la VM...' -ForegroundColor Cyan
Invoke-VmScript -VmName $vmCfg.Name -Script (Get-DiskInitScript -Disks $vmCfg.DataDisks) | Write-Host

Write-Host 'Configurando rutas de SQL, permisos y firewall (1433 solo desde snet-app)...' -ForegroundColor Cyan
$sqlScript = @'
$ErrorActionPreference = 'Continue'
$data = '__DATA__'; $log = '__LOG__'
New-Item -ItemType Directory -Force -Path $data, $log | Out-Null
foreach ($p in $data, $log) { icacls $p /grant "NT SERVICE\MSSQLSERVER:(OI)(CI)F" | Out-Null }
if (-not (Get-NetFirewallRule -DisplayName 'SQL Server 1433 (snet-app)' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'SQL Server 1433 (snet-app)' -Direction Inbound -Protocol TCP -LocalPort 1433 -RemoteAddress '__APPNET__' -Action Allow | Out-Null
    Write-Output 'Regla de Windows Firewall 1433 creada (solo desde snet-app)'
}
$sqlcmd = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source
if ($sqlcmd) {
    $q = "EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultData', REG_SZ, N'$data'; EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultLog', REG_SZ, N'$log';"
    & $sqlcmd -S localhost -E -b -Q $q
    if ($LASTEXITCODE -eq 0) { Write-Output 'Rutas por defecto de SQL configuradas'; Restart-Service MSSQLSERVER -Force; Write-Output 'Servicio SQL reiniciado' }
    else { Write-Output 'ADVERTENCIA: no se pudieron fijar las rutas por defecto; configurelas en SSMS (Propiedades del servidor > Database settings)' }
} else { Write-Output 'ADVERTENCIA: sqlcmd no encontrado; configure las rutas por defecto en SSMS' }
'@
$sqlScript = $sqlScript.Replace('__DATA__', $vmCfg.SqlDataPath).Replace('__LOG__', $vmCfg.SqlLogPath).Replace('__APPNET__', $Cfg.Subnets[$Cfg.VmApp.Subnet])
Invoke-VmScript -VmName $vmCfg.Name -Script $sqlScript | Write-Host

# --- 7. Registro en el proveedor SQL IaaS (licencia PAYG, administracion Full) ---
Write-Host 'Verificando registro en el proveedor SQL IaaS...' -ForegroundColor Cyan
$sqlPath = "$(Get-RgPath)/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/$($vmCfg.Name)?api-version=2023-10-01"
$sqlVm = $null
for ($i = 1; $i -le 6 -and -not $sqlVm; $i++) {
    $sqlVm = Invoke-ArmRest -Method GET -Path $sqlPath -AllowNotFound
    if (-not $sqlVm) { Write-Host "  (esperando auto-registro $i/6)" -ForegroundColor Gray; Start-Sleep -Seconds 30 }
}
if (-not $sqlVm) {
    $vmId = (Get-AzVM -Name $vmCfg.Name -ResourceGroupName $rg).Id
    Invoke-ArmRest -Method PUT -Path $sqlPath -Body @{
        location   = $loc
        properties = @{ virtualMachineResourceId = $vmId; sqlServerLicenseType = $vmCfg.SqlLicense; sqlManagement = 'Full' }
    } | Out-Null
    Write-Host 'VM registrada manualmente en SQL IaaS (Full).' -ForegroundColor Green
} else {
    Write-Host "VM ya registrada: licencia $($sqlVm.properties.sqlServerLicenseType), administracion $($sqlVm.properties.sqlManagement)." -ForegroundColor Green
}
try {
    Invoke-ArmRest -Method PATCH -Path $sqlPath -Body @{ properties = @{ autoPatchingSettings = @{ enable = $true; dayOfWeek = 'Sunday'; maintenanceWindowStartingHour = 2; maintenanceWindowDuration = 60 } } } | Out-Null
    Write-Host 'Parches automaticos de SQL: domingos 02:00, ventana de 60 min.' -ForegroundColor Green
} catch { Write-Warning "No se pudo configurar el parchado automatico de SQL: $($_.Exception.Message)" }

$info = Get-VmSubnetName -Vm (Get-AzVM -Name $vmCfg.Name -ResourceGroupName $rg)
Write-Host "`nVM de base de datos creada. IP privada: $($info.PrivateIp)" -ForegroundColor Green
Write-Host 'Siguiente paso: .\04-Crear-AppGateway-WAF.ps1' -ForegroundColor Green
