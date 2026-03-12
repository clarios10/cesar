import { useState, useMemo } from "react";

const REGIONS = [
  { id: "eastus", label: "East US", vmMult: 1.0 },
  { id: "westus2", label: "West US 2", vmMult: 1.0 },
  { id: "westeurope", label: "West Europe", vmMult: 1.05 },
  { id: "brazilsouth", label: "Brazil South", vmMult: 1.12 },
  { id: "mexicocentral", label: "Mexico Central", vmMult: 1.08 },
  { id: "canadacentral", label: "Canada Central", vmMult: 1.03 },
];

const OS_OPTIONS = [
  { id: "linux", label: "Linux", mult: 1.0 },
  { id: "windows", label: "Windows Server", mult: 1.73 },
];

const PAYMENT_OPTIONS = [
  { id: "payg", label: "Pago por uso", mult: 1.0 },
  { id: "reserved1", label: "Reservado 1 año", mult: 0.62 },
  { id: "reserved3", label: "Reservado 3 años", mult: 0.44 },
];

// E16s_v5 — 16 vCPUs, 128 GiB RAM (Linux base East US)
const VM_BASE_PRICE_HR = 1.008;
const HOURS_MONTH = 730;

// Premium SSD prices (East US, per month)
const DISK_PRICES = {
  P30_1TB: 135.17,   // P30 ~1 TiB LRS
  P40_2TB: 261.12,   // P40 ~2 TiB LRS
  P10_128GB: 19.71,  // P10 OS disk ~128 GiB
};

// Other services (base monthly USD)
const SERVICES = {
  vnet: { label: "Virtual Network (VNet)", base: 0, note: "Gratis (dentro de la misma región)" },
  vnetPeering: { label: "VNet Peering (outbound 100 GB/mes)", base: 1.0, note: "$0.01/GB outbound" },
  bandwidth: { label: "Ancho de banda saliente (100 GB/mes)", base: 9.0, note: "$0.087/GB primeros 10TB" },
  monitor: { label: "Azure Monitor (5 GB logs/mes)", base: 12.50, note: "$2.30/GB de ingesta por encima de 5 GB gratis" },
  logAnalytics: { label: "Log Analytics (10 GB datos/mes)", base: 23.0, note: "$2.30/GB" },
  backup: { label: "Azure Backup (1 TB protegido)", base: 30.0, note: "~$0.03/GB instancia protegida" },
  backupStorage: { label: "Backup Storage LRS (2 TB)", base: 40.96, note: "$0.02/GB almacenamiento backup" },
  privateDns: { label: "Azure Private DNS Zone", base: 0.50, note: "$0.50/zona + $0.40/millón queries" },
  dnsQueries: { label: "DNS Queries (1M consultas/mes)", base: 0.40, note: "$0.40/millón" },
  nsg: { label: "Network Security Group (NSG)", base: 0, note: "Gratis" },
  loadBalancer: { label: "Load Balancer (Standard, 0.5 reglas)", base: 18.25, note: "$0.025/hr + $0.008/GB" },
  snapshot: { label: "Disk Snapshots (1 TB snapshot)", base: 52.43, note: "$0.05/GB snapshot incremental" },
  keyvault: { label: "Azure Key Vault (10K operaciones/mes)", base: 0.03, note: "Gratis primero / $0.03 por 10K ops" },
  securityCenter: { label: "Microsoft Defender for Cloud (Servers P2)", base: 15.0, note: "$15/servidor/mes" },
};

