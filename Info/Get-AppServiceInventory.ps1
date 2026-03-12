# ============================================================
#  Get-AppServiceInventory.ps1
#  Inventario completo de Azure App Services
#  Requiere: Az PowerShell module (Install-Module Az)
# ============================================================

param(
    [string[]]$SubscriptionIds,          # Dejar vacío = todas las suscripciones accesibles
    [string]$OutputPath = ".\AppService_Inventario_$(Get-Date -Format 'yyyyMMdd_HHmm').csv",
    [switch]$IncludeAppSettings,         # Incluir variables de entorno (puede ser sensible)
    [switch]$IncludeConnectionStrings,   # Incluir connection strings (puede ser sensible)
    [switch]$Verbose
)

# ─── Verificar módulo Az ────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Az.Websites)) {
    Write-Error "Módulo Az no encontrado. Instálalo con: Install-Module Az -Scope CurrentUser"
    exit 1
}

# ─── Login (omitir si ya hay sesión activa) ─────────────────
$context = Get-AzContext
if (-not $context) {
    Write-Host "Iniciando sesión en Azure..." -ForegroundColor Cyan
    Connect-AzAccount
}

# ─── Obtener suscripciones ──────────────────────────────────
if ($SubscriptionIds) {
    $subscriptions = $SubscriptionIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
} else {
    $subscriptions = Get-AzSubscription
}

Write-Host "Suscripciones a procesar: $($subscriptions.Count)" -ForegroundColor Cyan

$inventario = [System.Collections.Generic.List[PSObject]]::new()

foreach ($sub in $subscriptions) {

    Write-Host "`n→ Procesando suscripción: $($sub.Name) ($($sub.Id))" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $webApps = Get-AzWebApp -ErrorAction SilentlyContinue

    if (-not $webApps) {
        Write-Host "  Sin App Services encontrados." -ForegroundColor DarkGray
        continue
    }

    foreach ($app in $webApps) {

        Write-Host "  · $($app.Name)" -ForegroundColor Gray

        # Configuración detallada
        $config = Get-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name

        # Plan de App Service
        $planName = ($app.ServerFarmId -split "/")[-1]
        $plan = $null
        try {
            $plan = Get-AzAppServicePlan -ResourceGroupName $app.ResourceGroup -Name $planName -ErrorAction SilentlyContinue
        } catch {}

        # Custom domains
        $customDomains = ($config.HostNames | Where-Object { $_ -notlike "*.azurewebsites.net" }) -join "; "

        # Tags
        $tags = if ($app.Tags) {
            ($app.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; "
        } else { "" }

        # App Settings (opcional)
        $appSettingsStr = ""
        if ($IncludeAppSettings -and $config.SiteConfig.AppSettings) {
            $appSettingsStr = ($config.SiteConfig.AppSettings | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "; "
        }

        # Connection Strings (opcional)
        $connStrStr = ""
        if ($IncludeConnectionStrings -and $config.SiteConfig.ConnectionStrings) {
            $connStrStr = ($config.SiteConfig.ConnectionStrings | ForEach-Object { "$($_.Name)[$($_.Type)]" }) -join "; "
        }

        $row = [PSCustomObject]@{
            Suscripcion          = $sub.Name
            SuscripcionId        = $sub.Id
            GrupoRecursos        = $app.ResourceGroup
            Nombre               = $app.Name
            Tipo                 = $app.Kind                          # app, functionapp, app,linux, etc.
            Estado               = $app.State
            Region               = $app.Location
            URL                  = "https://$($app.DefaultHostName)"
            DominiosPersonalizados = $customDomains
            PlanNombre           = $planName
            PlanSKU              = if ($plan) { $plan.Sku.Name } else { "N/A" }
            PlanTier             = if ($plan) { $plan.Sku.Tier } else { "N/A" }
            PlanWorkers          = if ($plan) { $plan.Sku.Capacity } else { "N/A" }
            SistemaOperativo     = if ($app.Kind -like "*linux*") { "Linux" } else { "Windows" }
            RuntimeStack         = $config.SiteConfig.LinuxFxVersion + $config.SiteConfig.WindowsFxVersion
            NetFramework         = $config.SiteConfig.NetFrameworkVersion
            PHP                  = $config.SiteConfig.PhpVersion
            Python               = $config.SiteConfig.PythonVersion
            Node                 = $config.SiteConfig.NodeVersion
            Java                 = $config.SiteConfig.JavaVersion
            HTTPSObligatorio     = $config.HttpsOnly
            TLS_Version          = $config.SiteConfig.MinTlsVersion
            HTTP2                = $config.SiteConfig.Http20Enabled
            AlwaysOn             = $config.SiteConfig.AlwaysOn
            WebSockets           = $config.SiteConfig.WebSocketsEnabled
            Autoscaling          = if ($plan) { $plan.AutoscaleEnabled } else { $false }
            ManagedIdentity      = if ($config.Identity) { $config.Identity.Type } else { "None" }
            FechaCreacion        = $app.CreationTime
            Tags                 = $tags
            AppSettings          = $appSettingsStr
            ConnectionStrings    = $connStrStr
        }

        $inventario.Add($row)
    }
}

# ─── Exportar CSV ───────────────────────────────────────────
$inventario | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "`n✅ Inventario completado." -ForegroundColor Green
Write-Host "   Total de App Services: $($inventario.Count)" -ForegroundColor Green
Write-Host "   Archivo guardado en:   $OutputPath" -ForegroundColor Green

# ─── Resumen en consola ─────────────────────────────────────
Write-Host "`n─── Resumen por tipo ───────────────────────────────" -ForegroundColor Cyan
$inventario | Group-Object Tipo | Sort-Object Count -Descending |
    Format-Table -AutoSize @{L="Tipo";E={$_.Name}}, @{L="Cantidad";E={$_.Count}}

Write-Host "─── Resumen por estado ─────────────────────────────" -ForegroundColor Cyan
$inventario | Group-Object Estado | Sort-Object Count -Descending |
    Format-Table -AutoSize @{L="Estado";E={$_.Name}}, @{L="Cantidad";E={$_.Count}}

Write-Host "─── Resumen por Plan SKU ───────────────────────────" -ForegroundColor Cyan
$inventario | Group-Object PlanSKU | Sort-Object Count -Descending |
    Format-Table -AutoSize @{L="SKU";E={$_.Name}}, @{L="Cantidad";E={$_.Count}}

# Retornar objeto para uso en pipeline
return $inventario
