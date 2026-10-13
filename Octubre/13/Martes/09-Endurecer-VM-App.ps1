<#
.SYNOPSIS
    Endurece la VM App por dentro (Windows Defender, firewall de Windows, NLA, bloqueo de cuentas, auditoria)
    y, opcionalmente, habilita Microsoft Defender para Servers en la suscripcion.
.DESCRIPTION
    Se ejecuta DESDE Azure (Run Command), no hace falta entrar por Bastion. Cada cambio es reversible y se informa en pantalla.
    Todo es opcional mediante parametros; sin parametros solo aplica lo "seguro":
      - Defender: tiempo real ON, proteccion en la nube (MAPS) avanzada, bloqueo de aplicaciones potencialmente no deseadas (PUA),
        proteccion de red, actualizacion de firmas.
      - Firewall de Windows activo en los 3 perfiles.
      - RDP con NLA obligatorio; SMBv1 deshabilitado.
      - Bloqueo de cuenta: 5 intentos fallidos -> 30 min. Registro de seguridad ampliado a 1 GB y auditoria de inicios de sesion.
.PARAMETER VmName
    Por defecto $Cfg.VmApp.Name.
.PARAMETER RestrictRdpToBastion
    Limita el RDP de Windows Firewall a la subred de Bastion. NO usar si los usuarios entran por RDP directo (ej. TSplus Desktop edition).
.PARAMETER EnableDefenderForServers
    Habilita Microsoft Defender para Servers Plan 1 en la SUSCRIPCION (afecta a todas sus VMs; tiene costo por servidor/mes: verifique el precio vigente).
.PARAMETER AddTsplusExclusions
    Agrega a Defender las exclusiones que documenta TSplus (solo si TSplus da falsos positivos; por defecto NO se excluye nada).
#>
[CmdletBinding()]
param(
    [string]$VmName,
    [switch]$RestrictRdpToBastion,
    [switch]$EnableDefenderForServers,
    [switch]$AddTsplusExclusions,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Compute
if (-not $VmName) { $VmName = $Cfg.VmApp.Name }
$rg = $Cfg.ResourceGroup

$vm = Get-AzVM -Name $VmName -ResourceGroupName $rg -Status -ErrorAction SilentlyContinue
if (-not $vm) { throw "No existe la VM '$VmName'." }
if (($vm.Statuses | Where-Object Code -like 'PowerState/*').Code -ne 'PowerState/running') { throw "La VM $VmName debe estar encendida." }

Confirm-Plan -Title "Endurecer $VmName" -Force:$Force -Lines @(
    'Defender: tiempo real, nube avanzada, PUA, proteccion de red, firmas',
    'Firewall de Windows ON; NLA para RDP; SMBv1 OFF; bloqueo de cuenta 5/30 min; auditoria de inicios de sesion; registro Security 1 GB',
    "RDP solo desde Bastion ($($Cfg.Subnets['AzureBastionSubnet'])): $(if ($RestrictRdpToBastion) { 'SI' } else { 'no' })",
    "Exclusiones de TSplus en Defender: $(if ($AddTsplusExclusions) { 'SI' } else { 'no' })",
    "Defender para Servers P1 en la suscripcion: $(if ($EnableDefenderForServers) { 'SI' } else { 'no' })"
)

$bastion = $Cfg.Subnets['AzureBastionSubnet']
$script = @"
`$ErrorActionPreference = 'Continue'
`$restrictRdp = `$$([bool]$RestrictRdpToBastion)
`$tsplusExcl  = `$$([bool]$AddTsplusExclusions)
function Say(`$m) { Write-Output `$m }

# --- Defender ---
Set-MpPreference -DisableRealtimeMonitoring `$false -MAPSReporting Advanced -SubmitSamplesConsent SendSafeSamples ``
    -PUAProtection Enabled -EnableNetworkProtection Enabled -CloudBlockLevel High -CloudExtendedTimeout 20
try { Update-MpSignature -ErrorAction Stop; Say 'Firmas de Defender actualizadas' } catch { Say ('Firmas: ' + `$_.Exception.Message) }
if (`$tsplusExcl) {
    foreach (`$p in 'C:\Program Files (x86)\TSplus','C:\wsession') { if (Test-Path `$p) { Add-MpPreference -ExclusionPath `$p; Say "Exclusion: `$p" } }
}
`$mp = Get-MpComputerStatus
Say ('Defender: AMService={0} RealTime={1} Firmas={2} Tamper={3}' -f `$mp.AMServiceEnabled, `$mp.RealTimeProtectionEnabled, `$mp.AntivirusSignatureLastUpdated, `$mp.IsTamperProtected)

# --- Firewall de Windows ---
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
Say 'Firewall de Windows habilitado (Domain/Public/Private)'
if (`$restrictRdp) {
    Get-NetFirewallRule -DisplayGroup 'Remote Desktop','Escritorio remoto' -ErrorAction SilentlyContinue | Where-Object Direction -eq Inbound |
        Set-NetFirewallRule -RemoteAddress '$bastion'
    Say 'RDP restringido a $bastion'
}

# --- RDP / SMB / cuentas / auditoria ---
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
Say 'NLA obligatorio para RDP'
Set-SmbServerConfiguration -EnableSMB1Protocol `$false -Force
Say 'SMBv1 deshabilitado'
net accounts /lockoutthreshold:5 /lockoutduration:30 /lockoutwindow:30 | Out-Null
Say 'Bloqueo de cuenta: 5 intentos / 30 min'
auditpol /set /subcategory:"Logon" /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Logoff" /success:enable | Out-Null
auditpol /set /subcategory:"Account Lockout" /failure:enable | Out-Null
wevtutil sl Security /ms:1073741824
Say 'Auditoria de inicio de sesion activada; registro Security 1 GB'
"@

Write-Host "Aplicando en $VmName (1-2 min)..." -ForegroundColor Cyan
Invoke-VmScript -VmName $VmName -Script $script | Write-Host

if ($EnableDefenderForServers) {
    Install-Module Az.Security -Scope CurrentUser -Force -ErrorAction SilentlyContinue
    Import-Module Az.Security -ErrorAction Stop
    Set-AzSecurityPricing -Name 'VirtualMachines' -PricingTier 'Standard' -SubPlan 'P1' | Out-Null
    Write-Host 'Microsoft Defender para Servers (Plan 1) habilitado en la suscripcion.' -ForegroundColor Green
}
Write-Host "`nListo. Revise SEGURIDAD-VM-App.md para el resto de recomendaciones (cuenta admin, TeamViewer, TSplus, respaldos)." -ForegroundColor Green
