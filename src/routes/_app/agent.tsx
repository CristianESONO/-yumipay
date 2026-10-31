import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { 
  PlusCircle, 
  ArrowDownCircle, 
  Loader2, 
  Wallet, 
  Coins, 
  ArrowRightLeft, 
  Banknote, 
  CheckCircle2, 
  Award,
  Sparkles 
} from "lucide-react";
import { toast } from "sonner";
import { formatXAF } from "@/lib/format";

export const Route = createFileRoute("/_app/agent")({
  component: AgentPage,
});

function AgentPage() {
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<"deposit" | "withdraw">("deposit");
  const [phone, setPhone] = useState("");
  const [depositAmount, setDepositAmount] = useState<number | "">("");
  const [depositLoading, setDepositLoading] = useState(false);

  // Cash-Out state
  const [cashOutCode, setCashOutCode] = useState("");
  const [cashOutPhone, setCashOutPhone] = useState("");
  const [cashOutLoading, setCashOutLoading] = useState(false);
  const [cashOutSuccess, setCashOutSuccess] = useState<any>(null);

  const [history, setHistory] = useState<any[]>([]);
  const [agentProfile, setAgentProfile] = useState<any>(null);
  const [transferAmount, setTransferAmount] = useState<number | "">("");
  const [transfering, setTransfering] = useState(false);

  useEffect(() => {
    loadData();
  }, []);

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;
    
    const { data: profile } = await supabase.from("profiles").select("*").eq("id", user.id).single();
    if (!profile || (profile.role !== "agent" && profile.role !== "admin")) {
      navigate({ to: "/home" as any });
      return;
    }
    setAgentProfile(profile);

    const { data: txs } = await supabase
      .from("transactions")
      .select("id, type, amount_xaf, note, recipient_phone, recipient_name")
      .or(`sender_id.eq.${user.id},recipient_id.eq.${user.id}`)
      .order("created_at", { ascending: false })
      .limit(6);
    
    setHistory(txs || []);
  }

  async function handleInternalTransfer(toAgent: boolean) {
    if (!transferAmount || Number(transferAmount) <= 0) return toast.error("Monto inválido");
    setTransfering(true);
    try {
      // @ts-ignore
      const { error } = await supabase.rpc("internal_transfer", {
        p_amount: Number(transferAmount),
        p_to_agent_wallet: toAgent
      });
      if (error) throw error;
      toast.success(toAgent ? "Saldo movido a Caja" : "Saldo movido a Personal");
      setTransferAmount("");
      loadData();
    } catch (e: any) {
      toast.error(e.message);
    } finally {
      setTransfering(false);
    }
  }

  async function handleDeposit(e: React.FormEvent) {
    e.preventDefault();
    if (!depositAmount || Number(depositAmount) <= 0) return toast.error("Cantidad inválida");
    if (!phone.trim()) return toast.error("Introduce el teléfono del cliente");
    
    setDepositLoading(true);
    try {
      // @ts-ignore
      const { data, error } = await supabase.rpc("agent_deposit_v2", {
        p_recipient_phone: phone.trim(),
        p_amount: Math.floor(Number(depositAmount)),
        p_note: "Recarga en punto Yumi"
      });

      if (error) throw error;
      if (data && (data as { ok?: boolean }).ok === false) {
        throw new Error((data as { message?: string }).message || "Error al recargar al cliente");
      }

      toast.success(`Recarga de ${formatXAF(Number(depositAmount))} completada`);
      setPhone("");
      setDepositAmount("");
      loadData();
    } catch (err: any) {
      toast.error(err.message || "Error al recargar al cliente");
    } finally {
      setDepositLoading(false);
    }
  }

  async function handleExecuteCashOut(e: React.FormEvent) {
    e.preventDefault();
    if (!cashOutCode.trim() || cashOutCode.trim().length !== 6) {
      return toast.error("Introduce un código de retiro válido de 6 dígitos");
    }
    if (!cashOutPhone.trim()) {
      return toast.error("Introduce el número de teléfono del cliente");
    }

    setCashOutLoading(true);
    setCashOutSuccess(null);
    try {
      // @ts-ignore
      const { data, error } = await supabase.rpc("agent_execute_cash_out_v3", {
        p_code: cashOutCode.trim(),
        p_client_phone: cashOutPhone.trim(),
      });

      if (error) throw error;
      if (!data.ok) throw new Error(data.message || "Error al procesar el retiro");

      setCashOutSuccess(data);
      toast.success(`Retiro validado. Entrega ${formatXAF((data as any).amount_to_hand_out)} en mano al cliente.`);
      setCashOutCode("");
      setCashOutPhone("");
      loadData();
    } catch (err: any) {
      toast.error(err.message || "Error al procesar el retiro");
    } finally {
      setCashOutLoading(false);
    }
  }

  return (
    <div className="mx-auto max-w-md px-5 pb-8 pt-6">
      <div className="flex items-center justify-between">
        <h1 className="font-display text-2xl font-bold text-foreground">Panel Agente</h1>
        <div className="rounded-full bg-success/10 px-3 py-1 text-[10px] font-bold text-success uppercase tracking-widest">
          Agente Oficial
        </div>
      </div>

      {/* Wallet Cards */}
      <div className="mt-6 flex flex-col gap-3">
        <div className="rounded-[2rem] border border-primary/20 bg-primary/5 p-6 shadow-sm">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2 text-primary">
              <Coins className="h-4 w-4" />
              <span className="text-[10px] font-bold uppercase tracking-widest">Saldo de Caja (Working Capital)</span>
            </div>
            {agentProfile?.agent_commission_earned_xaf > 0 && (
              <span className="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 text-[9px] font-bold text-primary">
                <Sparkles className="h-3 w-3" />
                +{formatXAF(agentProfile.agent_commission_earned_xaf)} ganados
              </span>
            )}
          </div>
          <p className="mt-2 font-display text-3xl font-bold text-primary">
            {formatXAF(agentProfile?.agent_balance_xaf || 0)}
          </p>
          <p className="mt-1 text-[10px] text-muted-foreground">Fondo para inyectar recargas y recibir retiros de clientes.</p>
        </div>

        <div className="rounded-2xl border border-border bg-card p-5 shadow-sm">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2 text-muted-foreground">
              <Wallet className="h-4 w-4" />
              <span className="text-[10px] font-bold uppercase tracking-widest">Tu Billetera Personal</span>
            </div>
            <p className="font-display font-bold text-foreground">
              {formatXAF(agentProfile?.balance_xaf || 0)}
            </p>
          </div>
          
          <div className="mt-4 pt-4 border-t border-border">
            <div className="flex items-center justify-between mb-3">
              <label className="text-[10px] font-bold uppercase tracking-widest text-muted-foreground">
                Mover fondos entre billeteras
              </label>
              <ArrowRightLeft className="h-3 w-3 text-muted-foreground" />
            </div>
            <div className="flex gap-2">
              <input
                type="number"
                value={transferAmount}
                onChange={e => setTransferAmount(e.target.value === "" ? "" : Number(e.target.value))}
                placeholder="Cantidad"
                className="h-10 flex-1 rounded-xl border border-border bg-background px-3 text-sm focus:border-primary focus:outline-none"
              />
              <button 
                onClick={() => handleInternalTransfer(true)}
                disabled={transfering}
                className="h-10 shrink-0 rounded-xl bg-primary/10 px-3 text-xs font-bold text-primary transition hover:bg-primary hover:text-white disabled:opacity-50"
              >
                A Caja
              </button>
              <button 
                onClick={() => handleInternalTransfer(false)}
                disabled={transfering}
                className="h-10 shrink-0 rounded-xl bg-accent px-3 text-xs font-bold text-foreground transition hover:bg-border disabled:opacity-50"
              >
                A Personal
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Action Tabs: Cash-In vs Cash-Out */}
      <div className="mt-6">
        <div className="flex rounded-2xl border border-border bg-muted/40 p-1">
          <button
            type="button"
            onClick={() => setActiveTab("deposit")}
            className={`flex-1 rounded-xl py-2.5 text-xs font-bold transition ${
              activeTab === "deposit"
                ? "bg-card text-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <span className="flex items-center justify-center gap-1.5">
              <PlusCircle className="h-4 w-4 text-success" />
              Recarga (Cash-In)
            </span>
          </button>
          <button
            type="button"
            onClick={() => setActiveTab("withdraw")}
            className={`flex-1 rounded-xl py-2.5 text-xs font-bold transition ${
              activeTab === "withdraw"
                ? "bg-card text-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <span className="flex items-center justify-center gap-1.5">
              <Banknote className="h-4 w-4 text-primary" />
              Pagar Retiro (Cash-Out)
            </span>
          </button>
        </div>

        {/* Tab 1: Cash-In Form */}
        {activeTab === "deposit" && (
          <form onSubmit={handleDeposit} className="mt-4 rounded-3xl border border-border bg-card p-5 shadow-sm space-y-4">
            <div>
              <h3 className="font-display font-semibold text-foreground">Recargar Saldo a Cliente</h3>
              <p className="text-xs text-muted-foreground">Recibe el dinero en efectivo y digitalízalo en la cuenta del cliente.</p>
            </div>

            <div>
              <label className="block text-xs font-bold text-muted-foreground uppercase mb-1">Teléfono del cliente</label>
              <input
                required
                type="tel"
                value={phone}
                onChange={e => setPhone(e.target.value)}
                placeholder="+240 222 000 000"
                className="input"
              />
            </div>

            <div>
              <label className="block text-xs font-bold text-muted-foreground uppercase mb-1">Monto en Efectivo Recibido (XAF)</label>
              <input
                required
                type="number"
                min={100}
                value={depositAmount}
                onChange={e => setDepositAmount(e.target.value === "" ? "" : Number(e.target.value))}
                placeholder="0"
                className="input font-display font-bold text-xl"
              />
            </div>

            <button
              type="submit"
              disabled={depositLoading}
              className="inline-flex h-12 w-full items-center justify-center gap-2 rounded-2xl bg-success font-display font-semibold text-white shadow-sm transition active:scale-[0.98] disabled:opacity-60"
            >
              {depositLoading ? <Loader2 className="h-4 w-4 animate-spin" /> : <PlusCircle className="h-4 w-4" />}
              Confirmar Recarga Digital
            </button>
          </form>
        )}

        {/* Tab 2: Cash-Out Form */}
        {activeTab === "withdraw" && (
          <form onSubmit={handleExecuteCashOut} className="mt-4 rounded-3xl border border-border bg-card p-5 shadow-sm space-y-4">
            <div>
              <h3 className="font-display font-semibold text-foreground">Validar Retiro en Efectivo</h3>
              <p className="text-xs text-muted-foreground">Pide al cliente su código de 6 dígitos para debitar su cuenta y entregarle los billetes.</p>
            </div>

            <div>
              <label className="block text-xs font-bold text-muted-foreground uppercase mb-1">Teléfono del cliente</label>
              <input
                required
                type="tel"
                value={cashOutPhone}
                onChange={e => setCashOutPhone(e.target.value)}
                placeholder="+240 222 000 000"
                className="input"
              />
            </div>

            <div>
              <label className="block text-xs font-bold text-muted-foreground uppercase mb-1">Código de 6 dígitos del cliente</label>
              <input
                required
                type="text"
                maxLength={6}
                value={cashOutCode}
                onChange={e => setCashOutCode(e.target.value.replace(/\D/g, ""))}
                placeholder="Ej. 482910"
                className="input text-center font-mono text-2xl font-bold tracking-widest"
              />
            </div>

            {cashOutSuccess && (
              <div className="rounded-2xl border border-success/30 bg-success/10 p-4 text-xs space-y-2">
                <div className="flex items-center gap-2 font-bold text-success text-sm">
                  <CheckCircle2 className="h-5 w-5" /> Retiro Autorizado
                </div>
                <div className="flex justify-between text-foreground">
                  <span>Cliente:</span>
                  <span className="font-bold">{cashOutSuccess.client_name}</span>
                </div>
                <div className="flex justify-between text-foreground">
                  <span>Entregar en efectivo:</span>
                  <span className="font-display font-extrabold text-sm text-foreground">
                    {formatXAF(cashOutSuccess.amount_to_hand_out)}
                  </span>
                </div>
                <div className="flex justify-between text-success font-bold pt-1 border-t border-success/20">
                  <span>Tu comisión ganada:</span>
                  <span>+{formatXAF(cashOutSuccess.agent_commission_earned)}</span>
                </div>
              </div>
            )}

            <button
              type="submit"
              disabled={cashOutLoading || cashOutCode.length !== 6}
              className="inline-flex h-12 w-full items-center justify-center gap-2 rounded-2xl bg-primary font-display font-semibold text-primary-foreground shadow-sm transition active:scale-[0.98] disabled:opacity-60"
            >
              {cashOutLoading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Banknote className="h-4 w-4" />}
              Verificar y Entregar Efectivo
            </button>
          </form>
        )}
      </div>

      {/* Recent History */}
      <div className="mt-8">
        <h3 className="font-display font-semibold text-foreground">Operaciones Recientes</h3>
        <div className="mt-3 space-y-2">
          {history.length === 0 && (
            <p className="py-8 text-center text-sm text-muted-foreground italic">No hay operaciones registradas aún.</p>
          )}
          {history.map((tx) => (
            <div key={tx.id} className="flex items-center justify-between rounded-2xl border border-border bg-card/60 p-4">
              <div className="flex items-center gap-3">
                <div className="grid h-10 w-10 place-items-center rounded-full bg-accent text-primary">
                  {tx.type === "withdrawal" ? <Banknote className="h-5 w-5" /> : <ArrowDownCircle className="h-5 w-5" />}
                </div>
                <div>
                  <p className="text-sm font-semibold text-foreground">
                    {tx.type === "withdrawal" ? "Retiro pagado" : "Recarga a cliente"}
                  </p>
                  <p className="text-[10px] text-muted-foreground">{tx.recipient_phone || tx.note}</p>
                </div>
              </div>
              <p className="font-display font-bold text-foreground">
                {formatXAF(tx.amount_xaf)}
              </p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
