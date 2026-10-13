<#
.SYNOPSIS
    Configura Log Analytics, Azure Monitor (agente, reglas de recoleccion, alertas) y logs de diagnostico.
.DESCRIPTION
    1. Workspace de Log Analytics (PerGB2018, retencion 30 dias, tope diario 10 GB segun CSV).
    2. Grupo de acciones con correo de notificacion.
    3. Regla de recoleccion de datos (DCR): contadores de rendimiento + eventos de Windows (errores/advertencias).
    4. En cada VM: identidad administrada, extension Azure Monitor Agent y asociacion a la DCR.
    5. Alertas por VM: disponibilidad (sev 1) y CPU > 85 % (sev 2).
    6. Logs de diagnostico hacia el workspace para Application Gateway (acceso/rendimiento/WAF), Bastion y los NSG.
    Es seguro re-ejecutarlo (por ejemplo, despues de crear el Application Gateway o Bastion).
#>
[CmdletBinding()]
param(
    [string]$AlertEmail,
    [switch]$Force
)

. "$PSScriptRoot\00-Config.ps1"
Initialize-AzSession -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute, Az.OperationalInsights

$m   = $Cfg.Monitor
$rg  = $Cfg.ResourceGroup
$loc = $Cfg.Location
$rgp = Get-RgPath
if ($AlertEmail) { $m.AlertEmail = $AlertEmail }
if ($m.AlertEmail -like '*@contoso.com') { Write-Warning "El correo de alertas es el de ejemplo ($($m.AlertEmail)). Use -AlertEmail o edite 00-Config.ps1." }

Confirm-Plan -Title 'Monitoreo y logs' -Force:$Force -Lines @(
    "Workspace: $($m.WorkspaceName) (PerGB2018, retencion $($m.RetentionDays) dias, tope $($m.DailyQuotaGb) GB/dia)",
    "Grupo de acciones: $($m.ActionGroup) -> $($m.AlertEmail)",
    "DCR: $($m.DcrName) (rendimiento + eventos Windows)",
    "VMs: $($Cfg.VmApp.Name), $($Cfg.VmDb.Name) (agente AMA + alertas de disponibilidad y CPU > 85%)",
    'Diagnosticos: Application Gateway, Bastion y NSG (los que existan)'
)

# --- 1. Log Analytics --------------------------------------------------------
Write-Section 'Log Analytics'
$law = Get-AzOperationalInsightsWorkspace -ResourceGroupName $rg -Name $m.WorkspaceName -ErrorAction SilentlyContinue
if (-not $law) {
    $law = New-AzOperationalInsightsWorkspace -ResourceGroupName $rg -Name $m.WorkspaceName -Location $loc -Sku 'pergb2018' -RetentionInDays $m.RetentionDays -Tag $Cfg.Tags
    Write-Host "Workspace $($m.WorkspaceName) creado." -ForegroundColor Green
} else { Write-Host "Workspace $($m.WorkspaceName) ya existe." -ForegroundColor Yellow }
Invoke-ArmRest -Method PATCH -Path "$rgp/providers/Microsoft.OperationalInsights/workspaces/$($m.WorkspaceName)?api-version=2023-09-01" -Body @{ properties = @{ workspaceCapping = @{ dailyQuotaGb = $m.DailyQuotaGb } } } | Out-Null
Write-Host "Tope diario de ingesta: $($m.DailyQuotaGb) GB/dia" -ForegroundColor Green

# --- 2. Grupo de acciones ----------------------------------------------------
Write-Section 'Grupo de acciones'
$ag = Invoke-ArmRest -Method PUT -Path "$rgp/providers/Microsoft.Insights/actionGroups/$($m.ActionGroup)?api-version=2023-01-01" -Body @{
    location   = 'Global'
    tags       = $Cfg.Tags
    properties = @{
        groupShortName = $m.ActionShort
        enabled        = $true
        emailReceivers = @(@{ name = 'AdminTI'; emailAddress = $m.AlertEmail; useCommonAlertSchema = $true })
    }
}
$agId = $ag.id
Write-Host "Grupo de acciones listo: $($m.ActionGroup) -> $($m.AlertEmail)" -ForegroundColor Green