const formatUSD = (n) => `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export default function AzureCalculator() {
  const [region, setRegion] = useState("eastus");
  const [os, setOs] = useState("linux");
  const [payment, setPayment] = useState("payg");
  const [vmHours, setVmHours] = useState(730);
  const [disk1, setDisk1] = useState("P30_1TB");
  const [disk2, setDisk2] = useState("P40_2TB");
  const [enabledServices, setEnabledServices] = useState({
    vnet: true, vnetPeering: true, bandwidth: true,
    monitor: true, logAnalytics: true, backup: true, backupStorage: true,
    privateDns: true, dnsQueries: true, nsg: true,
    loadBalancer: false, snapshot: false, keyvault: true, securityCenter: false,
  });

  const regionObj = REGIONS.find(r => r.id === region);
  const osObj = OS_OPTIONS.find(o => o.id === os);
  const paymentObj = PAYMENT_OPTIONS.find(p => p.id === payment);

  const vmMonthly = VM_BASE_PRICE_HR * vmHours * osObj.mult * regionObj.vmMult * paymentObj.mult;
  const osDiskMonthly = DISK_PRICES.P10_128GB * regionObj.vmMult;
  const dataDisk1Monthly = DISK_PRICES[disk1] * regionObj.vmMult;
  const dataDisk2Monthly = DISK_PRICES[disk2] * regionObj.vmMult;

  const servicesTotal = Object.entries(enabledServices).reduce((sum, [key, enabled]) => {
    return enabled ? sum + (SERVICES[key]?.base || 0) * regionObj.vmMult : sum;
  }, 0);

  const subtotalCompute = vmMonthly + osDiskMonthly + dataDisk1Monthly + dataDisk2Monthly;
  const total = subtotalCompute + servicesTotal;

  const toggleService = (key) => {
    setEnabledServices(prev => ({ ...prev, [key]: !prev[key] }));
  };

  const DISK_OPTIONS = [
    { id: "P30_1TB", label: "P30 – 1 TB SSD Premium" },
    { id: "P40_2TB", label: "P40 – 2 TB SSD Premium" },
  ];

  const SectionTitle = ({ children }) => (
    <div style={{ fontFamily: "'Courier New', monospace", fontSize: 11, letterSpacing: 3, textTransform: "uppercase", color: "#0078d4", marginBottom: 8, marginTop: 20, borderBottom: "1px solid #0078d420", paddingBottom: 4 }}>
      {children}
    </div>
  );

  const Row = ({ label, value, dimmed }) => (
    <div style={{ display: "flex", justifyContent: "space-between", padding: "5px 0", borderBottom: "1px solid #f0f0f0", opacity: dimmed ? 0.45 : 1 }}>
      <span style={{ fontSize: 13, color: "#444" }}>{label}</span>
      <span style={{ fontSize: 13, fontWeight: 600, color: "#1a1a2e", fontFamily: "monospace" }}>{value}</span>
    </div>
  );

  return (
    <div style={{ fontFamily: "'Segoe UI', system-ui, sans-serif", background: "linear-gradient(135deg, #f8faff 0%, #e8f0fe 100%)", minHeight: "100vh", padding: "24px 16px" }}>
      
      {/* Header */}
      <div style={{ maxWidth: 900, margin: "0 auto 24px", display: "flex", alignItems: "center", gap: 14 }}>
        <div style={{ width: 44, height: 44, background: "linear-gradient(135deg, #0078d4, #00b4d8)", borderRadius: 10, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 22 }}>☁</div>
        <div>
          <h1 style={{ margin: 0, fontSize: 22, fontWeight: 700, color: "#1a1a2e", letterSpacing: -0.5 }}>Calculadora Azure</h1>
          <p style={{ margin: 0, fontSize: 12, color: "#6b7280" }}>Estimación mensual de infraestructura · Precios referenciales East US 2025</p>
        </div>
      </div>

      <div style={{ maxWidth: 900, margin: "0 auto", display: "grid", gridTemplateColumns: "1fr 340px", gap: 20 }}>
        
        {/* LEFT: Config panel */}
        <div style={{ background: "white", borderRadius: 16, padding: 24, boxShadow: "0 4px 24px #0001" }}>
          
          <SectionTitle>Configuración general</SectionTitle>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 12, marginBottom: 16 }}>
            {[
              { label: "Región", value: region, set: setRegion, options: REGIONS.map(r => ({ id: r.id, label: r.label })) },
              { label: "Sistema Operativo", value: os, set: setOs, options: OS_OPTIONS },
              { label: "Modalidad de pago", value: payment, set: setPayment, options: PAYMENT_OPTIONS },
            ].map(({ label, value, set, options }) => (
              <div key={label}>
                <label style={{ display: "block", fontSize: 11, fontWeight: 600, color: "#6b7280", letterSpacing: 1, textTransform: "uppercase", marginBottom: 5 }}>{label}</label>
                <select value={value} onChange={e => set(e.target.value)} style={{ width: "100%", padding: "8px 10px", borderRadius: 8, border: "1.5px solid #e5e7eb", fontSize: 13, background: "#fafafa", outline: "none", cursor: "pointer" }}>
                  {options.map(o => <option key={o.id} value={o.id}>{o.label}</option>)}
                </select>
              </div>
            ))}
          </div>

          <SectionTitle>Máquina Virtual — E16s v5</SectionTitle>
          <div style={{ background: "#f0f7ff", borderRadius: 10, padding: 14, marginBottom: 14, border: "1px solid #bfdbfe" }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <div>
                <div style={{ fontWeight: 700, fontSize: 14, color: "#1e40af" }}>Standard_E16s_v5</div>
                <div style={{ fontSize: 12, color: "#4b5563", marginTop: 2 }}>16 vCPU · 128 GiB RAM · Intel Xeon 8370C</div>
              </div>
              <div style={{ textAlign: "right" }}>
                <div style={{ fontSize: 11, color: "#6b7280" }}>Base Linux East US</div>
                <div style={{ fontWeight: 700, fontSize: 15, color: "#0078d4" }}>${VM_BASE_PRICE_HR}/hr</div>
              </div>
            </div>
            <div style={{ marginTop: 12 }}>
              <label style={{ fontSize: 11, fontWeight: 600, color: "#6b7280", letterSpacing: 1, textTransform: "uppercase" }}>Horas de uso al mes: <span style={{ color: "#0078d4" }}>{vmHours}h</span></label>
              <input type="range" min={1} max={730} value={vmHours} onChange={e => setVmHours(+e.target.value)}
                style={{ width: "100%", marginTop: 6, accentColor: "#0078d4" }} />
              <div style={{ display: "flex", justifyContent: "space-between", fontSize: 10, color: "#9ca3af" }}>
                <span>1h</span><span>8h/día</span><span>730h (24/7)</span>
              </div>
            </div>
          </div>

          <SectionTitle>Discos Administrados (Premium SSD)</SectionTitle>
          <div style={{ marginBottom: 6, padding: "8px 12px", background: "#f9fafb", borderRadius: 8, border: "1px solid #e5e7eb", fontSize: 13, color: "#555" }}>
            <strong>OS Disk:</strong> P10 – 128 GiB Premium SSD (incluido) · <span style={{ color: "#0078d4", fontFamily: "monospace" }}>{formatUSD(osDiskMonthly)}/mes</span>
          </div>
          {[
            { label: "Disco de datos 1 (1 TB)", value: disk1, set: setDisk1 },
            { label: "Disco de datos 2 (2 TB)", value: disk2, set: setDisk2 },
          ].map(({ label, value, set }) => (
            <div key={label} style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
              <label style={{ fontSize: 12, color: "#555", minWidth: 170 }}>{label}:</label>
              <select value={value} onChange={e => set(e.target.value)} style={{ flex: 1, padding: "7px 10px", borderRadius: 8, border: "1.5px solid #e5e7eb", fontSize: 13, background: "#fafafa" }}>
                {DISK_OPTIONS.map(o => <option key={o.id} value={o.id}>{o.label}</option>)}
              </select>
              <span style={{ fontFamily: "monospace", fontSize: 12, color: "#0078d4", minWidth: 80, textAlign: "right" }}>
                {formatUSD(DISK_PRICES[value] * regionObj.vmMult)}/mes
              </span>
            </div>
          ))}

          <SectionTitle>Servicios adicionales</SectionTitle>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 6 }}>
            {Object.entries(SERVICES).map(([key, svc]) => (
              <div key={key} onClick={() => toggleService(key)}
                style={{ display: "flex", alignItems: "flex-start", gap: 8, padding: "9px 11px", borderRadius: 8, border: `1.5px solid ${enabledServices[key] ? "#bfdbfe" : "#e5e7eb"}`, background: enabledServices[key] ? "#f0f7ff" : "#fafafa", cursor: "pointer", transition: "all 0.15s" }}>
                <div style={{ width: 16, height: 16, borderRadius: 4, border: `2px solid ${enabledServices[key] ? "#0078d4" : "#d1d5db"}`, background: enabledServices[key] ? "#0078d4" : "white", marginTop: 1, flexShrink: 0, display: "flex", alignItems: "center", justifyContent: "center" }}>
                  {enabledServices[key] && <span style={{ color: "white", fontSize: 11, lineHeight: 1 }}>✓</span>}
                </div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 12, fontWeight: 600, color: enabledServices[key] ? "#1e40af" : "#6b7280" }}>{svc.label}</div>
                  <div style={{ fontSize: 10, color: "#9ca3af", marginTop: 1, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{svc.note}</div>
                </div>
                <div style={{ fontFamily: "monospace", fontSize: 11, color: "#0078d4", flexShrink: 0 }}>{formatUSD(svc.base)}</div>
              </div>
            ))}
          </div>
        </div>

        {/* RIGHT: Summary */}
        <div>
          <div style={{ background: "white", borderRadius: 16, padding: 22, boxShadow: "0 4px 24px #0001", position: "sticky", top: 20 }}>
            <div style={{ fontFamily: "'Courier New', monospace", fontSize: 10, letterSpacing: 3, textTransform: "uppercase", color: "#0078d4", marginBottom: 14 }}>Resumen de costos</div>

            <div style={{ marginBottom: 14 }}>
              <div style={{ fontSize: 11, color: "#9ca3af", marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>Cómputo</div>
              <Row label={`VM E16s v5 (${vmHours}h · ${osObj.label})`} value={formatUSD(vmMonthly)} />
              <Row label="OS Disk P10 (128 GB SSD)" value={formatUSD(osDiskMonthly)} />
              <Row label={`Disco 1: ${DISK_OPTIONS.find(d=>d.id===disk1)?.label}`} value={formatUSD(dataDisk1Monthly)} />
              <Row label={`Disco 2: ${DISK_OPTIONS.find(d=>d.id===disk2)?.label}`} value={formatUSD(dataDisk2Monthly)} />
              <div style={{ display: "flex", justifyContent: "space-between", padding: "7px 0", borderTop: "2px solid #e5e7eb", marginTop: 4 }}>
                <span style={{ fontSize: 13, fontWeight: 600, color: "#374151" }}>Subtotal cómputo</span>
                <span style={{ fontSize: 13, fontWeight: 700, fontFamily: "monospace", color: "#1a1a2e" }}>{formatUSD(subtotalCompute)}</span>
              </div>
            </div>

            <div style={{ marginBottom: 14 }}>
              <div style={{ fontSize: 11, color: "#9ca3af", marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>Servicios habilitados</div>
              {Object.entries(SERVICES).map(([key, svc]) => enabledServices[key] && (
                <Row key={key} label={svc.label} value={svc.base === 0 ? "Gratis" : formatUSD(svc.base * regionObj.vmMult)} dimmed={svc.base === 0} />
              ))}
              <div style={{ display: "flex", justifyContent: "space-between", padding: "7px 0", borderTop: "2px solid #e5e7eb", marginTop: 4 }}>
                <span style={{ fontSize: 13, fontWeight: 600, color: "#374151" }}>Subtotal servicios</span>
                <span style={{ fontSize: 13, fontWeight: 700, fontFamily: "monospace", color: "#1a1a2e" }}>{formatUSD(servicesTotal)}</span>
              </div>
            </div>

            {/* Total */}
            <div style={{ background: "linear-gradient(135deg, #0078d4, #005a9e)", borderRadius: 12, padding: "16px 18px", marginTop: 8 }}>
              <div style={{ color: "#93c5fd", fontSize: 11, letterSpacing: 2, textTransform: "uppercase", fontFamily: "monospace" }}>Total estimado / mes</div>
              <div style={{ color: "white", fontSize: 32, fontWeight: 800, fontFamily: "'Courier New', monospace", letterSpacing: -1, marginTop: 4 }}>
                {formatUSD(total)}
              </div>
              <div style={{ color: "#93c5fd", fontSize: 12, marginTop: 6 }}>
                ~{formatUSD(total / 12 * 12)} / año · {formatUSD(total / 730)}/hora
              </div>
              <div style={{ marginTop: 10, padding: "8px 10px", background: "#ffffff22", borderRadius: 8, fontSize: 11, color: "#dbeafe" }}>
                <strong>Región:</strong> {regionObj.label} · <strong>OS:</strong> {osObj.label} · <strong>Pago:</strong> {paymentObj.label}
              </div>
            </div>

            <div style={{ marginTop: 14, padding: "10px 12px", background: "#fffbeb", borderRadius: 8, border: "1px solid #fde68a", fontSize: 11, color: "#92400e", lineHeight: 1.6 }}>
              ⚠️ <strong>Nota:</strong> Estos precios son referenciales basados en tarifas públicas de Azure (East US, 2025). Usa la{" "}
              <a href="https://azure.microsoft.com/en-us/pricing/calculator/" target="_blank" rel="noreferrer" style={{ color: "#0078d4" }}>calculadora oficial</a>{" "}
              para cotizaciones finales. Precios en USD sin impuestos.
            </div>
          </div>
        </div>

      </div>
    </div>
  );
}
