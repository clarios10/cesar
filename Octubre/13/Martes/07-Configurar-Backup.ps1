<#
.SYNOPSIS
    Crea el Recovery Services Vault (LRS), la politica de backup diaria y protege las dos VMs.
.DESCRIPTION
    Politica: diario 05:00 UTC, retencion 30 dias + 12 semanas (domingos) + 12 meses (primer domingo).
    La redundancia (LRS segun CSV) solo puede cambiarse mientras el vault no tenga elementos protegidos.
.PARAMETER RunInitialBackup
    Dispara el primer respaldo de inmediato (en vez de esperar al horario programado).
#>
[CmdletBinding()]
param(
    [switch]$RunInitialBackup,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Compute, Az.RecoveryServices

$b   = $Cfg.Backup
$rg  = $Cfg.ResourceGroup
$loc = $Cfg.Location

Confirm-Plan -Title 'Backup de las VMs' -Force:$Force -Lines @(
    "Vault: $($b.VaultName)  |  Redundancia: $($b.Redundancy)",
    "Politica: $($b.PolicyName)  (diario $($b.TimeUtc) UTC; 30 dias / 12 semanas / 12 meses)",
    "VMs a proteger: $($Cfg.VmApp.Name), $($Cfg.VmDb.Name)"
)

# --- Vault -------------------------------------------------------------------
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $rg -Name $b.VaultName -ErrorAction SilentlyContinue
if (-not $vault) {
    $vault = New-AzRecoveryServicesVault -Name $b.VaultName -ResourceGroupName $rg -Location $loc -Tag $Cfg.Tags
    Write-Host "Vault $($b.VaultName) creado." -ForegroundColor Green
} else { Write-Host "Vault $($b.VaultName) ya existe." -ForegroundColor Yellow }
try {
    Set-AzRecoveryServicesBackupProperty -Vault $vault -BackupStorageRedundancy $b.Redundancy | Out-Null
    Write-Host "Redundancia del vault: $($b.Redundancy)" -ForegroundColor Green
} catch { Write-Warning "No se pudo fijar la redundancia (probablemente ya hay elementos protegidos): $($_.Exception.Message)" }

# --- Politica ----------------------------------------------------------------
$policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $b.PolicyName -VaultId $vault.ID -ErrorAction SilentlyContinue
if (-not $policy) {
    $time = [datetime]::SpecifyKind([datetime]"2026-01-01 $($b.TimeUtc):00", [DateTimeKind]::Utc)

    $sch = Get-AzRecoveryServicesBackupSchedulePolicyObject -WorkloadType AzureVM
    $sch.ScheduleRunTimes.Clear()
    $sch.ScheduleRunTimes.Add($time)

    $ret = Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType AzureVM
    $ret.IsDailyScheduleEnabled   = $true
    $ret.DailySchedule.DurationCountInDays = 30
    $ret.IsWeeklyScheduleEnabled  = $true
    $ret.WeeklySchedule.DaysOfTheWeek = @('Sunday')
    $ret.WeeklySchedule.DurationCountInWeeks = 12
    $ret.IsMonthlyScheduleEnabled = $true
    $ret.MonthlySchedule.DurationCountInMonths = 12
    $ret.MonthlySchedule.RetentionScheduleFormatType = 'Weekly'
    $ret.MonthlySchedule.RetentionScheduleWeekly.DaysOfTheWeek = @('Sunday')
    $ret.MonthlySchedule.RetentionScheduleWeekly.WeeksOfTheMonth = @('First')
    $ret.IsYearlyScheduleEnabled  = $false
    foreach ($s in @($ret.DailySchedule, $ret.WeeklySchedule, $ret.MonthlySchedule)) { $s.RetentionTimes.Clear(); $s.RetentionTimes.Add($time) }

    $policy = New-AzRecoveryServicesBackupProtectionPolicy -Name $b.PolicyName -WorkloadType AzureVM -RetentionPolicy $ret -SchedulePolicy $sch -VaultId $vault.ID
    Write-Host "Politica $($b.PolicyName) creada." -ForegroundColor Green
} else { Write-Host "Politica $($b.PolicyName) ya existe." -ForegroundColor Yellow }

# --- Proteger VMs ------------------------------------------------------------
foreach ($v in @($Cfg.VmApp, $Cfg.VmDb)) {
    $vm = Get-AzVM -Name $v.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Warning "La VM $($v.Name) no existe; se omite."; continue }
    $item = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $vault.ID |
            Where-Object { $_.Name -like "*;$($v.Name)" } | Select-Object -First 1
    if ($item) {
        Write-Host "$($v.Name) ya esta protegida (estado: $($item.ProtectionStatus))." -ForegroundColor Yellow
    } else {
        Write-Host "Habilitando proteccion de $($v.Name) ..." -ForegroundColor Cyan
        Enable-AzRecoveryServicesBackupProtection -ResourceGroupName $rg -Name $v.Name -Policy $policy -VaultId $vault.ID | Out-Null
        Write-Host "$($v.Name) protegida con la politica $($b.PolicyName)." -ForegroundColor Green
        $item = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $vault.ID |
                Where-Object { $_.Name -like "*;$($v.Name)" } | Select-Object -First 1
    }
    if ($RunInitialBackup -and $item) {
        Backup-AzRecoveryServicesBackupItem -Item $item -VaultId $vault.ID | Out-Null
        Write-Host "Primer respaldo de $($v.Name) iniciado (seguimiento: Portal > vault > Trabajos de copia de seguridad)." -ForegroundColor Green
    }
}
Write-Host "`nSiguiente paso: .\99-Validar-Todo.ps1" -ForegroundColor Green