# --- 3. Regla de recoleccion de datos (DCR) ---------------------------------
Write-Section 'Regla de recoleccion de datos (DCR)'
$dcr = Invoke-ArmRest -Method PUT -Path "$rgp/providers/Microsoft.Insights/dataCollectionRules/$($m.DcrName)?api-version=2022-06-01" -Body @{
    location   = $loc
    kind       = 'Windows'
    tags       = $Cfg.Tags
    properties = @{
        dataSources = @{
            performanceCounters = @(@{
                name = 'perfCounters60s'; streams = @('Microsoft-Perf'); samplingFrequencyInSeconds = 60
                counterSpecifiers = @(
                    '\Processor Information(_Total)\% Processor Time',
                    '\Memory\Available MBytes',
                    '\Memory\% Committed Bytes In Use',
                    '\LogicalDisk(_Total)\% Free Space',
                    '\LogicalDisk(_Total)\Avg. Disk sec/Read',
                    '\LogicalDisk(_Total)\Avg. Disk sec/Write',
                    '\Network Interface(*)\Bytes Total/sec'
                )
            })
            windowsEventLogs = @(@{
                name = 'eventLogsErrWarn'; streams = @('Microsoft-Event')
                xPathQueries = @('Application!*[System[(Level=1 or Level=2 or Level=3)]]', 'System!*[System[(Level=1 or Level=2 or Level=3)]]')
            })
        }
        destinations = @{ logAnalytics = @(@{ name = 'lawDest'; workspaceResourceId = $law.ResourceId }) }
        dataFlows    = @(@{ streams = @('Microsoft-Perf', 'Microsoft-Event'); destinations = @('lawDest') })
    }
}
Write-Host "DCR lista: $($m.DcrName)" -ForegroundColor Green

