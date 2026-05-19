import { createFileRoute } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { PlusCircle, Users, ArrowDownCircle, Search, Loader2, Wallet, Coins, ArrowRightLeft, ArrowUpRight } from "lucide-react";
import { toast } from "sonner";
import { formatXAF } from "@/lib/format";

export const Route = createFileRoute("/_app/agent")({
  component: AgentPage,
});

function AgentPage() {
  const [phone, setPhone] = useState("");
  const [amount, setAmount] = useState<number | "">("");
  const [loading, setLoading] = useState(false);
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
    setAgentProfile(profile);

    const { data: txs } = await supabase
      .from("transactions")
      .select("*, recipient:profiles!transactions_recipient_id_fkey(full_name, phone)")
      .eq("sender_id", user.id)
      // @ts-ignore
      .eq("type", "deposit")
      .order("created_at", { ascending: false })
      .limit(5);
    
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
    if (!amount || amount <= 0) return toast.error("Cantidad inválida");
    
    setLoading(true);
    try {
      // @ts-ignore
      const { error } = await supabase.rpc("agent_deposit", {
        p_recipient_phone: phone.trim(),
        p_amount: Number(amount),
        p_note: "Recarga en punto Yumi"
      });

      if (error) throw error;

      toast.success(`Recarga de ${formatXAF(Number(amount))} completada`);
      setPhone("");
      setAmount("");
      loadData();
    } catch (err: any) {
      toast.error(err.message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="mx-auto max-w-md px-5 pb-8 pt-6">
      <div className="flex items-center justify-between">
        <h1 className="font-display text-2xl font-bold text-foreground">Panel Agente</h1>
        <div className="rounded-full bg-success/10 px-3 py-1 text-[10px] font-bold text-success uppercase tracking-widest">
          Activo
        </div>
      </div>

      {/* Wallet Cards */}
      <div className="mt-6 flex flex-col gap-3">
        <div className="rounded-[2rem] border border-primary/20 bg-primary/5 p-6 shadow-sm">
          <div className="flex items-center gap-2 text-primary">
            <Coins className="h-4 w-4" />
            <span className="text-[10px] font-bold uppercase tracking-widest">Saldo de Caja (Working Capital)</span>
          </div>
          <p className="mt-2 font-display text-3xl font-bold text-primary">
            {formatXAF(agentProfile?.agent_balance_xaf || 0)}
          </p>
          <p className="mt-1 text-[10px] text-muted-foreground">Este dinero se usa para recargas de clientes.</p>
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
                Mover fondos
              </label>
              <ArrowRightLeft className="h-3 w-3 text-muted-foreground" />
            </div>
            <div className="flex gap-2">
              <div className="relative flex-1">
                <input
                  type="number"
                  value={transferAmount}
                  onChange={e => setTransferAmount(e.target.value === "" ? "" : Number(e.target.value))}
                  placeholder="Cantidad"
                  className="h-10 w-full rounded-xl border border-border bg-background px-3 text-sm focus:border-primary focus:outline-none"
                />
              </div>
              <button 
                onClick={() => handleInternalTransfer(true)}
                disabled={transfering}
                className="h-10 shrink-0 rounded-xl bg-primary/10 px-4 text-xs font-bold text-primary transition hover:bg-primary hover:text-white disabled:opacity-50"
              >
                A Caja
              </button>
              <button 
                onClick={() => handleInternalTransfer(false)}
                disabled={transfering}
                className="h-10 shrink-0 rounded-xl bg-accent px-4 text-xs font-bold text-foreground transition hover:bg-border disabled:opacity-50"
              >
                A Personal
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Recent History */}
      <div className="mt-8">
        <h3 className="font-display font-semibold text-foreground">Recientes</h3>
        <div className="mt-3 space-y-2">
          {history.length === 0 && (
            <p className="py-8 text-center text-sm text-muted-foreground italic">No hay operaciones hoy.</p>
          )}
          {history.map((tx) => (
            <div key={tx.id} className="flex items-center justify-between rounded-2xl border border-border bg-card/60 p-4">
              <div className="flex items-center gap-3">
                <div className="grid h-10 w-10 place-items-center rounded-full bg-success/10 text-success">
                  <ArrowDownCircle className="h-5 w-5" />
                </div>
                <div>
                  <p className="text-sm font-semibold text-foreground">{tx.recipient?.full_name}</p>
                  <p className="text-[10px] text-muted-foreground">{tx.recipient?.phone}</p>
                </div>
              </div>
              <p className="font-display font-bold text-success">
                +{formatXAF(tx.amount_xaf)}
              </p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
