# Scripts PowerShell - Arquitectura de 3 Niveles en Azure

Complementan la *Guia de Actividades* (portal de Azure) y la hoja de costos `0_1-Info_Infra_01.csv`.

## Como usarlos

1. Lo mas facil: **Azure Cloud Shell (PowerShell)** en el portal (icono `>_`). Ya trae el modulo Az y la sesion iniciada.
   Suba la carpeta con el boton *Cargar/Descargar archivos* y descomprima: `Expand-Archive azure-scripts-3niveles.zip`.
   En una PC: `Install-Module Az -Scope CurrentUser` y luego `Connect-AzAccount`.
2. Edite **`00-Config.ps1`** (nombres, correo de alertas). Los valores por defecto siguen la guia.
3. Ejecute en este orden (cada script muestra un plan y pide confirmacion; `-Force` la omite):

| # | Script | Que hace | Tiempo aprox. |
|---|--------|----------|---------------|
| 0 | `01a-Crear-Red-NSG.ps1` | **Crea** los 3 NSG con sus reglas, la VNet, las 6 subredes y asocia cada NSG. Solo crea lo que falta; al final ejecuta la validacion | 2 min |
| 1 | `01-Validar-Red-NSG.ps1` | Valida VNet, 6 subredes, NSG asociados y sus reglas (solo lee) | 1 min |
| 2 | `02-Crear-VM-App.ps1` | VM Windows Server 2025, DC16ds_v3, discos 512 GB / 1 TB / 512 GB, sin IP publica, **IP privada fija 10.10.10.4** | 10 min |
| 3 | `03-Crear-VM-DB-SQL.ps1` | VM Windows Server 2025 + SQL Server Standard (PAYG), D8as_v5, discos 512 GB / 2 TB / 512 GB | 15 min |
| 4 | `04-Crear-AppGateway-WAF.ps1` | IP publica Standard + Application Gateway WAF_v2 (modo Prevention) | 25 min |
| 5 | `05-Crear-Bastion.ps1` | Azure Bastion Basic + IP publica | 15 min |
| 6 | `06-Configurar-Monitoreo-Logs.ps1` | Log Analytics (tope 10 GB/dia), agente, DCR, alertas, logs de diagnostico | 5 min |
| 7 | `07-Configurar-Backup.ps1` | Recovery Services Vault (LRS), politica diaria, proteccion de las 2 VMs | 5 min |
| 7b | `01b-Aplicar-Reglas-NSG.ps1` | **Agrega** a NSG existentes las reglas faltantes (salida TeamViewer/TSplus, KMS, bloqueo de salida). `-SkipDenyOutbound` = fase 1 | 1 min |
| 7c | `02a-Fijar-IP-Privada.ps1` | Fija la IP privada de una VM ya creada (por defecto la App: 10.10.10.4) | 1 min |
| 7d | `08-Crear-NAT-Gateway.ps1` | NAT Gateway + IP publica fija de salida para snet-app/snet-db | 3 min |
| 7e | `09-Endurecer-VM-App.ps1` | Defender, Firewall de Windows, NLA, bloqueo de cuenta, auditoria (+ Defender para Servidores opcional) | 3 min |
| 8 | `99-Validar-Todo.ps1` | Valida TODO y genera un CSV. `-Deep` revisa tambien dentro de las VMs | 3-5 min |

Si ya creo recursos en el portal, ejecute primero `01` y `99` (o `01a`, que completa lo que falte en red/NSG sin tocar lo existente): dicen que coincide con la guia y que no.
Los scripts **nunca modifican ni borran** recursos existentes: si una VM ya existe, la omiten. Para corregir una VM
creada con valores incorrectos (por ejemplo disco de SO de 127 GB), ajuste el recurso en el portal o elimine la VM y sus
discos/NIC y vuelva a ejecutar el script.

## Windows Server 2025 "Standard"

Azure no publica imagenes Standard: todas son *Datacenter*. El precio de una VM con licencia incluida **no cambia por
edicion**, asi que usar la imagen Datacenter no encarece la solucion. Si el cliente tiene licencias con Software Assurance,
use `-UseAzureHybridBenefit` en los scripts 02/03 para pagar solo el computo. La VM de BD usa la imagen de Microsoft
"SQL Server on Windows Server 2025" (edicion Standard): Windows y SQL ya vienen licenciados (PAYG).

## Puntos a tener presentes

- **WAF vs. CSV**: el CSV cotiza Application Gateway *Estandar V2*, que no incluye WAF. `WAF_v2` tiene tarifa fija por hora
  mayor. Si no se requiere WAF, cambie `AppGw.Tier` a `Standard_v2` en `00-Config.ps1`.
- **Certificado TLS**: sin `-PfxPath` el script crea un listener HTTP 80 temporal (para probar el WAF). Para el certificado
  de Key Vault, cambie el listener a HTTPS desde el portal (PowerShell no permite combinar identidad y politica WAF al crear).
- **Backend HTTPS**: si IIS usa un certificado autofirmado/interno, indique `-BackendRootCertPath` o el estado sera *Unhealthy*.
- **DC16ds_v3** es una serie de computo confidencial: el script verifica disponibilidad y cuota en su region antes de crear.
- **SQL**: el script busca la oferta `sql2025-ws2025` (o `sql2022-ws2025`) disponible; ajuste `VmDb.SqlOffers` si hace falta.
- Bastion Basic no permite conexion por cliente nativo/tunel; para eso se requiere Standard.
- VPN Gateway (opcional en la guia) no esta incluido en estos scripts.
- Contrasenas: se piden por pantalla y no se guardan en ningun archivo.

Ver **`SEGURIDAD-VM-App.md`**: reglas de nsg-app, orden de ejecucion, mejores practicas de seguridad y evaluacion del firewall.