# --- 4 y 5. Agente, asociacion y alertas por VM -----------------------------
foreach ($v in @($Cfg.VmApp, $Cfg.VmDb)) {
    Write-Section "VM $($v.Name)"
    $vm = Get-AzVM -Name $v.Name -ResourceGroupName $rg -Status -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Warning "La VM $($v.Name) no existe; se omite."; continue }
    $vmFull = Get-AzVM -Name $v.Name -ResourceGroupName $rg
    $power = ($vm.Statuses | Where-Object Code -like 'PowerState/*').DisplayStatus
    if ($power -ne 'VM running') { Write-Warning "La VM esta '$power'. Inicie la VM y vuelva a ejecutar este script para instalar el agente."; continue }

    if ("$($vmFull.Identity.Type)" -notmatch 'SystemAssigned') {
        Write-Host 'Habilitando identidad administrada (requerida por AMA)...' -ForegroundColor Cyan
        Update-AzVM -ResourceGroupName $rg -VM $vmFull -IdentityType SystemAssigned | Out-Null
    }
    $ext = Get-AzVMExtension -ResourceGroupName $rg -VMName $v.Name -Name 'AzureMonitorWindowsAgent' -ErrorAction SilentlyContinue
    if (-not $ext) {
        Write-Host 'Instalando Azure Monitor Agent...' -ForegroundColor Cyan
        Set-AzVMExtension -ResourceGroupName $rg -VMName $v.Name -Location $loc -Name 'AzureMonitorWindowsAgent' `
            -Publisher 'Microsoft.Azure.Monitor' -ExtensionType 'AzureMonitorWindowsAgent' -TypeHandlerVersion '1.0' -EnableAutomaticUpgrade $true | Out-Null
    } else { Write-Host 'Azure Monitor Agent ya instalado.' -ForegroundColor Yellow }

    Invoke-ArmRest -Method PUT -Path "$($vmFull.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcra-$($v.Name)?api-version=2022-06-01" -Body @{
        properties = @{ dataCollectionRuleId = $dcr.id }
    } | Out-Null
    Write-Host "VM asociada a la DCR $($m.DcrName)." -ForegroundColor Green

    $alerts = @(
        @{ Suffix = 'availability'; Metric = 'VmAvailabilityMetric'; Op = 'LessThan';    Threshold = 1;  Sev = 1; Desc = 'La VM no responde / esta apagada' },
        @{ Suffix = 'cpu';          Metric = 'Percentage CPU';       Op = 'GreaterThan'; Threshold = 85; Sev = 2; Desc = 'CPU promedio > 85 % durante 15 minutos' }
    )
    foreach ($al in $alerts) {
        $alertName = "$($Cfg.Prefix)-alert-$($v.Name)-$($al.Suffix)"
        try {
            Invoke-ArmRest -Method PUT -Path "$rgp/providers/Microsoft.Insights/metricAlerts/$alertName?api-version=2018-03-01" -Body @{
                location   = 'global'
                tags       = $Cfg.Tags
                properties = @{
                    description = $al.Desc; severity = $al.Sev; enabled = $true
                    scopes = @($vmFull.Id); evaluationFrequency = 'PT5M'; windowSize = 'PT15M'
                    criteria = @{
                        'odata.type' = 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
                        allOf = @(@{ name = 'Metric1'; metricName = $al.Metric; metricNamespace = 'Microsoft.Compute/virtualMachines'
                                     operator = $al.Op; threshold = $al.Threshold; timeAggregation = 'Average'; criterionType = 'StaticThresholdCriterion' })
                    }
                    actions = @(@{ actionGroupId = $agId })
                }
            } | Out-Null
            Write-Host "Alerta creada: $alertName" -ForegroundColor Green
        } catch { Write-Warning "No se pudo crear la alerta $alertName : $($_.Exception.Message)" }
    }
}

# --- 6. Logs de diagnostico --------------------------------------------------
Write-Section 'Logs de diagnostico hacia Log Analytics'
function Set-DiagToLaw {
    param([string]$Label, [string]$ResourceId, [string[]]$LogCategories, [bool]$Metrics = $true)
    $props = @{ workspaceId = $law.ResourceId; logs = @($LogCategories | ForEach-Object { @{ category = $_; enabled = $true } }) }
    if ($Metrics) { $props.metrics = @(@{ category = 'AllMetrics'; enabled = $true }) }
    try {
        Invoke-ArmRest -Method PUT -Path "$ResourceId/providers/Microsoft.Insights/diagnosticSettings/diag-to-law?api-version=2021-05-01-preview" -Body @{ properties = $props } | Out-Null
        Write-Host "Diagnosticos activados: $Label" -ForegroundColor Green
    } catch { Write-Warning "No se pudieron activar los diagnosticos de $Label : $($_.Exception.Message)" }
}
$agw = Get-AzApplicationGateway -Name $Cfg.AppGw.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
if ($agw) { Set-DiagToLaw -Label $Cfg.AppGw.Name -ResourceId $agw.Id -LogCategories 'ApplicationGatewayAccessLog', 'ApplicationGatewayPerformanceLog', 'ApplicationGatewayFirewallLog' }
else { Write-Host "Application Gateway aun no existe (ejecute este script de nuevo despues de 04)." -ForegroundColor Gray }
$bas = Get-AzBastion -Name $Cfg.Bastion.Name -ResourceGroupName $rg -ErrorAction SilentlyContinue
if ($bas) { Set-DiagToLaw -Label $Cfg.Bastion.Name -ResourceId $bas.Id -LogCategories 'BastionAuditLogs' }
else { Write-Host "Bastion aun no existe (ejecute este script de nuevo despues de 05)." -ForegroundColor Gray }
foreach ($nsg in (Get-AzNetworkSecurityGroup -ResourceGroupName $rg)) {
    Set-DiagToLaw -Label $nsg.Name -ResourceId $nsg.Id -LogCategories 'NetworkSecurityGroupEvent', 'NetworkSecurityGroupRuleCounter' -Metrics $false
}

Write-Host "`nListo. Los primeros datos tardan 5-10 minutos en aparecer en Log Analytics." -ForegroundColor Green
Write-Host 'Consulta de prueba (Portal > Log Analytics > Logs):  Heartbeat | summarize max(TimeGenerated) by Computer' -ForegroundColor Gray
Write-Host 'Siguiente paso: .\07-Configurar-Backup.ps1  y luego  .\99-Validar-Todo.ps1' -ForegroundColor Green
